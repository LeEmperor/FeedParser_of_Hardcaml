(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "golden_decoder.ml" *)
(* Independent XML-driven software oracle for CME packet sequencing and template 46. *)

open! Core
open Schema_types

module Diagnostic_code = struct
  type t =
    | Sequence_gap
    | Duplicate_or_late
    | Truncated_packet_header
    | Invalid_message_size
    | Message_beyond_packet
    | Unsupported_template
    | Schema_incompatibility
    | Invalid_enum
  [@@deriving compare, equal, sexp]
end

type packet_context =
  { ingress_timestamp : int64
  ; source_id : int
  ; packet_seq : int64
  ; sending_time : int64
  ; packet_header_present : bool
  ; channel_valid : bool
  }
[@@deriving equal, sexp]

type message_context =
  { msg_size : int
  ; block_length : int
  ; template_id : int
  ; schema_id : int
  ; schema_version : int
  ; message_header_present : bool
  ; transaction_time : int64
  ; transaction_time_present : bool
  ; packet_byte_offset : int
  }
[@@deriving equal, sexp]

type update =
  { packet : packet_context
  ; message : message_context
  ; entry_index : int
  ; entry_count : int
  ; security_id : int64
  ; rpt_seq : int64
  ; price_mantissa : int64 option
  ; price_exponent : int
  ; entry_size : int64 option
  ; number_of_orders : int64 option
  ; price_level : int
  ; update_action : int
  ; entry_type : int
  ; tradeable_size : int64 option
  ; match_event_indicator : int
  ; message_last : bool
  }
[@@deriving equal, sexp]

type diagnostic =
  { packet : packet_context
  ; message : message_context option
  ; code : Diagnostic_code.t
  ; expected_seq : int64 option
  ; byte_offset : int
  }
[@@deriving equal, sexp]

type event =
  | Mbp_update of update
  | End_of_event of
      { packet : packet_context
      ; message : message_context
      ; match_event_indicator : int
      }
  | Diagnostic of diagnostic
[@@deriving equal, sexp]

type scalar =
  { offset : int
  ; width : int
  ; signed : bool
  ; null_value : int64 option
  ; since_version : int
  ; valid_values : (int * int) list
  }

type dimension =
  { size : int
  ; block_offset : int
  ; block_width : int
  ; count_offset : int
  ; count_width : int
  }

type layout =
  { schema_id : int
  ; schema_version : int
  ; template_id : int
  ; template_since_version : int
  ; root_block_length : int
  ; root_fields : field list
  ; transact_time : scalar
  ; match_event_indicator : scalar
  ; mbp_fields : field list
  ; mbp_block_length : int
  ; mbp_dimension : dimension
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
  ; order_dimension : dimension
  ; order_block_length : int
  }

type t =
  { schema : Schema_types.t
  ; layout : layout
  ; mutable expected_seq : int64 option
  ; mutable channel_valid : bool
  }

let mask32 = 0xffff_ffffL
let normalize32 value = Int64.bit_and value mask32

let empty_packet ?(ingress_timestamp = 0L) () =
  { ingress_timestamp
  ; source_id = 0
  ; packet_seq = 0L
  ; sending_time = 0L
  ; packet_header_present = false
  ; channel_valid = false
  }
;;

let empty_message ~offset =
  { msg_size = 0
  ; block_length = 0
  ; template_id = 0
  ; schema_id = 0
  ; schema_version = 0
  ; message_header_present = false
  ; transaction_time = 0L
  ; transaction_time_present = false
  ; packet_byte_offset = offset
  }
;;

let read_unsigned bytes offset width =
  if offset < 0 || width < 0 || offset + width > String.length bytes
  then invalid_arg "Golden_decoder.read_unsigned";
  let value = ref 0L in
  for byte = 0 to width - 1 do
    value
    := Int64.bit_or
         !value
         (Int64.shift_left (Int64.of_int (Char.to_int bytes.[offset + byte])) (byte * 8))
  done;
  !value
;;

let read_signed bytes offset width =
  let value = read_unsigned bytes offset width in
  if width = 8
  then value
  else (
    let bits = width * 8 in
    let sign_bit = Int64.shift_left 1L (bits - 1) in
    if Int64.(bit_and value sign_bit = 0L)
    then value
    else Int64.(value - shift_left 1L bits))
;;

let read_int bytes offset width = Int64.to_int_exn (read_unsigned bytes offset width)

let primitive_value primitive value =
  match primitive with
  | Char when String.length value = 1 -> Char.to_int value.[0]
  | _ -> Int.of_string value
;;

let find_field_exn (fields : field list) name =
  List.find_exn fields ~f:(fun field -> String.equal field.name name)
;;

