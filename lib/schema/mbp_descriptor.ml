(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "mbp_descriptor.ml" *)
(* Resolve and validate the hardware extraction descriptor for the selected MBP template. *)

open! Core
open Schema_types

type scalar =
  { offset : int
  ; width : int
  ; signed : bool
  ; nullable : bool
  ; null_value : string option
  ; since_version : int
  ; valid_values : int list
  }
[@@deriving equal, sexp]

type group_dimension =
  { encoded_size : int
  ; block_length_offset : int
  ; block_length_width : int
  ; count_offset : int
  ; count_width : int
  }
[@@deriving equal, sexp]

type t =
  { schema_id : int
  ; schema_version : int
  ; template_name : string
  ; template_id : int
  ; template_since_version : int
  ; root_block_length : int
  ; transact_time : scalar
  ; match_event_indicator : scalar
  ; mbp_group_block_length : int
  ; mbp_dimension : group_dimension
  ; price_mantissa : scalar
  ; price_exponent : int
  ; entry_size : scalar
  ; security_id : scalar
  ; rpt_seq : scalar
  ; number_of_orders : scalar
  ; price_level : scalar
  ; update_action : scalar
  ; entry_type : scalar
  ; tradeable_size : scalar
  ; order_group_block_length : int
  ; order_dimension : group_dimension
  }
[@@deriving equal, sexp]

let fail template format =
  Printf.ksprintf
    (fun message ->
      raise (Schema_xml.Schema_error (sprintf "template %s: %s" template message)))
    format
;;

let field_exn template (fields : field list) name =
  match List.find fields ~f:(fun (field : field) -> String.equal field.name name) with
  | Some field -> field
  | None -> fail template "missing field %s" name
;;

let group_exn template (groups : group list) name =
  match List.find groups ~f:(fun (group : group) -> String.equal group.name name) with
  | Some group -> group
  | None -> fail template "missing group %s" name
;;

let int_of_wire_value primitive value =
  match primitive with
  | Char when String.length value = 1 -> Char.to_int value.[0]
  | Char ->
    (match Int.of_string_opt value with
     | Some value -> value
     | None -> failwithf "invalid char encoding %S" value ())
  | _ -> Int.of_string value
;;

let scalar_of_encoding schema template ~offset ~since_version encoding =
  match encoding with
  | Type component ->
    { offset
    ; width = component_wire_width component
    ; signed = primitive_is_signed component.primitive
    ; nullable = equal_presence component.presence Optional
    ; null_value = component.null_value
    ; since_version = Int.max since_version component.since_version
    ; valid_values = []
    }
  | Enum enum ->
    let primitive = encoding_primitive_exn schema encoding in
    { offset
    ; width = primitive_width primitive
    ; signed = primitive_is_signed primitive
    ; nullable = false
    ; null_value = None
    ; since_version = Int.max since_version enum.since_version
    ; valid_values =
        List.map enum.values ~f:(fun value -> int_of_wire_value primitive value.value)
    }
  | Set set ->
    let primitive = encoding_primitive_exn schema encoding in
    { offset
    ; width = primitive_width primitive
    ; signed = primitive_is_signed primitive
    ; nullable = false
    ; null_value = None
    ; since_version = Int.max since_version set.since_version
    ; valid_values = []
    }
  | Composite _ -> fail template "composite used where a scalar field was required"
;;

let scalar_field schema template (fields : field list) name =
  let field = field_exn template fields name in
  let layout = block_field_layout_exn schema fields in
  let _, offset, _ =
    List.find_exn layout ~f:(fun ((candidate : field), _, _) ->
      String.equal candidate.name name)
  in
  scalar_of_encoding
    schema
    template
    ~offset
    ~since_version:field.since_version
    (find_encoding_exn schema field.type_name)
;;

