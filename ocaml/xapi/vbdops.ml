(*
 * Copyright (C) 2006-2009 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
(**
 * @group Storage
 *)
 
open Printf
open Threadext
open Stringext
open Pervasiveext
open Vmopshelpers
open Client

module D = Debug.Debugger(struct let name="xapi" end)
open D

module L = Debug.Debugger(struct let name="license" end)


(** Thrown if an empty VBD is attached to a PV guest *)
exception Empty_VBDs_not_supported_for_PV
(** Thrown if an empty VBD which isn't a CDROM is attached to an HVM guest *)
exception Only_CD_VBDs_may_be_empty


(* This function maps from a string-encoded integer to a device name, dependent on *)
(* whether the VM is HVM or not. HVM gets a mapping 0 -> hda | 1 -> hdb etc., and *)
(* PV gets 0 -> xvda | 1 -> xvdb etc *)

let translate_vbd_device name is_hvm =
  try
    let num = int_of_string name in
    if num<0 || num>15 then failwith "Invalid"; (* Note - this gets caught and the original string is returned *)
    let a = int_of_char 'a' in
    if is_hvm
    then Printf.sprintf "hd%c" (char_of_int (num+a))
    else Printf.sprintf "xvd%c" (char_of_int (num+a))
  with
      _ -> name

(** Create a debug-friendly string from a VBD *)
let string_of_vbd ~__context ~vbd = 
  let r = Db.VBD.get_record ~__context ~self:vbd in
  let name = r.API.vBD_userdevice ^ "/" ^ r.API.vBD_device in
  let vdi = if r.API.vBD_empty then "empty" else try Db.VDI.get_uuid ~__context ~self:r.API.vBD_VDI with _ -> "missing" in
  name ^ ":" ^ vdi


(* real helpers *)
let create_vbd ~__context ~xs ~hvm ~protocol domid self =
  Xapi_xenops_errors.handle_xenops_error
    (fun () ->
	(* Don't attempt to attach an empty VBD to a PV guest *)
	let empty = Db.VBD.get_empty ~__context ~self in
	if not(hvm) && empty
	then raise Empty_VBDs_not_supported_for_PV;
	let dev_type = Db.VBD.get_type ~__context ~self in
	if empty && dev_type <> `CD
	then raise Only_CD_VBDs_may_be_empty;

	let mode = Db.VBD.get_mode ~__context ~self in
	let mode = match mode with
	  | `RW -> Device.Vbd.ReadWrite
	  | `RO -> Device.Vbd.ReadOnly in
	let dev_type = match dev_type with
	  | `Disk -> Device.Vbd.Disk
	  | `CD   -> Device.Vbd.CDROM in
	let unpluggable = Db.VBD.get_unpluggable ~__context ~self in

	let userdevice = Db.VBD.get_userdevice ~__context ~self in
	let realdevice = translate_vbd_device userdevice hvm in
	Db.VBD.set_device ~__context ~self ~value:realdevice;

	if empty then begin
	  let (_: Device_common.device) = Device.Vbd.add ~xs ~hvm ~mode ~phystype:Device.Vbd.File ~physpath:""
	    ~virtpath:realdevice ~dev_type ~unpluggable ~protocol ~extra_private_keys:[ "ref", Ref.string_of self ] domid in
	  Db.VBD.set_currently_attached ~__context ~self ~value:true;
	end else begin
	  (* Attach a real VDI *)
	  let vdi = Db.VBD.get_VDI ~__context ~self in
	  let vdi_uuid = Uuid.of_string (Db.VDI.get_uuid ~__context ~self:vdi) in

	  Sm.call_sm_vdi_functions ~__context ~vdi
	    (fun srconf srtype sr ->
	       let phystype = Device.Vbd.physty_of_string (Sm.sr_content_type ~__context ~sr) 
	       and physpath = Storage_access.VDI.get_physical_path vdi_uuid in

		    try
		      (* The backend can put useful stuff in here on vdi_attach *)
		      let extra_backend_keys = List.map (fun (k, v) -> "sm-data/" ^ k, v) (Db.VDI.get_xenstore_data ~__context ~self:vdi) in
		      let (_: Device_common.device) = Device.Vbd.add ~xs ~hvm ~mode ~phystype ~physpath
			~virtpath:realdevice ~dev_type ~unpluggable ~protocol ~extra_backend_keys ~extra_private_keys:[ "ref", Ref.string_of self ] domid in

		      Db.VBD.set_currently_attached ~__context ~self ~value:true;
		      debug "set_currently_attached to true for VBD uuid %s" (Db.VBD.get_uuid ~__context ~self)
		    with   
		    | Hotplug.Device_timeout device ->
			error "Timeout waiting for backend hotplug scripts (%s) for VBD %s" (Device_common.string_of_device device) (string_of_vbd ~__context ~vbd:self);
			raise (Api_errors.Server_error(Api_errors.device_attach_timeout, 
						      [ "VBD"; Ref.string_of self ]))
		    | Hotplug.Frontend_device_timeout device ->
			error "Timeout waiting for frontend hotplug scripts (%s) for VBD %s" (Device_common.string_of_device device) (string_of_vbd ~__context ~vbd:self);
			raise (Api_errors.Server_error(Api_errors.device_attach_timeout, 
						      [ "VBD"; Ref.string_of self ]))
		 )
	end
    )

(** set vbd qos via ionicing blkback thread *)
let set_vbd_qos_norestrictions ~__context ~self domid devid pid ty params alert_fct =
	let do_ionice pid schedclass param =
		let ionice = [| "ionice"; sprintf "-c%d" schedclass;
		                sprintf "-n%d" param; sprintf "-p%d" pid |] in
		match Unixext.spawnvp ionice.(0) ionice with
		| Unix.WEXITED 0  -> ()
		| Unix.WEXITED rc -> alert_fct (sprintf "ionice exit code = %d" rc)
		| _               -> alert_fct "ionice didn't complete";
		in

	let apply_ioqos pid params =
		let schedclass, needparam =
			try
				match List.assoc "sched" params with
				| "rt" | "real-time" -> 1, true
				| "idle"             -> 3, false
				| _                  -> 2, true
			with Not_found ->
				2, true in

		match needparam with
		| false -> do_ionice pid schedclass 7
		| true  -> (
			let param =
				if List.mem_assoc "class" params then
					match List.assoc "class" params with
					| "highest" -> Some 0
					| "high"    -> Some 2
					| "normal"  -> Some 4
					| "low"     -> Some 6
					| "lowest"  -> Some 7
					| s         ->
						try Some (int_of_string s) with _ -> None
				else
					None in
			match param with
			| None   -> alert_fct "this IO class need a valid parameter"
			| Some n -> do_ionice pid schedclass n
			)
		in

	match ty with
	| "ionice" -> apply_ioqos pid params
	| ""       -> ()
	| _        -> alert_fct (sprintf "unknown type \"%s\"" ty)

let set_vbd_qos ~__context ~self domid devid pid =
	let ty = Db.VBD.get_qos_algorithm_type ~__context ~self in
	let params = Db.VBD.get_qos_algorithm_params ~__context ~self in

	let alert_fct reason =
		let vbduuid = Db.VBD.get_uuid ~__context ~self in
		let vm = Db.VBD.get_VM ~__context ~self in
		let vmuuid = Db.VM.get_uuid ~__context ~self:vm in
		warn "vbd qos failed: %s (vm=%s,vbd=%s)" reason vmuuid vbduuid;
		(*
		ignore (Xapi_alert.create_system ~__context ~level:`Warn ~message:Api_alerts.vbd_qos_failed
		                                 ~params:[ "vm", vmuuid; "vbd", vbduuid; "reason", reason; ])
		*)
		in

	set_vbd_qos_norestrictions ~__context ~self domid devid pid ty params alert_fct

let eject_vbd ~__context ~self =
	if not (Db.VBD.get_empty ~__context ~self) then (
		let vdi = Db.VBD.get_VDI ~__context ~self in

		let is_sr_local_cdrom sr =
			let srty = Db.SR.get_type ~__context ~self:sr in
			if srty = "udev" then (
				let smconfig = Db.SR.get_sm_config ~__context ~self:sr in
				try List.assoc "type" smconfig = "cd" with _ -> false
			) else
				false
			in
		let activate_tray =
			let host = Helpers.get_localhost ~__context in
			try
				let oc = Db.Host.get_other_config ~__context ~self:host in
				bool_of_string (List.assoc Xapi_globs.cd_tray_ejector oc)
			with _ -> false
			in
		if is_sr_local_cdrom (Db.VDI.get_SR ~__context ~self:vdi) then (
			(* check if other VBD are also attached to this VDI *)
			let allvbds = Db.VDI.get_VBDs ~__context ~self:vdi in
			let running_vbds = List.fold_left (fun acc vbd ->
				try
					let vm = Db.VBD.get_VM ~__context ~self:vbd in
					if Helpers.is_running ~__context ~self:vm then
						(vbd, vm) :: acc
					else
						acc
				with _ -> acc
			) [] allvbds in
		
			(* iterate over all xenstore entries related to vbd/vm to see if the guest already
			   ejected the cd or not *)
			let notejected = List.fold_left (fun acc (vbd, vm) ->
				let domid = Int64.to_int (Db.VM.get_domid ~__context ~self:vm) in
				let device = Db.VBD.get_device ~__context ~self:vbd in
				with_xs (fun xs ->
					if Device.Vbd.media_is_ejected ~xs ~virtpath:device domid then
						acc
					else
						vbd :: acc
				)
			) [] running_vbds in

			if List.length notejected = 0 then (
				if activate_tray then (
					let location = Db.VDI.get_location ~__context ~self:vdi in
					let cmd = [| "eject"; location |] in
					ignore (Unixext.spawnvp cmd.(0) cmd)
				);
				Storage_access.deactivate_and_detach ~__context ~vdi;
			)
		) else (
			Db.VBD.set_empty ~__context ~self ~value:true;
			Db.VBD.set_VDI ~__context ~self ~value:Ref.null
		)
	)

(* Sets VBD as empty; throws an error if the VBD is not removable. Called for each
   VBD whose VDI could not be attached or locked. Intention is to allow a VM to boot
   if a removable device couldn't be attached but NOT if any non-removable disks
   couldn't be attached.
   Is a no-op in the event a VBD is already marked as empty *)
let mark_as_empty ~__context ~vbd =
  if not(Db.VBD.get_empty ~__context ~self:vbd) then begin
    let vdi = Db.VBD.get_VDI ~__context ~self:vbd in
    let name = string_of_vbd ~__context ~vbd in
    debug "VBD device %s: VDI failed to attach" name;
    if not(Helpers.is_removable ~__context ~vbd) then begin
      error "VBD device %s: VDI failed to attach and cannot be ejected because VBD is not removable media" name;
      let vm = Ref.string_of (Db.VBD.get_VM ~__context ~self:vbd) in
      let vdi = Ref.string_of vdi in
      raise (Api_errors.Server_error(Api_errors.vm_requires_vdi, [ vm; vdi ]))
    end;
    debug "VBD device %s: marking as empty" name;
    Db.VBD.set_empty ~__context ~self:vbd ~value:true;
    Db.VBD.set_VDI ~__context ~self:vbd ~value:Ref.null
  end

(* Check to see if a VDI record still exists. If not (eg if the scanner zapped it)
   then attempt to mark the VBD as empty *)
let check_vdi_exists ~__context ~vbd = 
  let vdi = Db.VBD.get_VDI ~__context ~self:vbd in
  try 
    ignore(Db.VDI.get_uuid ~__context ~self:vdi)
  with _ ->
    mark_as_empty ~__context ~vbd
    
(** On a start/reboot we only actually attach those disks which satisfy
    at least one of:
    (i) marked with operation `attach in the message-forwarder (VM.start); or
    (ii) marked with 'reserved' by the event thread (in-guest reboot).
    All other disks should be ignored.
    Note during resume and migrate the currently_attached field is used. *)
let vbds_to_attach ~__context ~vm = 
  let should_attach_this_vbd vbd =
    try
      let vbd_r = Db.VBD.get_record_internal ~__context ~self:vbd in
      false
      || vbd_r.Db_actions.vBD_currently_attached
      || vbd_r.Db_actions.vBD_reserved
      || (List.mem `attach (List.map snd vbd_r.Db_actions.vBD_current_operations))
    with _ ->
      (* Skip VBD because it was destroyed: it must not have been
	 any of the ones we care about *)
      false in
  List.filter should_attach_this_vbd (Db.VM.get_VBDs ~__context ~self:vm)