let field_offset_exn schema (fields : field list) name =
  let field, offset, _ =
    List.find_exn (block_field_layout_exn schema fields) ~f:(fun (field, _, _) ->
      String.equal field.name name)
  in
  field, offset
;;

let scalar schema fields name =
  let field, offset = field_offset_exn schema fields name in
  match find_encoding_exn schema field.type_name with
  | Type component ->
    { offset
    ; width = component_wire_width component
    ; signed = primitive_is_signed component.primitive
    ; null_value = Option.map component.null_value ~f:Int64.of_string
    ; since_version = Int.max field.since_version component.since_version
    ; valid_values = []
    }
  | Enum enum ->
    let primitive = encoding_primitive_exn schema (Enum enum) in
    { offset
    ; width = primitive_width primitive
    ; signed = primitive_is_signed primitive
    ; null_value = None
    ; since_version = Int.max field.since_version enum.since_version
    ; valid_values =
        List.map enum.values ~f:(fun value ->
          primitive_value primitive value.value, value.since_version)
    }
  | Set set ->
    let primitive = encoding_primitive_exn schema (Set set) in
    { offset
    ; width = primitive_width primitive
    ; signed = primitive_is_signed primitive
    ; null_value = None
    ; since_version = Int.max field.since_version set.since_version
    ; valid_values = []
    }
  | Composite _ -> failwithf "%s unexpectedly uses a composite" name ()
;;

let price schema fields =
  let field, offset = field_offset_exn schema fields "MDEntryPx" in
  match find_encoding_exn schema field.type_name with
  | Composite composite ->
    let component_layout = composite_layout composite.components in
    let mantissa, mantissa_offset, _ =
      List.find_exn component_layout ~f:(fun (component, _, _) ->
        String.equal component.name "mantissa")
    in
    let exponent =
      List.find_exn composite.components ~f:(fun component ->
        String.equal component.name "exponent")
    in
    let scalar =
      { offset = offset + mantissa_offset
      ; width = component_wire_width mantissa
      ; signed = primitive_is_signed mantissa.primitive
      ; null_value = Option.map mantissa.null_value ~f:Int64.of_string
      ; since_version =
          List.fold
            [ field.since_version; composite.since_version; mantissa.since_version ]
            ~init:0
            ~f:Int.max
      ; valid_values = []
      }
    in
    let exponent = Option.value_exn exponent.constant_value |> Int.of_string in
    scalar, exponent
  | _ -> failwith "MDEntryPx is not a composite"
;;

let dimension schema type_name =
  match find_encoding_exn schema type_name with
  | Composite composite ->
    let fields = composite_layout composite.components in
    let find name =
      List.find_exn fields ~f:(fun (component, _, _) -> String.equal component.name name)
    in
    let _, block_offset, block_width = find "blockLength" in
    let _, count_offset, count_width = find "numInGroup" in
    { size = encoding_wire_width_exn schema (Composite composite)
    ; block_offset
    ; block_width
    ; count_offset
    ; count_width
    }
  | _ -> failwithf "dimension %s is not a composite" type_name ()
;;

let layout_of_schema schema =
  let message = find_message_by_name_exn schema "MDIncrementalRefreshBook46" in
  let mbp_group =
    List.find_exn message.groups ~f:(fun group -> String.equal group.name "NoMDEntries")
  in
  let order_group =
    List.find_exn message.groups ~f:(fun group ->
      String.equal group.name "NoOrderIDEntries")
  in
  let price_mantissa, price_exponent = price schema mbp_group.fields in
  { schema_id = schema.id
  ; schema_version = schema.version
  ; template_id = message.id
  ; template_since_version = message.since_version
  ; root_block_length = message.block_length
  ; root_fields = message.fields
  ; transact_time = scalar schema message.fields "TransactTime"
  ; match_event_indicator = scalar schema message.fields "MatchEventIndicator"
  ; mbp_fields = mbp_group.fields
  ; mbp_block_length = mbp_group.block_length
  ; mbp_dimension = dimension schema mbp_group.dimension_type
  ; price_mantissa
  ; price_exponent
  ; entry_size = scalar schema mbp_group.fields "MDEntrySize"
  ; security_id = scalar schema mbp_group.fields "SecurityID"
  ; rpt_seq = scalar schema mbp_group.fields "RptSeq"
  ; number_of_orders = scalar schema mbp_group.fields "NumberOfOrders"
  ; price_level = scalar schema mbp_group.fields "MDPriceLevel"
  ; update_action = scalar schema mbp_group.fields "MDUpdateAction"
  ; entry_type = scalar schema mbp_group.fields "MDEntryType"
  ; tradeable_size = scalar schema mbp_group.fields "TradeableSize"
  ; order_dimension = dimension schema order_group.dimension_type
  ; order_block_length = order_group.block_length
  }
;;