let price_field schema template (fields : field list) =
  let field = field_exn template fields "MDEntryPx" in
  let _, field_offset, _ =
    List.find_exn
      (block_field_layout_exn schema fields)
      ~f:(fun ((candidate : field), _, _) -> String.equal candidate.name field.name)
  in
  match find_encoding_exn schema field.type_name with
  | Composite composite ->
    let mantissa, mantissa_offset, _ =
      List.find_exn (composite_layout composite.components) ~f:(fun (component, _, _) ->
        String.equal component.name "mantissa")
    in
    let exponent =
      List.find_exn composite.components ~f:(fun component ->
        String.equal component.name "exponent")
    in
    let price_mantissa =
      { offset = field_offset + mantissa_offset
      ; width = component_wire_width mantissa
      ; signed = primitive_is_signed mantissa.primitive
      ; nullable = equal_presence mantissa.presence Optional
      ; null_value = mantissa.null_value
      ; since_version =
          List.fold
            [ field.since_version; composite.since_version; mantissa.since_version ]
            ~init:0
            ~f:Int.max
      ; valid_values = []
      }
    in
    let price_exponent =
      match exponent.presence, exponent.constant_value with
      | Constant, Some value -> Int.of_string value
      | _ -> fail template "%s.exponent must be constant" field.type_name
    in
    price_mantissa, price_exponent
  | _ -> fail template "MDEntryPx must use a composite price encoding"
;;

let dimension schema template type_name =
  match find_encoding_exn schema type_name with
  | Composite composite ->
    let layout = composite_layout composite.components in
    let part name =
      match
        List.find layout ~f:(fun (component, _, _) -> String.equal component.name name)
      with
      | Some value -> value
      | None -> fail template "dimension %s is missing %s" type_name name
    in
    let block, block_offset, block_width = part "blockLength" in
    let count, count_offset, count_width = part "numInGroup" in
    if equal_presence block.presence Constant || equal_presence count.presence Constant
    then fail template "dimension %s uses a constant wire component" type_name;
    { encoded_size = encoding_wire_width_exn schema (Composite composite)
    ; block_length_offset = block_offset
    ; block_length_width = block_width
    ; count_offset
    ; count_width
    }
  | _ -> fail template "dimensionType %s is not a composite" type_name
;;

let of_schema schema ~template_name =
  if not (String.equal schema.byte_order "littleEndian")
  then fail template_name "unsupported byteOrder %s" schema.byte_order;
  let message = find_message_by_name_exn schema template_name in
  let mbp_group = group_exn template_name message.groups "NoMDEntries" in
  let order_group = group_exn template_name message.groups "NoOrderIDEntries" in
  if List.length message.groups <> 2
  then fail template_name "expected exactly the NoMDEntries and NoOrderIDEntries groups";
  let price_mantissa, price_exponent =
    price_field schema template_name mbp_group.fields
  in
  { schema_id = schema.id
  ; schema_version = schema.version
  ; template_name
  ; template_id = message.id
  ; template_since_version = message.since_version
  ; root_block_length = message.block_length
  ; transact_time = scalar_field schema template_name message.fields "TransactTime"
  ; match_event_indicator =
      scalar_field schema template_name message.fields "MatchEventIndicator"
  ; mbp_group_block_length = mbp_group.block_length
  ; mbp_dimension = dimension schema template_name mbp_group.dimension_type
  ; price_mantissa
  ; price_exponent
  ; entry_size = scalar_field schema template_name mbp_group.fields "MDEntrySize"
  ; security_id = scalar_field schema template_name mbp_group.fields "SecurityID"
  ; rpt_seq = scalar_field schema template_name mbp_group.fields "RptSeq"
  ; number_of_orders = scalar_field schema template_name mbp_group.fields "NumberOfOrders"
  ; price_level = scalar_field schema template_name mbp_group.fields "MDPriceLevel"
  ; update_action = scalar_field schema template_name mbp_group.fields "MDUpdateAction"
  ; entry_type = scalar_field schema template_name mbp_group.fields "MDEntryType"
  ; tradeable_size = scalar_field schema template_name mbp_group.fields "TradeableSize"
  ; order_group_block_length = order_group.block_length
  ; order_dimension = dimension schema template_name order_group.dimension_type
  }
;;

let load schema_file ~template_name =
  Schema_xml.load schema_file |> of_schema ~template_name
;;
