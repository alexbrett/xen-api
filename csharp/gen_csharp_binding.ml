(*
 * Copyright (c) Citrix Systems, Inc.
 * All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 
 *   1) Redistributions of source code must retain the above copyright
 *      notice, this list of conditions and the following disclaimer.
 * 
 *   2) Redistributions in binary form must reproduce the above
 *      copyright notice, this list of conditions and the following
 *      disclaimer in the documentation and/or other materials
 *      provided with the distribution.
 * 
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
 * COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
 * OF THE POSSIBILITY OF SUCH DAMAGE.
 *)

open Stdext
open Pervasiveext
open Printf
open Xstringext

open Datamodel
open Datamodel_types
open Dm_api

open CommonFunctions

module DT = Datamodel_types
module DU = Datamodel_utils

module TypeSet = Set.Make(struct
			    type t = DT.ty
			    let compare = compare
			  end)

let open_source' = ref false
let destdir'    = ref ""
let sr_xml'     = ref ""
let resx_file'  = ref ""

let get_deprecated_attribute_string version =
  match version with
  | None -> ""
  | Some versionString -> "[Deprecated(\"" ^ get_release_name versionString ^ "\")]"  

let get_deprecated_attribute message =
  let version = message.msg_release.internal_deprecated_since in
    get_deprecated_attribute_string version

let _ =
  Arg.parse
    [
      "-r", Arg.Set_string resx_file', "specifies the location of the FriendlyErrorNames.resx file";
      "-s", Arg.Set_string sr_xml', "specifies the location of the XE_SR_ERRORCODES.xml file";
      "-o", Arg.Set open_source', "requests a version of the API filtered for open source";
      "-d", Arg.Set_string destdir', "specifies the destination directory for the generated files";
    ]
    (fun x -> raise (Arg.Bad ("Found anonymous argument " ^ x)))
    ("Generates C# bindings for the XenAPI. See -help.")

let open_source = !open_source'
let destdir = !destdir'
let sr_xml = !sr_xml'
let resx_file = !resx_file'