let create ~schema_file =
  let schema = Schema_xml.load schema_file in
  { schema; layout = layout_of_schema schema; expected_seq = None; channel_valid = false }
;;

let session_reset t =
  t.expected_seq <- None;
  t.channel_valid <- false
;;

let resync t ~next_seq =
  t.expected_seq <- Some (normalize32 next_seq);
  t.channel_valid <- true
;;

let diagnostic ?message ?expected_seq packet code byte_offset =
  Diagnostic { packet; message; code; expected_seq; byte_offset }
;;

let sequence t packet =
  let next = normalize32 Int64.(packet.packet_seq + 1L) in
  match t.expected_seq with
  | None ->
    t.expected_seq <- Some next;
    t.channel_valid <- true;
    `Accept []
  | Some expected ->
    let raw_delta = normalize32 Int64.(packet.packet_seq - expected) in
    let delta =
      if Int64.(raw_delta >= 0x8000_0000L)
      then Int64.(raw_delta - 0x1_0000_0000L)
      else raw_delta
    in
    if Int64.(delta = 0L)
    then (
      t.expected_seq <- Some next;
      `Accept [])
    else if Int64.(delta > 0L)
    then (
      t.expected_seq <- Some next;
      t.channel_valid <- false;
      `Accept [ diagnostic packet Diagnostic_code.Sequence_gap 0 ~expected_seq:expected ])
    else
      `Drop
        [ diagnostic packet Diagnostic_code.Duplicate_or_late 0 ~expected_seq:expected ]
;;

let read_scalar bytes base scalar =
  if scalar.signed
  then read_signed bytes (base + scalar.offset) scalar.width
  else read_unsigned bytes (base + scalar.offset) scalar.width
;;

let read_optional bytes base scalar ~version =
  if scalar.since_version > version
  then None
  else (
    let value = read_scalar bytes base scalar in
    if Option.value_map scalar.null_value ~default:false ~f:(Int64.equal value)
    then None
    else Some value)
;;

let required_end schema (fields : field list) version =
  List.fold fields ~init:0 ~f:(fun result (field : field) ->
    if field.since_version > version
    then result
    else (
      let _, offset = field_offset_exn schema fields field.name in
      Int.max result (offset + field_wire_width_exn schema field)))
;;

let enum_valid scalar ~version value =
  List.is_empty scalar.valid_values
  || List.exists scalar.valid_values ~f:(fun (candidate, since_version) ->
    candidate = value && since_version <= version)
;;

let decode_supported_message t schema bytes packet message body_start message_end =
  let layout = t.layout in
  let schema_problem offset =
    [ diagnostic packet ~message Diagnostic_code.Schema_incompatibility offset ]
  in
  if message.schema_id <> layout.schema_id
  then schema_problem (message.packet_byte_offset + 6)
  else if message.schema_version < layout.template_since_version
  then schema_problem (message.packet_byte_offset + 8)
  else (
    let root_required =
      Int.max
        layout.root_block_length
        (required_end schema layout.root_fields message.schema_version)
    in
    if message.block_length < root_required
       || body_start + message.block_length > message_end
    then schema_problem (message.packet_byte_offset + 2)
    else (
      let transaction_time = read_scalar bytes body_start layout.transact_time in
      let match_event_indicator =
        read_scalar bytes body_start layout.match_event_indicator |> Int64.to_int_exn
      in
      let message = { message with transaction_time; transaction_time_present = true } in
      let dimension_start = body_start + message.block_length in
      let dimension = layout.mbp_dimension in
      if dimension_start + dimension.size > message_end
      then schema_problem dimension_start
      else (
        let entry_block =
          read_int bytes (dimension_start + dimension.block_offset) dimension.block_width
        in
        let count =
          read_int bytes (dimension_start + dimension.count_offset) dimension.count_width
        in
        let entry_required =
          Int.max
            layout.mbp_block_length
            (required_end schema layout.mbp_fields message.schema_version)
        in
        let entries_start = dimension_start + dimension.size in
        let entries_end = entries_start + (entry_block * count) in
        if entry_block < entry_required || entries_end > message_end
        then schema_problem dimension_start
        else (
          let rec decode_entries index events =
            if index = count
            then `Ok (List.rev events)
            else (
              let base = entries_start + (index * entry_block) in
              let update_action =
                read_scalar bytes base layout.update_action |> Int64.to_int_exn
              in
              let entry_type =
                read_scalar bytes base layout.entry_type |> Int64.to_int_exn
              in
              if not
                   (enum_valid
                      layout.update_action
                      ~version:message.schema_version
                      update_action)
              then `Invalid (List.rev events, base + layout.update_action.offset)
              else if not
                        (enum_valid
                           layout.entry_type
                           ~version:message.schema_version
                           entry_type)
              then `Invalid (List.rev events, base + layout.entry_type.offset)
              else (
                let update =
                  { packet
                  ; message
                  ; entry_index = index
                  ; entry_count = count
                  ; security_id = read_scalar bytes base layout.security_id
                  ; rpt_seq = read_scalar bytes base layout.rpt_seq
                  ; price_mantissa =
                      read_optional
                        bytes
                        base
                        layout.price_mantissa
                        ~version:message.schema_version
                  ; price_exponent = layout.price_exponent
                  ; entry_size =
                      read_optional
                        bytes
                        base
                        layout.entry_size
                        ~version:message.schema_version
                  ; number_of_orders =
                      read_optional
                        bytes
                        base
                        layout.number_of_orders
                        ~version:message.schema_version
                  ; price_level =
                      read_scalar bytes base layout.price_level |> Int64.to_int_exn
                  ; update_action
                  ; entry_type
                  ; tradeable_size =
                      read_optional
                        bytes
                        base
                        layout.tradeable_size
                        ~version:message.schema_version
                  ; match_event_indicator
                  ; message_last = index + 1 = count
                  }
                in
                decode_entries (index + 1) (Mbp_update update :: events)))
          in
          match decode_entries 0 [] with
          | `Invalid (events, offset) ->
            events @ [ diagnostic packet ~message Diagnostic_code.Invalid_enum offset ]
          | `Ok events ->
            let order_dimension_start = entries_end in
            let order_dimension = layout.order_dimension in
            if order_dimension_start + order_dimension.size > message_end
            then events @ schema_problem order_dimension_start
            else (
              let order_block =
                read_int
                  bytes
                  (order_dimension_start + order_dimension.block_offset)
                  order_dimension.block_width
              in
              let order_count =
                read_int
                  bytes
                  (order_dimension_start + order_dimension.count_offset)
                  order_dimension.count_width
              in
              let orders_end =
                order_dimension_start + order_dimension.size + (order_block * order_count)
              in
              if order_block < layout.order_block_length || orders_end > message_end
              then events @ schema_problem order_dimension_start
              else if match_event_indicator land 0x80 <> 0
              then events @ [ End_of_event { packet; message; match_event_indicator } ]
              else events)))))
;;

let decode_payload ?(ingress_timestamp = 0L) t bytes =
  let length = String.length bytes in
  if length < 12
  then
    [ diagnostic
        (empty_packet ~ingress_timestamp ())
        Diagnostic_code.Truncated_packet_header
        length
    ]
  else (
    let packet_seq = read_unsigned bytes 0 4 in
    let packet_before_sequence =
      { ingress_timestamp
      ; source_id = 0
      ; packet_seq
      ; sending_time = read_unsigned bytes 4 8
      ; packet_header_present = true
      ; channel_valid = t.channel_valid
      }
    in
    match sequence t packet_before_sequence with
    | `Drop events -> events
    | `Accept sequence_events ->
      let packet = { packet_before_sequence with channel_valid = t.channel_valid } in
      let sequence_events =
        List.map sequence_events ~f:(function
          | Diagnostic diagnostic -> Diagnostic { diagnostic with packet }
          | event -> event)
      in
      let rec messages offset events =
        if offset = length
        then List.rev events
        else if length - offset < 10
        then
          List.rev
            (diagnostic
               packet
               ~message:(empty_message ~offset)
               Diagnostic_code.Message_beyond_packet
               length
             :: events)
        else (
          let msg_size = read_int bytes offset 2 in
          let message =
            { msg_size
            ; block_length = read_int bytes (offset + 2) 2
            ; template_id = read_int bytes (offset + 4) 2
            ; schema_id = read_int bytes (offset + 6) 2
            ; schema_version = read_int bytes (offset + 8) 2
            ; message_header_present = true
            ; transaction_time = 0L
            ; transaction_time_present = false
            ; packet_byte_offset = offset
            }
          in
          if msg_size < 10
          then
            List.rev
              (diagnostic packet ~message Diagnostic_code.Invalid_message_size offset
               :: events)
          else (
            let message_end = offset + msg_size in
            let supported = message.template_id = t.layout.template_id in
            let events =
              if supported
              then events
              else
                diagnostic
                  packet
                  ~message
                  Diagnostic_code.Unsupported_template
                  (offset + 4)
                :: events
            in
            if message_end > length
            then
              List.rev
                (diagnostic packet ~message Diagnostic_code.Message_beyond_packet length
                 :: events)
            else if not supported
            then messages message_end events
            else (
              let decoded =
                decode_supported_message
                  t
                  t.schema
                  bytes
                  packet
                  message
                  (offset + 10)
                  message_end
              in
              messages message_end (List.rev_append decoded events))))
      in
      sequence_events @ messages 12 [])
;;
