(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "schema_xml.ml" *)
(* Strict Xmlm reader for the reusable CME/SBE schema subset. *)

open! Core
open Schema_types

exception Schema_error of string

type node =
  { name : string
  ; attributes : (string * string) list
  ; children : node list
  ; text : string
  ; line : int
  ; column : int
  }

let error ?node format =
  Printf.ksprintf
    (fun message ->
      let location =
        match node with
        | None -> ""
        | Some node -> sprintf " at line %d, column %d" node.line node.column
      in
      raise (Schema_error (message ^ location)))
    format
;;

let local_name (_, name) = name

let rec read_node input ((_, name), attributes) (line, column) =
  let rec loop children text =
    match Xmlm.input input with
    | `El_start (tag, attributes) ->
      let position = Xmlm.pos input in
      loop (read_node input (tag, attributes) position :: children) text
    | `Data data -> loop children (data :: text)
    | `El_end ->
      { name
      ; attributes =
          List.filter_map attributes ~f:(fun (((namespace, _) as name), value) ->
            if String.equal namespace "http://www.w3.org/2000/xmlns/"
            then None
            else Some (local_name name, value))
      ; children = List.rev children
      ; text = String.strip (String.concat (List.rev text))
      ; line
      ; column
      }
    | `Dtd _ -> error "unexpected DTD inside <%s>" name
  in
  loop [] []
;;