let api =
	Datamodel_utils.named_self := true;

	let obj_filter _ = true in
	let field_filter field =
		(not field.internal_only) &&
		((not open_source && (List.mem "closed" field.release.internal)) ||
		(open_source && (List.mem "3.0.3" field.release.opensource)))
	in
	let message_filter msg = 
		Datamodel_utils.on_client_side msg &&
		(* XXX: C# binding generates get_all_records some other way *)
		(msg.msg_tag <> (FromObject GetAllRecords)) && 
		((not open_source && (List.mem "closed" msg.msg_release.internal)) ||
		(open_source && (List.mem "3.0.3" msg.msg_release.opensource)))
	in
	filter obj_filter field_filter message_filter
		(Datamodel_utils.add_implicit_messages ~document_order:false
			(filter obj_filter field_filter message_filter Datamodel.all_api))

let classes = objects_of_api api
let enums = ref TypeSet.empty
let maps = ref TypeSet.empty

(* XenCenter only caches certain XenAPI objects. Don't bother autogenerating methods*)
(* to handle a type in XenObjectDownloader if the GUI isn't interested in them. *)
let cached_by_gui x =
  not (List.mem (String.lowercase x.name) ["vtpm"; "user"; "session"; "debug"; "event"; "secret"])

let generated x =
  not (List.mem x.name ["session"; "debug"; "event"])

let proxy_generated x =
  not (List.mem x.name ["debug"; "event"])

let joined sep f l =
  let r = List.map f l in
  String.concat sep
    (List.filter (fun x -> String.compare x "" != 0) r)


let escape s =
  let esc_char = function
    | '"' -> "\\\""
    | c -> String.make 1 c
  in
    String.concat "" (List.map esc_char (String.explode s))

let enum_of_wire = String.replace "-" "_"

let rec main() =
  gen_proxy();
  List.iter (fun x -> if generated x then gen_class x) classes;
  gen_object_downloader classes;
  TypeSet.iter gen_enum !enums;
  gen_maps();
  gen_i18n_errors();
  gen_http_actions();
  gen_relations()


(* ------------------- category: relations *)

and relations = Hashtbl.create 10

and gen_relations() =
  let out_chan = open_out (Filename.concat destdir "Relation.cs") in
  let print format = fprintf out_chan format in
  let _ = List.iter process_relations (relations_of_api Datamodel.all_api) in
  print 
"%s

using System;
using System.Collections.Generic;

namespace XenAPI
{
    public partial class Relation
    {
        public readonly String field;
        public readonly String manyType;
        public readonly String manyField;

        public Relation(String field, String manyType, String manyField)
        {
            this.field = field;
            this.manyField = manyField;
            this.manyType = manyType;
        }

        public static Dictionary<Type, Relation[]> GetRelations()
        {
            Dictionary<Type, Relation[]> relations = new Dictionary<Type, Relation[]>();

" (banner());
    Hashtbl.iter (gen_relations_by_type out_chan) relations;
    print
"
            return relations;
       }
    }
}
"
and string_ends str en = 
  let len = String.length en in
    String.sub str ((String.length str) - len) len = en

and process_relations ((oneClass, oneField), (manyClass, manyField)) = 
  let value = 
    try
      (manyField, oneClass, oneField) :: (Hashtbl.find relations manyClass)
    with Not_found ->
      begin
        [(manyField, oneClass, oneField)]
      end
  in
    Hashtbl.replace relations manyClass value

and gen_relations_by_type out_chan manyClass relations =
  let print format = fprintf out_chan format in
    print "            relations.Add(typeof(Proxy_%s), new Relation[] {\n" (exposed_class_name manyClass);
    
    List.iter (gen_relation out_chan) relations;
    
    print "            });\n\n";
    
and gen_relation out_chan (manyField, oneClass, oneField) =
  let print format = fprintf out_chan format in
    print "                new Relation(\"%s\", \"%s\", \"%s\"),\n" manyField oneClass oneField

(* ------------------- category: http_actions *)

and gen_http_actions() =
  let out_chan = open_out (Filename.concat destdir "HTTP_actions.cs") in
  let print format = fprintf out_chan format in

  let print_header() = print
"%s

using System;
using System.Text;
using System.Net;

namespace XenAPI
{
    public partial class HTTP_actions
    {
        private static void Get(HTTP.DataCopiedDelegate dataCopiedDelegate, HTTP.FuncBool cancellingDelegate, int timeout_ms,
            string hostname, string remotePath, IWebProxy proxy, string localPath, params object[] args)
        {
            HTTP.Get(dataCopiedDelegate, cancellingDelegate, HTTP.BuildUri(hostname, remotePath, args), proxy, localPath, timeout_ms);
        }

        private static void Put(HTTP.UpdateProgressDelegate progressDelegate, HTTP.FuncBool cancellingDelegate, int timeout_ms,
            string hostname, string remotePath, IWebProxy proxy, string localPath, params object[] args)
        {
            HTTP.Put(progressDelegate, cancellingDelegate, HTTP.BuildUri(hostname, remotePath, args), proxy, localPath, timeout_ms);
        }"
    (banner())
  in

  let print_footer() = print "\n    }\n}\n" in

  let decl_of_sdkarg = function
      String_query_arg s -> "string " ^ (escaped s)
    | Int64_query_arg s -> "long " ^ (escaped s)
    | Bool_query_arg s -> "bool " ^ (escaped s)
    | Varargs_query_arg -> "params string[] args /* alternate names & values */"
  in

  let use_of_sdkarg =  function
      String_query_arg s
    | Int64_query_arg s
    | Bool_query_arg s -> "\"" ^ s ^ "\", " ^ (escaped s)  (* "s", s *)
    | Varargs_query_arg -> "args"
  in

  let string1 = function
      Get -> "HTTP.DataCopiedDelegate dataCopiedDelegate"
    | Put -> "HTTP.UpdateProgressDelegate progressDelegate"
    | _ -> failwith "Unimplemented HTTP method"
  in

  let string2 = function
      Get -> "Get(dataCopiedDelegate"
    | Put -> "Put(progressDelegate"
    | _ -> failwith "Unimplemented HTTP method"
  in

  let enhanced_args args =
    [String_query_arg "task_id"; String_query_arg "session_id"] @ args
  in

  let print_one_action_core name meth uri sdkargs =
    print "

        public static void %s(%s, HTTP.FuncBool cancellingDelegate, int timeout_ms,
            string hostname, IWebProxy proxy, string path, %s)
        {
            %s, cancellingDelegate, timeout_ms, hostname, \"%s\", proxy, path,
                %s);
        }"
      name
      (string1 meth)
      (String.concat ", " (List.map decl_of_sdkarg (enhanced_args sdkargs)))
      (string2 meth)
      uri
      (String.concat ", " (List.map use_of_sdkarg (enhanced_args sdkargs)))
  in

  let print_one_action(name, (meth, uri, sdk, sdkargs, _, _)) =
    match sdk with
      | false -> ()
      | true -> print_one_action_core name meth uri sdkargs
  in

  print_header(); 
  List.iter print_one_action http_actions;
  print_footer();

(* ------------------- category: classes *)


and gen_class cls =
  let out_chan = open_out (Filename.concat destdir (exposed_class_name cls.name)^".cs")
  in
    finally (fun () -> gen_class_gui out_chan cls)
            (fun () -> close_out out_chan)

(* XenAPI autogen class generator for GUI bindings *)
and gen_class_gui out_chan cls =
  let print format = fprintf out_chan format in
  let exposed_class_name = exposed_class_name cls.name in
  let messages = List.filter (fun msg -> (String.compare msg.msg_name "get_all_records_where" != 0)) cls.messages in
  let contents = cls.contents in
  let publishedInfo = get_published_info_class cls in

  print
"%s

using System;
using System.Collections;
using System.Collections.Generic;

using CookComputing.XmlRpc;


namespace XenAPI
{
    /// <summary>
    /// %s%s
    /// </summary>
    public partial class %s : XenObject<%s>
    {"

  (banner())
  cls.description (if publishedInfo = "" then "" else "\n    /// "^publishedInfo)
  exposed_class_name exposed_class_name;

  (* Generate bits for Message type *)
  if cls.name = "message" then
    begin
    print "
        public enum MessageType { %s };

        public MessageType Type
        {
            get
            {
                switch (this.name)
                {"
      (String.concat ", " ((List.map fst !Api_messages.msgList) @ ["unknown"]));
    
    List.iter (fun x -> print "
                    case \"%s\":
                        return MessageType.%s;" x x) (List.map fst !Api_messages.msgList);

    print
"
                    default:
                        return MessageType.unknown;
                }
            }
        }
"
    end;

  print
"
        public %s()
        {
        }
"
  exposed_class_name;

  let print_internal_ctor = function
    | []            -> ()
    | _ as cnt -> print
"
        public %s(%s)
        {
            %s
        }
"
  exposed_class_name
  (String.concat ",\n            " (List.rev (get_constructor_params cnt)))
  (String.concat "\n            " (List.rev (get_constructor_body cnt)))
  in print_internal_ctor contents;

  print
"
        /// <summary>
        /// Creates a new %s from a Proxy_%s.
        /// </summary>
        /// <param name=\"proxy\"></param>
        public %s(Proxy_%s proxy)
        {
            this.UpdateFromProxy(proxy);
        }

        public override void UpdateFrom(%s update)
        {
"
  exposed_class_name exposed_class_name
  exposed_class_name exposed_class_name
  exposed_class_name;

  List.iter (gen_updatefrom_line out_chan) contents;

  print
"        }

        internal void UpdateFromProxy(Proxy_%s proxy)
        {
"
  exposed_class_name;

  List.iter (gen_constructor_line out_chan) contents;

  print
"        }

        public Proxy_%s ToProxy()
        {
            Proxy_%s result_ = new Proxy_%s();
"
  exposed_class_name
  exposed_class_name exposed_class_name;

  List.iter (gen_to_proxy_line out_chan) contents;

  print
"            return result_;
        }
";

  print "
        /// <summary>
        /// Creates a new %s from a Hashtable.
        /// </summary>
        /// <param name=\"table\"></param>
        public %s(Hashtable table)
        {
"
  exposed_class_name exposed_class_name;

  List.iter (gen_hashtable_constructor_line out_chan) contents;

  print
"        }

        ";

  let is_current_ops = function
    | Field f -> (full_name f = "current_operations")
    | _ -> false
  in
  let (current_ops, other_contents) = List.partition is_current_ops contents in
  let check_refs = "if (ReferenceEquals(null, other))
                return false;
            if (ReferenceEquals(this, other))
                return true;" in
  (match current_ops with
    | [] ->
      print "public bool DeepEquals(%s other)
        {
            %s

            return " exposed_class_name check_refs
    | _ ->
      print "public bool DeepEquals(%s other, bool ignoreCurrentOperations)
        {
            %s

            if (!ignoreCurrentOperations && !Helper.AreEqual2(this.current_operations, other.current_operations))
                return false;

            return " exposed_class_name check_refs);

  (match other_contents with
     | [] -> print "false"
     | _ ->  print "%s" (String.concat " &&
                " (List.map gen_equals_condition other_contents)));

  print ";
        }

        public override string SaveChanges(Session session, string opaqueRef, %s server)
        {
            if (opaqueRef == null)
            {
"
  exposed_class_name;

  if cls.gen_constructor_destructor then
    print
"                Proxy_%s p = this.ToProxy();
                return session.proxy.%s_create(session.uuid, p).parse();
"
    exposed_class_name (String.lowercase exposed_class_name)
    else
      print
"                System.Diagnostics.Debug.Assert(false, \"Cannot create instances of this type on the server\");
                return \"\";
";

      print
"            }
            else
            {
";

    gen_save_changes out_chan exposed_class_name messages contents;

    print
"
            }
        }";
 
  List.iter (gen_exposed_method_overloads out_chan cls) (List.filter (fun x -> not x.msg_hide_from_docs) messages);

  (* Don't create duplicate get_all_records call *)
  if not (List.exists (fun msg -> String.compare msg.msg_name "get_all_records" = 0) messages) &&
     List.mem cls.name expose_get_all_messages_for
  then gen_exposed_method out_chan cls (get_all_records_method cls.name) [];

  List.iter (gen_exposed_field out_chan cls) contents;

  print
"    }
}
";

and get_all_records_method classname = 
  { default_message with
    msg_name = "get_all_records";
    msg_params = []; 
    msg_result = Some (Map(Ref classname, Record classname), 
                  sprintf "A map from %s to %s.Record" classname classname);
    msg_doc = sprintf "Get all the %s Records at once, in a single XML RPC call" classname;
    msg_session = true; msg_async = false;
    msg_release = {opensource=["3.0.3"]; internal=["closed"; "debug"]; internal_deprecated_since=None}; 
    msg_lifecycle = [];
    msg_has_effect = false; msg_tag = Custom; 
    msg_obj_name = classname;
    msg_errors = []; msg_secret = false;
    msg_custom_marshaller = false;
    msg_no_current_operations = false;
    msg_hide_from_docs = false;
    msg_pool_internal = false;
    msg_db_only = false;
    msg_force_custom = None;
    msg_allowed_roles = None;
    msg_map_keys_roles = [];
    msg_doc_tags = [];
  };

and get_constructor_params content =
  get_constructor_params' content []

and get_constructor_params' content elements =
  match content with
    [] -> elements
    | (Field fr)::others -> get_constructor_params' others ((sprintf "%s %s" (exposed_type fr.ty) (full_name fr))::elements)
    | (Namespace (_, c))::others -> get_constructor_params' (c@others) elements

and get_constructor_body content =
  get_constructor_body' content []

and get_constructor_body' content elements =
  match content with
    [] -> elements
    | (Field fr)::others -> get_constructor_body' others ((sprintf "this.%s = %s;" (full_name fr) (full_name fr))::elements)
    | (Namespace (_, c))::others -> get_constructor_body' (c@others) elements

and gen_constructor_line out_chan content =
  let print format = fprintf out_chan format in

  match content with
      Field fr ->
          print
"            %s = %s;
" (full_name fr) (convert_from_proxy ("proxy." ^ (full_name fr)) fr.ty)

    | Namespace (_, c) -> List.iter (gen_constructor_line out_chan) c

and gen_hashtable_constructor_line out_chan content =
  let print format = fprintf out_chan format in

  match content with
    | Field fr ->
          print
"            %s = %s;
" (full_name fr) (convert_from_hashtable (full_name fr) fr.ty)

    | Namespace (_, c) -> List.iter (gen_hashtable_constructor_line out_chan) c

and gen_equals_condition content =
  match content with
    | Field fr -> "Helper.AreEqual2(this._" ^ (full_name fr) ^ ", other._" ^ (full_name fr) ^ ")"
    | Namespace (_, c) -> String.concat " &&
                " (List.map gen_equals_condition c);

and gen_updatefrom_line out_chan content =
  let print format = fprintf out_chan format in

  match content with
      Field fr ->
          print
"            %s = %s;
" (full_name fr) ("update." ^ (full_name fr))
    | Namespace (_, c) -> List.iter (gen_updatefrom_line out_chan) c

and gen_to_proxy_line out_chan content =
  let print format = fprintf out_chan format in

  match content with
      Field fr ->
          print
"            result_.%s = %s;
" (full_name fr) (convert_to_proxy (full_name fr) fr.ty)

    | Namespace (_, c) -> List.iter (gen_to_proxy_line out_chan) c

and gen_overload out_chan classname message generator =
  let methodParams = get_method_params_list message in
    match methodParams with
    | [] -> generator []
    | _  -> let paramGroups =  gen_param_groups message methodParams in
              List.iter generator paramGroups

and gen_exposed_method_overloads out_chan cls message =
  let generator = fun x -> gen_exposed_method out_chan cls message x in
  gen_overload out_chan cls.name message generator

and gen_exposed_method out_chan cls msg curParams =
  let classname = cls.name in
  let print format = fprintf out_chan format in
  let proxyMsgName = proxy_msg_name classname msg in
  let exposed_ret_type = exposed_type_opt msg.msg_result in
  let paramSignature = exposed_params msg classname curParams in
  let paramsDoc = get_params_doc msg classname curParams in
  let callParams = exposed_call_params msg classname curParams in
  let publishInfo = get_published_info_message msg cls in
  let deprecatedInfo = get_deprecated_info_message msg in
  let deprecatedAttribute = get_deprecated_attribute msg in 
  let deprecatedInfoString = (if deprecatedInfo = "" then "" else "\n        /// "^deprecatedInfo) in
  let deprecatedAttributeString = (if deprecatedAttribute = "" then "" else "\n        "^deprecatedAttribute) in
  print "
        /// <summary>
        /// %s%s%s
        /// </summary>%s%s
        public static %s %s(%s)
        {
            %s;
        }\n"
    msg.msg_doc (if publishInfo = "" then "" else "\n        /// "^publishInfo)
    deprecatedInfoString
    paramsDoc
    deprecatedAttributeString 
    exposed_ret_type  
    msg.msg_name paramSignature
    (convert_from_proxy_opt (sprintf "session.proxy.%s(%s).parse()" proxyMsgName callParams) msg.msg_result);
  if msg.msg_async then 
    print "
        /// <summary>
        /// %s%s%s
        /// </summary>%s%s
        public static XenRef<Task> async_%s(%s)
        {
            return XenRef<Task>.Create(session.proxy.async_%s(%s).parse());
        }\n"
      msg.msg_doc (if publishInfo = "" then "" else "\n        /// "^publishInfo)
      deprecatedInfoString
      paramsDoc
      deprecatedAttributeString
      msg.msg_name paramSignature
      proxyMsgName callParams

and returns_xenobject msg =
  match msg.msg_result with
    |  Some (Record r, _) -> true
    |  _ -> false

and get_params_doc msg classname params =
  let sessionDoc = "\n        /// <param name=\"session\">The session</param>" in
  let refDoc =  if is_method_static msg then ""
                else if (msg.msg_name = "get_by_permission") then
                  sprintf "\n        /// <param name=\"_%s\">The opaque_ref of the given permission</param>" (String.lowercase classname)
                else if (msg.msg_name = "revert") then
                  sprintf "\n        /// <param name=\"_%s\">The opaque_ref of the given snapshotted state</param>" (String.lowercase classname)
                else sprintf "\n        /// <param name=\"_%s\">The opaque_ref of the given %s</param>"
                     (String.lowercase classname) (String.lowercase classname) in
  String.concat "" (sessionDoc::(refDoc::(List.map (fun x -> get_param_doc msg x) params)))

and get_param_doc msg x =
  let publishInfo = get_published_info_param msg x in
    sprintf "\n        /// <param name=\"_%s\">%s%s</param>" (String.lowercase x.param_name) x.param_doc
      (if publishInfo = "" then "" else " "^publishInfo)

and exposed_params message classname params =
  let exposedParams = List.map exposed_param params in
  let refParam = sprintf "string _%s" (String.lowercase classname) in
  let exposedParams = if is_method_static message then exposedParams else refParam::exposedParams in
  String.concat ", " ("Session session"::exposedParams)

and exposed_param p =
      sprintf "%s _%s" (internal_type p.param_type) (String.lowercase p.param_name)

and exposed_call_params message classname params =
  let exposedParams = List.map exposed_call_param params in
  let name = String.lowercase classname in
  let refParam = sprintf "(_%s != null) ? _%s : \"\"" name name in
  let exposedParams = if is_method_static message then exposedParams else refParam::exposedParams in
  String.concat ", " ("session.uuid"::exposedParams)

and exposed_call_param p =
  convert_to_proxy (sprintf "_%s" (String.lowercase p.param_name)) p.param_type


(* 'messages' are methods, 'contents' are fields *)
and gen_save_changes out_chan exposed_class_name messages contents =
  let fields = List.flatten (List.map flatten_content contents) in
  let fields2 = List.filter (fun fr -> fr.qualifier == RW && (not (List.mem "public" fr.full_name))) fields in
  (* Find all StaticRO fields which have corresponding messages (methods) of the form set_readonlyField *)
  let readonlyFieldsWithSetters = List.filter (fun field -> field.qualifier == StaticRO && List.exists (fun msg -> msg.msg_name = (String.concat "" ["set_"; full_name field])) messages) fields in
  let length = List.length fields2 + List.length readonlyFieldsWithSetters in
  let print format = fprintf out_chan format in
  if length == 0 then
    print 
"              throw new InvalidOperationException(\"This type has no read/write properties\");"
  else 
    (List.iter (gen_save_changes_to_field out_chan exposed_class_name) fields2;
    (* Generate calls to any set_ methods *)
     List.iter (gen_save_changes_to_field out_chan exposed_class_name) readonlyFieldsWithSetters;
    print
"
                return null;";)


and flatten_content content =
  match content with
      Field fr -> [ fr ]
    | Namespace (_, c) -> List.flatten (List.map flatten_content c)


and gen_save_changes_to_field out_chan exposed_class_name fr =
  let print format = fprintf out_chan format in
  let full_name_fr = full_name fr in
  let equality =
    (* Use AreEqual2 - see CA-19220 *)
    sprintf "Helper.AreEqual2(_%s, server._%s)" full_name_fr full_name_fr
  in
    print
"                if (!%s)
                {
                    %s.set_%s(session, opaqueRef, _%s);
                }
" equality exposed_class_name full_name_fr full_name_fr


and ctor_call classname =
  let fields = Datamodel_utils.fields_of_obj (Dm_api.get_obj_by_name api ~objname:classname) in
  let fields2 = ctor_fields fields in
  let args = (List.map (fun fr -> "p." ^ (full_name fr)) fields2) in
  String.concat ", " ("session.uuid" :: args)


and gen_exposed_field out_chan cls content =
  match content with
    | Field fr ->
        let print format = fprintf out_chan format in
        let full_name_fr = full_name fr in
        let comp = sprintf "!Helper.AreEqual(value, _%s)" full_name_fr in
        let publishInfo = get_published_info_field fr cls in
        
          print "
        /// <summary>
        /// %s%s
        /// </summary>
        public virtual %s %s
        {
            get { return _%s; }" fr.field_description
  (if publishInfo = "" then "" else "\n        /// "^publishInfo) 
  (exposed_type fr.ty) full_name_fr full_name_fr;

              print
"
            set
            {
                if (%s)
                {
                    _%s = value;
                    Changed = true;
                    NotifyPropertyChanged(\"%s\");
                }
            }
        }" comp full_name_fr full_name_fr;

              print "
        private %s _%s;\n" (exposed_type fr.ty) full_name_fr

	  | Namespace (_, c) -> List.iter (gen_exposed_field out_chan cls) c

(* ------------------- category: gui bits *)
	
and gen_object_downloader classes =
  let out_chan = open_out (Filename.concat destdir "XenObjectDownloader.cs")
  in
    finally (fun () -> gen_xenobjectdownloader out_chan classes)
            (fun () -> close_out out_chan)

and gen_xenobjectdownloader out_chan classes =
  let print format = fprintf out_chan format in
    print
"%s

using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Runtime.Serialization;
using XenAdmin.Core;

namespace XenAPI
{
    [Serializable]
    public class EventNextBlockedException : Exception
    {
        public EventNextBlockedException() : base() { }

        public EventNextBlockedException(string message) : base(message) { }

        public EventNextBlockedException(string message, Exception exception) : base(message, exception) { }

        protected EventNextBlockedException(SerializationInfo info, StreamingContext context) : base(info, context) { }
    }

    public static class XenObjectDownloader
    {
        private static readonly log4net.ILog log = log4net.LogManager.GetLogger(System.Reflection.MethodBase.GetCurrentMethod().DeclaringType);

        private const double EVENT_FROM_TIMEOUT = 30; // 30 seconds

        /// <summary>
        /// Whether to use the legacy event system (event.next); the new system is event.from.
        /// </summary>
        /// <param name=\"session\"></param>
        public static bool LegacyEventSystem(Session session)
        {
            return session.APIVersion <= API_Version.API_1_9;
        }

        /// <sumary>
        /// Gets all objects from the server. Used in order to fill the cache.
        /// This function implements the new event system, available from in API version 1.9.
        /// In the new event system, (GetAllRecords + GetEvents) sequence will replace (RegisterForEvents + DownloadObjects + GetNextEvents).
        /// </summary>
        /// <param name=\"session\">The session over which to download the objects. Must not be null.</param>
        /// <param name=\"changes\">The queue that the ObjectChanges will be put into. Must not be null.</param>
        /// <param name=\"cancelled\">Used by GetEvents().</param>
        /// <param name=\"legacyEventSystem\">True if legacy event system (event.next) should to be used.</param>
        /// <param name=\"token\">Used by GetEvents().</param>
        public static void GetAllObjects(Session session, LockFreeQueue<ObjectChange> changes, HTTP.FuncBool cancelled, bool legacyEventSystem, ref string token)
        {
            if (legacyEventSystem)
            {
                DownloadObjects(session, changes);
                return;
            }
            
            // download objects that are not covered by event.from(), e.g. Roles
            List<ObjectChange> list = new List<ObjectChange>();
            Download_Role(session, list);
            foreach (ObjectChange o in list)
                changes.Enqueue(o);

            // get all objects with event.from()
            token = \"\"; 
            GetEvents(session, changes, cancelled, false, ref token);
        }

        /// <summary>
        /// Blocks until events are sent on the session, or timeout is reached, then processes any received events and adds them
        /// to eventQueue. This function implements the new event system, available in API version 1.9. 
        /// In the new event system, (GetAllRecords + GetEvents) sequence will replace (RegisterForEvents + DownloadObjects + GetNextEvents).
        /// </summary>
        /// <param name=\"session\"></param>
        /// <param name=\"eventQueue\"></param>
        /// <param name=\"cancelled\"></param>
        /// <param name=\"legacyEventSystem\">True if legacy event system (event.next) should be used.</param>
        /// <param name=\"token\">A token used by event.from(). 
        /// It should be the empty string when event.from is first called, which is the replacement of get_all_records.
        /// </param>
        public static void GetEvents(Session session, LockFreeQueue<ObjectChange> eventQueue, HTTP.FuncBool cancelled, bool legacyEventSystem, ref string token)
        {
            if (legacyEventSystem)
            {
                GetNextEvents(session, eventQueue, cancelled);
                return;
            }

            Proxy_Event[] proxyEvents;
            try
            {
                var classes = new [] { \"*\" }; // classes that we are interested in receiving events from
                var eventResult = Event.from(session, classes, token, EVENT_FROM_TIMEOUT);
                token = eventResult.token;
                proxyEvents = eventResult.events;
            }
            catch (WebException e)
            {
                // Catch timeout, and turn it into an EventNextBlockedException so we can recognise it later (CA-33145)
                if (e.Status == WebExceptionStatus.Timeout)
                    throw new EventNextBlockedException();
                else
                    throw;
            }

            if (cancelled())
                return;

            //We want to do the marshalling on this bg thread so as not to block the gui thread
            foreach (Proxy_Event proxyEvent in proxyEvents)
            {
                ObjectChange objectChange = ProcessEvent(proxyEvent);

                if (objectChange != null)
                    eventQueue.Enqueue(objectChange);
            }
        }
        
        public static void RegisterForEvents(Session session)
        {
            Event.register(session, new string[] { \"*\" });
        }
       
        /// <summary>
        /// Blocks until events are sent on the session, then processes any received events and adds them
        /// to eventQueue. Will always add at least one event to eventQueue.
        /// This function should be used with XenServer up to version 6.0. For XenServer higher than 6.0, GetEvents() should be used instead.
        /// </summary>
        /// <param name=\"session\"></param>
        /// <param name=\"eventQueue\"></param>
        /// <param name=\"cancelled\"></param>
        public static void GetNextEvents(Session session, LockFreeQueue<ObjectChange> eventQueue, HTTP.FuncBool cancelled)
        {
            Proxy_Event[] proxyEvents;

            try
            {
                proxyEvents = Event.next(session);
            }
            catch (WebException e)
            {
                // Catch timeout, and turn it into an EventNextBlockedException so we can recognise it later (CA-33145)
                if (e.Status == WebExceptionStatus.Timeout)
                    throw new EventNextBlockedException();
                else
                    throw;
            }

            if (proxyEvents.Length == 0)
                throw new IOException(\"Event.next() returned no events; the server is misbehaving.\");

            if (cancelled())
                return;

            //We want to do the marshalling on this bg thread so as not to block the gui thread
            foreach (Proxy_Event proxyEvent in proxyEvents)
            {
                ObjectChange objectChange = ProcessEvent(proxyEvent);

                if (objectChange != null)
                    eventQueue.Enqueue(objectChange);
            }
        }

        /// <summary>
        /// Returns null if we get an event we're not interested in, or an unparseable event (e.g. for an object type we don't know about).
        /// </summary>
        /// <param name=\"proxyEvent\"></param>
        /// <returns></returns>
        private static ObjectChange ProcessEvent(Proxy_Event proxyEvent)
        {
            switch (proxyEvent.class_.ToLowerInvariant())
            {
" Licence.bsd_two_clause;

    (* Ignore events on untracked objects *)
    List.iter (
      fun obj ->
        let exposed_class_name = exposed_class_name obj.name in
          print
"                case \"%s\":
"
          (String.lowercase exposed_class_name)
    ) (List.filter (fun x -> not (cached_by_gui x)) classes);

    print
"                    // We don't track events on these objects
                    return null;

                default:
                    Type typ = Marshalling.GetXenAPIType(proxyEvent.class_);

                    if (typ == null)
                    {
                        log.DebugFormat(\"Unknown {0} event for class {1}.\", proxyEvent.operation, proxyEvent.class_);
                        return null;
                    }

                    switch (proxyEvent.operation)
                    {
                        case \"add\":
                        case \"mod\":
                            return new ObjectChange(typ, proxyEvent.opaqueRef, Marshalling.convertStruct(typ, (Hashtable)proxyEvent.snapshot));
                        case \"del\":
                            return new ObjectChange(typ, proxyEvent.opaqueRef, null);

                        default:
                            log.DebugFormat(\"Unknown event operation {0} for opaque ref {1}\", proxyEvent.operation, proxyEvent.opaqueRef);
                            return null;
                    }
            }
        }
";

    print "
        /// <summary>
        /// Downloads all objects from the server. Used in order to fill the cache.
        /// This function should be used with XenServer up to version 6.0. For XenServer higher than 6.0, GetAllObjects() should be used instead.
        /// </summary>
        /// <param name=\"session\">The session over which to download the objects. Must not be null.</param>
        /// <param name=\"changes\">The queue that the ObjectChanges will be put into. Must not be null.</param>
        public static void DownloadObjects(Session session, LockFreeQueue<ObjectChange> changes)
        {
            List<ObjectChange> list = new List<ObjectChange>();

";

    (* Generate Download_T methods for Rio objects *)
    List.iter (
      fun obj ->
        if
          List.mem rel_rio obj.obj_release.internal
          && List.exists (fun x -> x.msg_name = "get_all") obj.messages
          && cached_by_gui obj
        then
          print
"            Download_%s(session, list);
"
          (exposed_class_name obj.name);
    ) classes;

    print
"
            if (session.APIVersion >= API_Version.API_1_2)
            {
                // Download Miami-only objects
";

    (* And for Miami objects *)
    List.iter (
      fun obj ->
        if
          List.mem rel_miami obj.obj_release.internal
          && not (List.mem rel_rio obj.obj_release.internal)
          && List.exists (fun x -> x.msg_name = "get_all") obj.messages
          && cached_by_gui obj
        then
          print
"                Download_%s(session, list);
"
          (exposed_class_name obj.name);
    ) classes;

    print
"            }

            if (session.APIVersion >= API_Version.API_1_3)
            {
                // Download Orlando-only objects
";

    (* And for Orlando objects *)
    List.iter (
      fun obj ->
        if
          List.mem rel_orlando obj.obj_release.internal
          && not (List.mem rel_miami obj.obj_release.internal)
          && not (List.mem rel_rio obj.obj_release.internal)
          && List.exists (fun x -> x.msg_name = "get_all") obj.messages
          && cached_by_gui obj
        then
          print
"                Download_%s(session, list);
"
          (exposed_class_name obj.name);
    ) classes;

    print
"            }

            if (session.APIVersion >= API_Version.API_1_6)
            {
                // Download George-only objects
";

    (* And for George objects *)
    List.iter (
      fun obj ->
        if
          List.mem rel_george obj.obj_release.internal
          && not (List.mem rel_orlando obj.obj_release.internal)
          && not (List.mem rel_miami obj.obj_release.internal)
          && not (List.mem rel_rio obj.obj_release.internal)
          && List.exists (fun x -> x.msg_name = "get_all") obj.messages
          && cached_by_gui obj
        then
          print
"                Download_%s(session, list);
"
          (exposed_class_name obj.name);
    ) classes;

    print
"            }

            if (session.APIVersion >= API_Version.API_1_7)
            {
                // Download Midnight Ride-only objects
";

    (* And for Midnight Ride objects *)
    List.iter (
      fun obj ->
        if
          List.mem rel_midnight_ride obj.obj_release.internal
          && not (List.mem rel_george obj.obj_release.internal)
          && not (List.mem rel_orlando obj.obj_release.internal)
          && not (List.mem rel_miami obj.obj_release.internal)
          && not (List.mem rel_rio obj.obj_release.internal)
          && List.exists (fun x -> x.msg_name = "get_all") obj.messages
          && cached_by_gui obj
        then
          print
"                Download_%s(session, list);
"
          (exposed_class_name obj.name);
    ) classes;

print 
"            }

            if (session.APIVersion >= API_Version.API_1_8)
            {
                // Download Cowley-only objects
";

    (* And for Cowley objects *)
    List.iter (
      fun obj ->
        if
          List.mem rel_cowley obj.obj_release.internal
          && not (List.mem rel_midnight_ride obj.obj_release.internal)
          && not (List.mem rel_george obj.obj_release.internal)
          && not (List.mem rel_orlando obj.obj_release.internal)
          && not (List.mem rel_miami obj.obj_release.internal)
          && not (List.mem rel_rio obj.obj_release.internal)
          && List.exists (fun x -> x.msg_name = "get_all") obj.messages
          && cached_by_gui obj
        then
          print
"                Download_%s(session, list);
"
          (exposed_class_name obj.name);
    ) classes;

print 
"            }

            if (session.APIVersion >= API_Version.API_1_9)
            {
                // Download Boston-only objects
";

    (* And for Boston objects *)
    List.iter (
      fun obj ->
        if
          List.mem rel_boston obj.obj_release.internal
          && not (List.mem rel_cowley obj.obj_release.internal)
          && not (List.mem rel_midnight_ride obj.obj_release.internal)
          && not (List.mem rel_george obj.obj_release.internal)
          && not (List.mem rel_orlando obj.obj_release.internal)
          && not (List.mem rel_miami obj.obj_release.internal)
          && not (List.mem rel_rio obj.obj_release.internal)
          && List.exists (fun x -> x.msg_name = "get_all") obj.messages
          && cached_by_gui obj
        then
          print
"                Download_%s(session, list);
"
          (exposed_class_name obj.name);
    ) classes;

    print
"            }

            foreach (ObjectChange o in list)
            {
                changes.Enqueue(o);
            }
        }
";



    (* Generate the Download_T methods *)
    List.iter (fun obj -> 
      if (List.exists (fun x -> x.msg_name = "get_all") obj.messages)
        && (List.exists (fun rel -> rel = rel_boston
                                || rel = rel_cowley
                                || rel = rel_midnight_ride
                                || rel = rel_george
                                || rel = rel_orlando
                                || rel = rel_miami
                                || rel = rel_rio) obj.obj_release.internal)
        && cached_by_gui obj
      then
        gen_download_method out_chan obj
    ) classes;

    print "    }
}
";

and gen_download_method out_chan 
{name=classname; messages=messages; contents=contents; gen_constructor_destructor=gen_constructor_destructor } =
  let print format = fprintf out_chan format in
  let exposed_class_name = exposed_class_name classname in
    print
"
        private static void Download_%s(Session session, List<ObjectChange> changes)
        {
            Dictionary<XenRef<%s>, %s> records = %s.get_all_records(session);
            foreach (KeyValuePair<XenRef<%s>, %s> entry in records)
                changes.Add(new ObjectChange(typeof(%s), entry.Key.opaque_ref, entry.Value));
        }
"
  exposed_class_name
  exposed_class_name exposed_class_name exposed_class_name
  exposed_class_name exposed_class_name
  exposed_class_name;

(* ------------------- category: proxy classes *)


and gen_proxy() =
  let out_chan = open_out (Filename.concat destdir "Proxy.cs")
  in
    finally (fun () -> gen_proxy' out_chan)
            (fun () -> close_out out_chan)


and gen_proxy' out_chan =
  let print format = fprintf out_chan format in

(* NB the Event methods below must be manually written out since the class is hand-written not autogenerated *)
  print "%s

using System;
using System.Collections;
using System.Collections.Generic;

using CookComputing.XmlRpc;


namespace XenAPI
{
    public partial interface Proxy : IXmlRpcProxy
    {
        [XmlRpcMethod(\"event.get_record\")]
        Response<Proxy_Event>
        event_get_record(string session, string _event);

        [XmlRpcMethod(\"event.get_by_uuid\")]
        Response<string>
        event_get_by_uuid(string session, string _uuid);

        [XmlRpcMethod(\"event.get_id\")]
        Response<string>
        event_get_id(string session, string _event);

        [XmlRpcMethod(\"event.set_id\")]
        Response<string>
        event_set_id(string session, string _event, string _id);

        [XmlRpcMethod(\"event.register\")]
        Response<string>
        event_register(string session, string [] _classes);

        [XmlRpcMethod(\"event.unregister\")]
        Response<string>
        event_unregister(string session, string [] _classes);

        [XmlRpcMethod(\"event.next\")]
        Response<Proxy_Event[]>
        event_next(string session);

        [XmlRpcMethod(\"event.from\")]
        Response<Events>
        event_from(string session, string [] _classes, string _token, double _timeout);
" (banner());

  List.iter
    (fun x -> if proxy_generated x then gen_proxy_for_class out_chan x) classes;
  print
"    }

";

  List.iter (fun x -> if proxy_generated x then gen_proxyclass out_chan x) classes;

  print
"}
"


and gen_proxy_for_class out_chan {name=classname; messages=messages} =
  (* Generate each of the proxy methods (but not the internal-only ones that are marked hide_from_docs) *)
  List.iter (gen_proxy_method_overloads out_chan classname) (List.filter (fun x -> not x.msg_hide_from_docs) messages);
  if (not (List.exists (fun msg -> String.compare msg.msg_name "get_all_records" = 0) messages)) then
    gen_proxy_method out_chan classname (get_all_records_method classname) []

and gen_proxy_method_overloads out_chan classname message =
  let generator = fun x -> gen_proxy_method out_chan classname message x in
  gen_overload out_chan classname message generator

and gen_proxy_method out_chan classname message params =
  let print format = fprintf out_chan format in
  let proxy_ret_type = proxy_type_opt message.msg_result in
  let proxy_msg_name = proxy_msg_name classname message in
  let proxyParams = proxy_params message classname params in

  print "
        [XmlRpcMethod(\"%s.%s\")]
        Response<%s>
        %s(%s);
" classname message.msg_name
  proxy_ret_type 
  proxy_msg_name proxyParams;

  if message.msg_async then
    print "
        [XmlRpcMethod(\"Async.%s.%s\")]
        Response<string>
        async_%s(%s);
" classname message.msg_name
  proxy_msg_name proxyParams;


and proxy_params message classname params =
  let refParam = sprintf "string _%s" (String.lowercase classname) in
  let args = List.map proxy_param params in
  let args = if is_method_static message then args else refParam::args in
  let args = if message.msg_session then "string session" :: args else args in
  String.concat ", " args

and proxy_param p =
  sprintf "%s _%s" (proxy_type p.param_type) (String.lowercase p.param_name)


and ctor_fields fields =
  List.filter (function { DT.qualifier = (DT.StaticRO | DT.RW) } -> true | _ -> false) fields
    

and gen_proxyclass out_chan {name=classname; contents=contents} =
  let print format = fprintf out_chan format in

  print
"    [XmlRpcMissingMapping(MappingAction.Ignore)]
    public class Proxy_%s
    {
" (exposed_class_name classname);

  List.iter (gen_proxy_field out_chan) contents;

print
"    }

"


and gen_proxy_field out_chan content =
  match content with
      Field fr ->
        let print format = fprintf out_chan format in

          print
"        public %s %s;
" (proxy_type fr.ty) (full_name fr)

    | Namespace (_, c) -> List.iter (gen_proxy_field out_chan) c


(* ------------------- category: enums *)


and gen_enum = function
    Enum(name, contents) ->
      let out_chan = open_out (Filename.concat destdir (name ^ ".cs"))
      in
        finally (fun () -> gen_enum' name contents out_chan)
                (fun () -> close_out out_chan)
  | _ -> assert false


and gen_enum' name contents out_chan =
  let print format = fprintf out_chan format in

  print "%s

using System;
using System.Collections.Generic;


namespace XenAPI
{
    public enum %s
    {
        " (banner()) name;

  print "%s" (joined ", " gen_enum_line contents);

  if not (has_unknown_entry contents) then
    print ", unknown";

  print "
    }

    public static class %s_helper
    {
        public static string ToString(%s x)
        {
            switch (x)
            {
" name name;

  List.iter (fun (wire, _) ->
    print "                case %s.%s:\n                    return \"%s\";\n" name (enum_of_wire wire) wire
  ) contents;

  print "                default:
                    return \"unknown\";
            }
        }
    }
}
"


and gen_enum_line content =
  enum_of_wire (fst content)


and has_unknown_entry contents =
  let rec f = function
    | x :: xs -> if String.lowercase (fst x) = "unknown" then true else f xs
    | []      -> false
  in
    f contents


(* ------------------- category: maps *)


and gen_maps() =
  let out_chan = open_out (Filename.concat destdir "Maps.cs")
  in
  finally (fun () -> gen_maps' out_chan)
          (fun () -> close_out out_chan)


and gen_maps' out_chan =
  let print format = fprintf out_chan format in

  print "%s

using System;
using System.Collections;
using System.Collections.Generic;


namespace XenAPI
{
    internal class Maps
    {
" (banner());

  TypeSet.iter (gen_map_conversion out_chan) !maps;

print "
    }
}
"

and gen_map_conversion out_chan = function
    Map(l, r) ->
      let print format = fprintf out_chan format in
      let el = exposed_type l in
      let el_literal = exposed_type_as_literal l in
      let er = exposed_type r in
      let er_literal = exposed_type_as_literal r in

      print
"        internal static Dictionary<%s, %s>
        convert_from_proxy_%s_%s(Object o)
        {
            Hashtable table = (Hashtable)o;
            Dictionary<%s, %s> result = new Dictionary<%s, %s>();
            if (table != null)
            {
                foreach (string key in table.Keys)
                {
                    try
                    {
                        %s k = %s;
                        %s v = %s;
                        result[k] = v;
                    }
                    catch
                    {
                        continue;
                    }
                }
            }
            return result;
        }

        internal static Hashtable
        convert_to_proxy_%s_%s(Dictionary<%s, %s> table)
        {
            CookComputing.XmlRpc.XmlRpcStruct result = new CookComputing.XmlRpc.XmlRpcStruct();
            if (table != null)
            {
                foreach (%s key in table.Keys)
                {
                    try
                    {
                        %s k = %s;
                        %s v = %s;
                        result[k] = v;
                    }
                    catch
                    {
                        continue;
                    }
                }
            }
            return result;
        }

" el er (sanitise_function_name el_literal) (sanitise_function_name er_literal)
  el er el er
  el (convert_from_proxy_never_null_string "key" l)
  er (convert_from_proxy_hashtable_value "table[key]" r)
  (sanitise_function_name el_literal) (sanitise_function_name er_literal) el er el
  (proxy_type l) (convert_to_proxy "key" l)
  (proxy_type r) (convert_to_proxy "table[key]" r)
(***)

  | _ -> assert false


(* ------------------- category: utility *)


and proxy_type_opt = function
    Some (typ, _) -> proxy_type typ
  | None -> "string"


and proxy_type = function
  | String              -> "string"
  | Int                 -> "string"
  | Float               -> "double"
  | Bool                -> "bool"
  | DateTime            -> "DateTime"
  | Ref name            -> "string"
  | Set (Record name)   -> "Proxy_" ^ exposed_class_name name ^ "[]"
  | Set _               -> "string []"
  | Enum _              -> "string"
  | Map _               -> "Object"
  | Record name         -> "Proxy_" ^ exposed_class_name name

and exposed_type_opt = function
    Some (typ, _) -> exposed_type typ
  | None -> "void"

and exposed_type = function
  | String                  -> "string"
  | Int                     -> "long"
  | Float                   -> "double"
  | Bool                    -> "bool"
  | DateTime                -> "DateTime"
  | Ref name                -> sprintf "XenRef<%s>" (exposed_class_name name)
  | Set(Ref name)           -> sprintf "List<XenRef<%s>>" (exposed_class_name name)
  | Set(Enum(name, _) as x) -> enums := TypeSet.add x !enums;
                               sprintf "List<%s>" name
  | Set(Int)                -> "long[]"
  | Set(String)             -> "string[]"
  | Enum(name, _) as x      -> enums := TypeSet.add x !enums; name
  | Map(u, v)               -> sprintf "Dictionary<%s, %s>" (exposed_type u)
                                                            (exposed_type v)
  | Record name             -> exposed_class_name name
  | Set(Record name)        -> sprintf "List<%s>" (exposed_class_name name)
  | _                       -> assert false


and internal_type = function
  | Ref name                -> (* THIS SHOULD BE: Printf.sprintf "XenRef<%s>" name *) "string"
  | Set(Ref name)           -> Printf.sprintf "List<XenRef<%s>>" (exposed_class_name name)
  | x                       -> exposed_type x


and exposed_type_as_literal = function
  | Set(String)             -> "string_array"
  | Map(u, v)               -> sprintf "Dictionary_%s_%s" (exposed_type u) (exposed_type v)
  | x                       -> exposed_type x

and convert_from_proxy_opt thing = function
    Some (typ, _) -> "return " ^ simple_convert_from_proxy thing typ
  | None -> thing

and convert_from_proxy_hashtable_value thing ty =
  match ty with
  | Set(String)         -> sprintf "%s == null ? new string[] {} : Array.ConvertAll<object, string>((object[])%s, Convert.ToString)" thing thing
  | _                   -> convert_from_proxy thing ty

and convert_from_proxy thing ty = (*function*)
  match ty with
  | DateTime            -> thing
  | Bool                -> simple_convert_from_proxy thing ty
  | Float               -> simple_convert_from_proxy thing ty
  | Int                 -> sprintf "%s == null ? 0 : %s" thing (simple_convert_from_proxy thing ty)
  | Set(String)         -> sprintf "%s == null ? new string[] {} : %s" thing (simple_convert_from_proxy thing ty)
  | Enum(name, _)       -> sprintf "%s == null ? (%s) 0 : %s" thing name (simple_convert_from_proxy thing ty)
  | _                   -> sprintf "%s == null ? null : %s" thing (simple_convert_from_proxy thing ty)

and convert_from_proxy_never_null_string thing ty = (* for when 'thing' is never null and is a string - i.e. it is a key in a hashtable *)
  match ty with
  | DateTime            -> thing
  | String              -> thing
  | Int                 -> sprintf "long.Parse(%s)" thing
  | _                   -> simple_convert_from_proxy thing ty

and convert_from_hashtable fname ty =
  let field = sprintf "\"%s\"" fname in
    match ty with
      | DateTime            -> sprintf "Marshalling.ParseDateTime(table, %s)" field
      | Bool                -> sprintf "Marshalling.ParseBool(table, %s)" field
      | Float               -> sprintf "Marshalling.ParseDouble(table, %s)" field
      | Int                 -> sprintf "Marshalling.ParseLong(table, %s)" field
      | Ref name            -> sprintf "Marshalling.ParseRef<%s>(table, %s)" (exposed_class_name name) field
      | String              -> sprintf "Marshalling.ParseString(table, %s)" field
      | Set(String)         -> sprintf "Marshalling.ParseStringArray(table, %s)" field
      | Set(Ref name)       -> sprintf "Marshalling.ParseSetRef<%s>(table, %s)" (exposed_class_name name) field
      | Set(Enum(name, _))  -> sprintf "Helper.StringArrayToEnumList<%s>(Marshalling.ParseStringArray(table, %s))" name field
      | Enum(name, _)       -> sprintf "(%s)Helper.EnumParseDefault(typeof(%s), Marshalling.ParseString(table, %s))" name name field
      | Map(Ref name, Record _) -> sprintf "Marshalling.ParseMapRefRecord<%s, Proxy_%s>(table, %s)" (exposed_class_name name) (exposed_class_name name) field
      | Map(u, v) as x      ->
          maps := TypeSet.add x !maps;
           sprintf "%s(Marshalling.ParseHashTable(table, %s))"
	         (sanitise_function_name (sprintf "Maps.convert_from_proxy_%s_%s" (exposed_type_as_literal u) (exposed_type_as_literal v))) field
      | Record name         -> 
          sprintf "new %s((Proxy_%s)table[%s])"
            (exposed_class_name name) (exposed_class_name name) field
      | Set(Record name)    -> 
          sprintf "Helper.Proxy_%sArrayTo%sList(Marshalling.ParseStringArray(%s))"
            (exposed_class_name name) (exposed_class_name name) field
      | Set(Int)            -> sprintf "Marshalling.ParseLongArray(table, %s)" field
      | _                   -> assert false 

and sanitise_function_name name =
  String.implode (List.filter (fun c -> c<>'>' && c<>'<' && c<>',' && c<>' ') (String.explode name))

and simple_convert_from_proxy thing ty =
   match ty with
  | DateTime            -> thing
  | Int                 -> sprintf "long.Parse((string)%s)" thing
  | Bool                -> sprintf "(bool)%s" thing
  | Float               -> sprintf "Convert.ToDouble(%s)" thing
  | Ref name            -> sprintf "XenRef<%s>.Create(%s)" (exposed_class_name name) thing
  | String              -> sprintf "(string)%s" thing
  | Set(String)         -> sprintf "(string [])%s" thing
  | Set(Ref name)       -> sprintf "XenRef<%s>.Create(%s)" (exposed_class_name name) thing 
  | Set(Enum(name, _))  -> sprintf "Helper.StringArrayToEnumList<%s>(%s)" name thing
  | Enum(name, _)       -> sprintf "(%s)Helper.EnumParseDefault(typeof(%s), (string)%s)" name name thing
  | Map(Ref name, Record _) -> sprintf "XenRef<%s>.Create<Proxy_%s>(%s)" (exposed_class_name name) (exposed_class_name name) thing
  | Map(u, v) as x      -> 
      maps := TypeSet.add x !maps;
      sprintf "%s(%s)"
      (sanitise_function_name (sprintf "Maps.convert_from_proxy_%s_%s" (exposed_type_as_literal u) (exposed_type_as_literal v))) thing
  | Record name         -> 
      sprintf "new %s((Proxy_%s)%s)"
      (exposed_class_name name) (exposed_class_name name) thing
  | Set(Record name)    -> 
      sprintf "Helper.Proxy_%sArrayTo%sList(%s)" 
      (exposed_class_name name) (exposed_class_name name) thing
  | Set(Int)            ->
      sprintf "Helper.StringArrayToLongArray(%s)" thing
  | _                   -> assert false 


and convert_to_proxy thing ty = (*function*)
  match ty with
  | DateTime            -> thing
  | Int                 -> sprintf "%s.ToString()" thing
  | Bool                
  | Float               -> thing
  | Ref _               -> sprintf "(%s != null) ? %s : \"\"" thing thing
  | String              -> sprintf "(%s != null) ? %s : \"\"" thing thing
  | Enum (name,_)       -> sprintf "%s_helper.ToString(%s)" name thing
  | Set (Ref name)         -> sprintf "(%s != null) ? Helper.RefListToStringArray(%s) : new string[] {}" thing thing
  | Set(String)         -> thing
  | Set (Int) -> sprintf "(%s != null) ? Helper.LongArrayToStringArray(%s) : new string[] {}" thing thing
  | Set(Enum(_, _))  -> sprintf "(%s != null) ? Helper.ObjectListToStringArray(%s) : new string[] {}" thing thing
  | Map(u, v) as x      -> maps := TypeSet.add x !maps;
                           sprintf "%s(%s)"
                           (sanitise_function_name (sprintf "Maps.convert_to_proxy_%s_%s" (exposed_type_as_literal u) (exposed_type_as_literal v))) thing
  | Record name         -> sprintf "%s.ToProxy()" thing

  | _                   -> assert false


and proxy_msg_name classname msg =
  sprintf "%s_%s" (String.lowercase classname) (String.lowercase msg.msg_name)


and exposed_class_name classname =
  String.capitalize classname

and escaped = function
  | "params" -> "paramz"
  | "ref" -> "reff"
  | "public" -> "pubblic"
  | s -> s

and full_name field =
  escaped (String.concat "_" field.full_name)

and full_description field =
  field.field_description


and is_readonly field =
  match field.qualifier with
      RW   -> "false"
    | _    -> "true"


and is_static_readonly field =
  match field.qualifier with
      StaticRO     -> "true"
    | DynamicRO    -> "false"
    | _            -> "false"


and banner () = sprintf "%s" Licence.bsd_two_clause

and i18n_header out_chan =
  let print format = fprintf out_chan format in
    print
"<?xml version=\"1.0\" encoding=\"utf-8\"?>
<root>
  <!-- 
    Microsoft ResX Schema 
    
    Version 2.0
    
    The primary goals of this format is to allow a simple XML format 
    that is mostly human readable. The generation and parsing of the 
    various data types are done through the TypeConverter classes 
    associated with the data types.
    
    Example:
    
    ... ado.net/XML headers & schema ...
    <resheader name=\"resmimetype\">text/microsoft-resx</resheader>
    <resheader name=\"version\">2.0</resheader>
    <resheader name=\"reader\">System.Resources.ResXResourceReader, System.Windows.Forms, ...</resheader>
    <resheader name=\"writer\">System.Resources.ResXResourceWriter, System.Windows.Forms, ...</resheader>
    <data name=\"Name1\"><value>this is my long string</value><comment>this is a comment</comment></data>
    <data name=\"Color1\" type=\"System.Drawing.Color, System.Drawing\">Blue</data>
    <data name=\"Bitmap1\" mimetype=\"application/x-microsoft.net.object.binary.base64\">
        <value>[base64 mime encoded serialized .NET Framework object]</value>
    </data>
    <data name=\"Icon1\" type=\"System.Drawing.Icon, System.Drawing\" mimetype=\"application/x-microsoft.net.object.bytearray.base64\">
        <value>[base64 mime encoded string representing a byte array form of the .NET Framework object]</value>
        <comment>This is a comment</comment>
    </data>
                
    There are any number of \"resheader\" rows that contain simple 
    name/value pairs.
    
    Each data row contains a name, and value. The row also contains a 
    type or mimetype. Type corresponds to a .NET class that support 
    text/value conversion through the TypeConverter architecture. 
    Classes that don't support this are serialized and stored with the 
    mimetype set.
    
    The mimetype is used for serialized objects, and tells the 
    ResXResourceReader how to depersist the object. This is currently not 
    extensible. For a given mimetype the value must be set accordingly:
    
    Note - application/x-microsoft.net.object.binary.base64 is the format 
    that the ResXResourceWriter will generate, however the reader can 
    read any of the formats listed below.
    
    mimetype: application/x-microsoft.net.object.binary.base64
    value   : The object must be serialized with 
            : System.Runtime.Serialization.Formatters.Binary.BinaryFormatter
            : and then encoded with base64 encoding.
    
    mimetype: application/x-microsoft.net.object.soap.base64
    value   : The object must be serialized with 
            : System.Runtime.Serialization.Formatters.Soap.SoapFormatter
            : and then encoded with base64 encoding.

    mimetype: application/x-microsoft.net.object.bytearray.base64
    value   : The object must be serialized into a byte array 
            : using a System.ComponentModel.TypeConverter
            : and then encoded with base64 encoding.
    -->
  <xsd:schema id=\"root\" xmlns=\"\" xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" xmlns:msdata=\"urn:schemas-microsoft-com:xml-msdata\">
    <xsd:import namespace=\"http://www.w3.org/XML/1998/namespace\" />
    <xsd:element name=\"root\" msdata:IsDataSet=\"true\">
      <xsd:complexType>
        <xsd:choice maxOccurs=\"unbounded\">
          <xsd:element name=\"metadata\">
            <xsd:complexType>
              <xsd:sequence>
                <xsd:element name=\"value\" type=\"xsd:string\" minOccurs=\"0\" />
              </xsd:sequence>
              <xsd:attribute name=\"name\" use=\"required\" type=\"xsd:string\" />
              <xsd:attribute name=\"type\" type=\"xsd:string\" />
              <xsd:attribute name=\"mimetype\" type=\"xsd:string\" />
              <xsd:attribute ref=\"xml:space\" />
            </xsd:complexType>
          </xsd:element>
          <xsd:element name=\"assembly\">
            <xsd:complexType>
              <xsd:attribute name=\"alias\" type=\"xsd:string\" />
              <xsd:attribute name=\"name\" type=\"xsd:string\" />
            </xsd:complexType>
          </xsd:element>
          <xsd:element name=\"data\">
            <xsd:complexType>
              <xsd:sequence>
                <xsd:element name=\"value\" type=\"xsd:string\" minOccurs=\"0\" msdata:Ordinal=\"1\" />
                <xsd:element name=\"comment\" type=\"xsd:string\" minOccurs=\"0\" msdata:Ordinal=\"2\" />
              </xsd:sequence>
              <xsd:attribute name=\"name\" type=\"xsd:string\" use=\"required\" msdata:Ordinal=\"1\" />
              <xsd:attribute name=\"type\" type=\"xsd:string\" msdata:Ordinal=\"3\" />
              <xsd:attribute name=\"mimetype\" type=\"xsd:string\" msdata:Ordinal=\"4\" />
              <xsd:attribute ref=\"xml:space\" />
            </xsd:complexType>
          </xsd:element>
          <xsd:element name=\"resheader\">
            <xsd:complexType>
              <xsd:sequence>
                <xsd:element name=\"value\" type=\"xsd:string\" minOccurs=\"0\" msdata:Ordinal=\"1\" />
              </xsd:sequence>
              <xsd:attribute name=\"name\" type=\"xsd:string\" use=\"required\" />
            </xsd:complexType>
          </xsd:element>
        </xsd:choice>
      </xsd:complexType>
    </xsd:element>
  </xsd:schema>
  <resheader name=\"resmimetype\">
    <value>text/microsoft-resx</value>
  </resheader>
  <resheader name=\"version\">
    <value>2.0</value>
  </resheader>
  <resheader name=\"reader\">
    <value>System.Resources.ResXResourceReader, System.Windows.Forms, Version=2.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089</value>
  </resheader>
  <resheader name=\"writer\">
    <value>System.Resources.ResXResourceWriter, System.Windows.Forms, Version=2.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089</value>
  </resheader>
"
and i18n_footer out_chan =
  let print format = fprintf out_chan format in
    print
"</root>\n"
and gen_i18n_errors () =
  Friendly_error_names.parse_sr_xml sr_xml;
  Friendly_error_names.parse_resx resx_file;
  let out_chan = open_out (Filename.concat destdir "FriendlyErrorNames.resx")
  in
    finally (fun () ->
               i18n_header out_chan;
               List.iter (gen_i18n_error_field out_chan)
                 (Friendly_error_names.friendly_names_all Datamodel.errors);
               i18n_footer out_chan)
            (fun () -> close_out out_chan)


and gen_i18n_error_field out_chan (error, desc) =
  let print format = fprintf out_chan format in
    (* Note that we can't use Xml.to_string for the whole block, because
       we need the output to be whitespace-identical to what Visual Studio
       would produce.  We need to use it for the inner <value> though, to
       get the escaping right. *)
    print "  <data name=\"%s\" xml:space=\"preserve\">\n    %s\n  </data>\n"
      error
      (Xml.to_string (Xml.Element("value", [], [(Xml.PCData desc)])))

let _ =
  main()
