(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "schema_types.ml" *)
(* Software representation of the SBE XML subset used by CME market-by-price. *)

open! Core

type primitive =
  | Char
  | Int8
  | Uint8
  | Int16
  | Uint16
  | Int32
  | Uint32
  | Int64
  | Uint64
[@@deriving equal, sexp]

type presence =
  | Required
  | Optional
  | Constant
[@@deriving equal, sexp]

type component =
  { name : string
  ; primitive : primitive
  ; length : int
  ; offset : int option
  ; presence : presence
  ; null_value : string option
  ; constant_value : string option
  ; since_version : int
  }
[@@deriving equal, sexp]

type valid_value =
  { name : string
  ; value : string
  ; since_version : int
  }
[@@deriving equal, sexp]

type choice =
  { name : string
  ; bit : int
  ; since_version : int
  }
[@@deriving equal, sexp]

type encoding =
  | Type of component
  | Composite of
      { name : string
      ; components : component list
      ; since_version : int
      }
  | Enum of
      { name : string
      ; encoding_type : string
      ; values : valid_value list
      ; since_version : int
      }
  | Set of
      { name : string
      ; encoding_type : string
      ; choices : choice list
      ; since_version : int
      }
[@@deriving equal, sexp]

type field =
  { name : string
  ; id : int
  ; type_name : string
  ; offset : int option
  ; since_version : int
  }
[@@deriving equal, sexp]

type group =
  { name : string
  ; id : int
  ; block_length : int
  ; dimension_type : string
  ; since_version : int
  ; fields : field list
  }
[@@deriving equal, sexp]

type message =
  { name : string
  ; id : int
  ; block_length : int
  ; since_version : int
  ; fields : field list
  ; groups : group list
  }
[@@deriving equal, sexp]

type t =
  { package : string
  ; id : int
  ; version : int
  ; description : string
  ; byte_order : string
  ; encodings : encoding list
  ; messages : message list
  }
[@@deriving equal, sexp]

let primitive_width = function
  | Char | Int8 | Uint8 -> 1
  | Int16 | Uint16 -> 2
  | Int32 | Uint32 -> 4
  | Int64 | Uint64 -> 8
;;

let primitive_is_signed = function
  | Int8 | Int16 | Int32 | Int64 -> true
  | Char | Uint8 | Uint16 | Uint32 | Uint64 -> false
;;

let find_encoding_exn t name =
  List.find_exn t.encodings ~f:(function
    | Type c -> String.equal c.name name
    | Composite c -> String.equal c.name name
    | Enum e -> String.equal e.name name
    | Set s -> String.equal s.name name)
;;

let find_message_by_name_exn t name =
  List.find_exn t.messages ~f:(fun message -> String.equal message.name name)
;;

let find_message_by_id t id = List.find t.messages ~f:(fun message -> message.id = id)

let encoding_primitive_exn t = function
  | Type c -> c.primitive
  | Composite _ -> failwith "a composite has no single primitive encoding"
  | Enum e ->
    (match find_encoding_exn t e.encoding_type with
     | Type c -> c.primitive
     | _ ->
       failwithf "encoding %s does not resolve to a primitive type" e.encoding_type ())
  | Set s ->
    (match find_encoding_exn t s.encoding_type with
     | Type c -> c.primitive
     | _ ->
       failwithf "encoding %s does not resolve to a primitive type" s.encoding_type ())
;;

let component_wire_width component =
  if equal_presence component.presence Constant
  then 0
  else primitive_width component.primitive * component.length
;;

let composite_layout (components : component list) =
  let _, layout =
    List.fold components ~init:(0, []) ~f:(fun (cursor, result) (component : component) ->
      let offset = Option.value component.offset ~default:cursor in
      let width = component_wire_width component in
      Int.max cursor (offset + width), (component, offset, width) :: result)
  in
  List.rev layout
;;

let encoding_wire_width_exn t = function
  | Type c -> component_wire_width c
  | Composite c ->
    List.fold (composite_layout c.components) ~init:0 ~f:(fun size (_, offset, width) ->
      Int.max size (offset + width))
  | Enum e -> primitive_width (encoding_primitive_exn t (Enum e))
  | Set s -> primitive_width (encoding_primitive_exn t (Set s))
;;

let field_wire_width_exn t field =
  encoding_wire_width_exn t (find_encoding_exn t field.type_name)
;;

let block_field_layout_exn t (fields : field list) =
  let _, layout =
    List.fold fields ~init:(0, []) ~f:(fun (cursor, result) (field : field) ->
      let offset = Option.value field.offset ~default:cursor in
      let width = field_wire_width_exn t field in
      Int.max cursor (offset + width), (field, offset, width) :: result)
  in
  List.rev layout
;;

let field_required_end_exn t ~version (field : field) =
  if field.since_version > version
  then 0
  else Option.value field.offset ~default:0 + field_wire_width_exn t field
;;