let parse_input input =
  (match Xmlm.input input with
   | `Dtd _ -> ()
   | _ -> error "expected XML document declaration");
  match Xmlm.input input with
  | `El_start (tag, attributes) -> read_node input (tag, attributes) (Xmlm.pos input)
  | _ -> error "expected the messageSchema root element"
;;

let attribute node name = List.Assoc.find node.attributes ~equal:String.equal name

let required_attribute node name =
  match attribute node name with
  | Some value -> value
  | None -> error ~node "<%s> is missing required attribute %S" node.name name
;;

let int_attribute ?default node name =
  match attribute node name, default with
  | None, Some default -> default
  | None, None -> error ~node "<%s> is missing integer attribute %S" node.name name
  | Some value, _ ->
    (match Int.of_string_opt value with
     | Some value -> value
     | None -> error ~node "<%s> has invalid integer %s=%S" node.name name value)
;;

let allowed_attributes node allowed =
  List.iter node.attributes ~f:(fun (name, _) ->
    if not (List.mem allowed name ~equal:String.equal)
    then error ~node "unsupported attribute %S on <%s>" name node.name)
;;

let primitive node value =
  match String.lowercase value with
  | "char" -> Char
  | "int8" -> Int8
  | "uint8" -> Uint8
  | "int16" -> Int16
  | "uint16" -> Uint16
  | "int32" -> Int32
  | "uint32" -> Uint32
  | "int64" -> Int64
  | "uint64" -> Uint64
  | value -> error ~node "unsupported primitiveType %S" value
;;

let presence node =
  match Option.value (attribute node "presence") ~default:"required" with
  | "required" -> Required
  | "optional" -> Optional
  | "constant" -> Constant
  | value -> error ~node "unsupported presence %S" value
;;

let parse_component node =
  allowed_attributes
    node
    [ "name"
    ; "description"
    ; "primitiveType"
    ; "length"
    ; "offset"
    ; "presence"
    ; "nullValue"
    ; "sinceVersion"
    ; "semanticType"
    ; "characterEncoding"
    ; "minValue"
    ; "maxValue"
    ];
  { name = required_attribute node "name"
  ; primitive = primitive node (required_attribute node "primitiveType")
  ; length = int_attribute ~default:1 node "length"
  ; offset = Option.map (attribute node "offset") ~f:Int.of_string
  ; presence = presence node
  ; null_value = attribute node "nullValue"
  ; constant_value = (if String.is_empty node.text then None else Some node.text)
  ; since_version = int_attribute ~default:0 node "sinceVersion"
  }
;;

let parse_encoding node =
  match node.name with
  | "type" -> Type (parse_component node)
  | "composite" ->
    allowed_attributes node [ "name"; "description"; "sinceVersion"; "semanticType" ];
    Composite
      { name = required_attribute node "name"
      ; components =
          List.map node.children ~f:(fun child ->
            if not (String.equal child.name "type")
            then
              error
                ~node:child
                "unsupported <%s> inside composite %s"
                child.name
                (required_attribute node "name");
            parse_component child)
      ; since_version = int_attribute ~default:0 node "sinceVersion"
      }
  | "enum" ->
    allowed_attributes node [ "name"; "description"; "encodingType"; "sinceVersion" ];
    Enum
      { name = required_attribute node "name"
      ; encoding_type = required_attribute node "encodingType"
      ; values =
          List.map node.children ~f:(fun child ->
            if not (String.equal child.name "validValue")
            then
              error
                ~node:child
                "unsupported <%s> inside enum %s"
                child.name
                (required_attribute node "name");
            allowed_attributes child [ "name"; "description"; "sinceVersion" ];
            { name = required_attribute child "name"
            ; value = child.text
            ; since_version = int_attribute ~default:0 child "sinceVersion"
            })
      ; since_version = int_attribute ~default:0 node "sinceVersion"
      }
  | "set" ->
    allowed_attributes node [ "name"; "description"; "encodingType"; "sinceVersion" ];
    Set
      { name = required_attribute node "name"
      ; encoding_type = required_attribute node "encodingType"
      ; choices =
          List.map node.children ~f:(fun child ->
            if not (String.equal child.name "choice")
            then
              error
                ~node:child
                "unsupported <%s> inside set %s"
                child.name
                (required_attribute node "name");
            allowed_attributes child [ "name"; "description"; "sinceVersion" ];
            { name = required_attribute child "name"
            ; bit = Int.of_string child.text
            ; since_version = int_attribute ~default:0 child "sinceVersion"
            })
      ; since_version = int_attribute ~default:0 node "sinceVersion"
      }
  | name -> error ~node "unsupported <%s> in <types>" name
;;

let parse_field node =
  if not (String.equal node.name "field")
  then error ~node "expected <field>, found <%s>" node.name;
  allowed_attributes
    node
    [ "name"; "id"; "type"; "offset"; "sinceVersion"; "description"; "semanticType" ];
  if not (List.is_empty node.children)
  then
    error ~node "field %s has unsupported child elements" (required_attribute node "name");
  { name = required_attribute node "name"
  ; id = int_attribute node "id"
  ; type_name = required_attribute node "type"
  ; offset = Option.map (attribute node "offset") ~f:Int.of_string
  ; since_version = int_attribute ~default:0 node "sinceVersion"
  }
;;

let parse_group node =
  allowed_attributes
    node
    [ "name"; "id"; "description"; "blockLength"; "dimensionType"; "sinceVersion" ];
  { name = required_attribute node "name"
  ; id = int_attribute node "id"
  ; block_length = int_attribute node "blockLength"
  ; dimension_type = required_attribute node "dimensionType"
  ; since_version = int_attribute ~default:0 node "sinceVersion"
  ; fields = List.map node.children ~f:parse_field
  }
;;

let parse_message node =
  allowed_attributes
    node
    [ "name"; "id"; "description"; "blockLength"; "semanticType"; "sinceVersion" ];
  let fields, groups =
    List.fold node.children ~init:([], []) ~f:(fun (fields, groups) child ->
      match child.name with
      | "field" -> parse_field child :: fields, groups
      | "group" -> fields, parse_group child :: groups
      | name ->
        error
          ~node:child
          "unsupported <%s> in template %s"
          name
          (required_attribute node "name"))
  in
  { name = required_attribute node "name"
  ; id = int_attribute node "id"
  ; block_length = int_attribute node "blockLength"
  ; since_version = int_attribute ~default:0 node "sinceVersion"
  ; fields = List.rev fields
  ; groups = List.rev groups
  }
;;

let of_root root =
  if not (String.equal root.name "messageSchema")
  then error ~node:root "expected <messageSchema>, found <%s>" root.name;
  allowed_attributes
    root
    [ "package"
    ; "id"
    ; "version"
    ; "semanticVersion"
    ; "description"
    ; "byteOrder"
    ; "schemaLocation"
    ];
  let types =
    List.find_exn root.children ~f:(fun child -> String.equal child.name "types")
  in
  let messages =
    List.filter root.children ~f:(fun child -> String.equal child.name "message")
  in
  let unexpected =
    List.filter root.children ~f:(fun child ->
      not (String.equal child.name "types" || String.equal child.name "message"))
  in
  List.iter unexpected ~f:(fun child ->
    error ~node:child "unsupported root element <%s>" child.name);
  { package = required_attribute root "package"
  ; id = int_attribute root "id"
  ; version = int_attribute root "version"
  ; description = required_attribute root "description"
  ; byte_order = required_attribute root "byteOrder"
  ; encodings = List.map types.children ~f:parse_encoding
  ; messages = List.map messages ~f:parse_message
  }
;;

let of_string value =
  let input = Xmlm.make_input ~strip:false (`String (0, value)) in
  try of_root (parse_input input) with
  | Xmlm.Error ((line, column), error_value) ->
    raise
      (Schema_error
         (sprintf "%s at line %d, column %d" (Xmlm.error_message error_value) line column))
;;

let load filename = In_channel.read_all filename |> of_string
