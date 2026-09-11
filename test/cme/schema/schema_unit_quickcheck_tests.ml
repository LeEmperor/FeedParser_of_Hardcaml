(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "schema_unit_quickcheck_tests.ml" *)
(* Schema pin, generated descriptor, golden decoder, and schema-valid random fixtures. *)

open! Core
open Schema_fixture
module G = Cme_schema.Golden_decoder

let decoder () = G.create ~schema_file

let updates events =
  List.filter_map events ~f:(function
    | G.Mbp_update update -> Some update
    | _ -> None)
;;

let diagnostics events =
  List.filter_map events ~f:(function
    | G.Diagnostic diagnostic -> Some diagnostic
    | _ -> None)
;;

let%test_unit "pinned metadata and generated descriptor agree with hand-reviewed \
               template 46"
  =
  let schema = Cme_schema.Schema_xml.load schema_file in
  [%test_result: int * int * string]
    (schema.id, schema.version, schema.byte_order)
    ~expect:(1, 13, "littleEndian");
  let module D = Cme_of_hardcaml.Generated_mbp_descriptor in
  [%test_result: int * int * int * int * int]
    ( D.template_id
    , D.root_block_length
    , D.mbp_group_block_length
    , D.price_exponent
    , D.Entry_type.bit_width )
    ~expect:(46, 11, 32, -9, 8);
  [%test_result: int list] D.Update_action.valid_values ~expect:[ 0; 1; 2; 3; 4; 5 ];
  [%test_result: int list]
    D.Entry_type.valid_values
    ~expect:(List.map [ '0'; '1'; 'E'; 'F'; 'J'; 'w'; 'x' ] ~f:Char.to_int);
  [%test_result: int list]
    [ D.Transact_time.offset
    ; D.Match_event_indicator.offset
    ; D.Price_mantissa.offset
    ; D.Entry_size.offset
    ; D.Security_id.offset
    ; D.Rpt_seq.offset
    ; D.Number_of_orders.offset
    ; D.Price_level.offset
    ; D.Update_action.offset
    ; D.Entry_type.offset
    ; D.Tradeable_size.offset
    ]
    ~expect:[ 0; 8; 0; 8; 12; 16; 20; 24; 25; 26; 27 ];
  [%test_result: int * int * int * int]
    ( D.Mbp_dimension.encoded_size
    , D.Mbp_dimension.count_offset
    , D.Order_dimension.encoded_size
    , D.Order_dimension.count_offset )
    ~expect:(3, 2, 8, 7);
  [%test_result: string option * string option * int]
    (D.Price_mantissa.null_value, D.Entry_size.null_value, D.Tradeable_size.since_version)
    ~expect:(Some "9223372036854775807", Some "2147483647", 10)
;;

let%test_unit "hand-checked signed limits, nulls, enums, and end-of-event" =
  let entry =
    { price = -123_456_789L
    ; size = -0x8000_0000L
    ; security_id = -1L
    ; rpt_seq = 0xffff_ffffL
    ; orders = 0x7fff_ffffL
    ; level = 255
    ; action = 5
    ; entry_type = 'F'
    ; tradeable = 0x7fff_ffffL
    }
  in
  let events =
    G.decode_payload
      ~ingress_timestamp:55L
      (decoder ())
      (packet 7L [ message ~match_event_indicator:0x80 [ entry ] ])
  in
  match events with
  | [ G.Mbp_update update; G.End_of_event end_event ] ->
    [%test_result: int64 * int64 * int64 * int64 option * int64 option]
      ( update.packet.ingress_timestamp
      , update.security_id
      , update.rpt_seq
      , update.number_of_orders
      , update.tradeable_size )
      ~expect:(55L, -1L, 0xffff_ffffL, None, None);
    [%test_result: int64 option * int64 option * int * int * int * bool]
      ( update.price_mantissa
      , update.entry_size
      , update.price_level
      , update.update_action
      , update.entry_type
      , update.message_last )
      ~expect:(Some (-123_456_789L), Some (-0x8000_0000L), 255, 5, Char.to_int 'F', true);
    [%test_result: int] end_event.match_event_indicator ~expect:0x80
  | _ -> failwith (Sexp.to_string_hum ([%sexp_of: G.event list] events))
;;

let%test_unit "runtime blocks, version 9 omissions, appended fields, and MBO skip" =
  let v9 =
    G.decode_payload (decoder ()) (packet 1L [ message ~version:9 [ default_entry ] ])
  in
  [%test_result: int64 option list]
    (List.map (updates v9) ~f:(fun update -> update.tradeable_size))
    ~expect:[ None ];
  let newer =
    G.decode_payload
      (decoder ())
      (packet
         2L
         [ message
             ~version:14
             ~root_block:19
             ~entry_block:48
             ~order_block:31
             ~order_count:2
             [ default_entry; { default_entry with rpt_seq = 8L } ]
         ])
  in
  [%test_result: int64 list]
    (List.map (updates newer) ~f:(fun update -> update.rpt_seq))
    ~expect:[ 7L; 8L ]
;;

let%test_unit "all nullable fields distinguish sentinels from signed minima" =
  let entry =
    { default_entry with
      price = Int64.max_value
    ; size = 0x7fff_ffffL
    ; orders = -0x8000_0000L
    ; tradeable = -0x8000_0000L
    }
  in
  match updates (G.decode_payload (decoder ()) (packet 1L [ message [ entry ] ])) with
  | [ update ] ->
    [%test_result: int64 option * int64 option * int64 option * int64 option]
      ( update.price_mantissa
      , update.entry_size
      , update.number_of_orders
      , update.tradeable_size )
      ~expect:(None, None, Some (-0x8000_0000L), Some (-0x8000_0000L))
  | _ -> assert false
;;

let%test_unit "all update actions and book entry types use their raw schema encodings" =
  let actions = [ 0; 1; 2; 3; 4; 5 ] in
  let entry_types = [ '0'; '1'; 'E'; 'F'; 'J'; 'w'; 'x' ] in
  let entries =
    List.concat_map actions ~f:(fun action ->
      List.map entry_types ~f:(fun entry_type ->
        { default_entry with action; entry_type }))
  in
  let decoded = updates (G.decode_payload (decoder ()) (packet 1L [ message entries ])) in
  [%test_result: (int * int) list]
    (List.map decoded ~f:(fun update -> update.update_action, update.entry_type))
    ~expect:
      (List.concat_map actions ~f:(fun action ->
         List.map entry_types ~f:(fun entry_type -> action, Char.to_int entry_type)))
;;

let%test_unit "zero-entry end-of-event and schema/enum/structural diagnostics" =
  let zero =
    G.decode_payload (decoder ()) (packet 1L [ message ~match_event_indicator:0x80 [] ])
  in
  [%test_result: int * int] (List.length (updates zero), List.length zero) ~expect:(0, 1);
  let cases =
    [ packet 1L [ message ~schema:2 [ default_entry ] ]
    ; packet 1L [ message ~root_block:8 [ default_entry ] ]
    ; packet 1L [ message ~entry_block:31 [ default_entry ] ]
    ; packet 1L [ message [ { default_entry with action = 6 } ] ]
    ; packet 1L [ message ~version:9 [ { default_entry with entry_type = 'w' } ] ]
    ; packet 1L [ raw_message ~declared_size:9 "bad" ]
    ; packet 1L [ raw_message ~declared_size:100 "short" ]
    ]
  in
  let codes =
    List.map cases ~f:(fun payload ->
      match diagnostics (G.decode_payload (decoder ()) payload) with
      | [ diagnostic ] -> diagnostic.code
      | diagnostics ->
        failwith (Sexp.to_string_hum ([%sexp_of: G.diagnostic list] diagnostics)))
  in
  [%test_result: G.Diagnostic_code.t list]
    codes
    ~expect:
      [ Schema_incompatibility
      ; Schema_incompatibility
      ; Schema_incompatibility
      ; Invalid_enum
      ; Invalid_enum
      ; Invalid_message_size
      ; Message_beyond_packet
      ]
;;

let%test_unit "sequence gap precedes updates and duplicate is dropped" =
  let decoder = decoder () in
  ignore
    (G.decode_payload decoder (packet 10L [ message [ default_entry ] ]) : G.event list);
  let gap = G.decode_payload decoder (packet 12L [ message [ default_entry ] ]) in
  let duplicate = G.decode_payload decoder (packet 12L [ message [ default_entry ] ]) in
  (match gap with
   | G.Diagnostic diagnostic :: G.Mbp_update update :: _ ->
     [%test_result: G.Diagnostic_code.t] diagnostic.code ~expect:Sequence_gap;
     [%test_result: bool] update.packet.channel_valid ~expect:false
   | _ -> assert false);
  [%test_result: G.Diagnostic_code.t list]
    (List.map (diagnostics duplicate) ~f:(fun diagnostic -> diagnostic.code))
    ~expect:[ Duplicate_or_late ];
  [%test_result: int] (List.length (updates duplicate)) ~expect:0
;;

let%test_unit "classic PCAP extraction preserves payload and timestamp" =
  let payload = packet 1L [ message [ default_entry ] ] in
  let extracted = Cme_schema.Pcap_payloads.of_string (pcap payload) in
  [%test_result: (int64 * string) list]
    (List.map extracted ~f:(fun value -> value.ingress_timestamp, value.bytes))
    ~expect:[ 2_000_003_000L, payload ];
  [%test_result: int]
    (Cme_schema.Pcap_payloads.decode (decoder ()) extracted |> updates |> List.length)
    ~expect:1
;;

let%test_unit "schema-valid randomized values decode without consulting generated offsets"
  =
  Quickcheck.test
    ~trials:100
    ~seed:(`Deterministic "phase4-golden-schema-valid")
    ~sexp_of:[%sexp_of: int]
    Int.quickcheck_generator
    ~f:(fun seed ->
      let random = Random.State.make [| seed |] in
      let count = Random.State.int random 9 in
      let action_values = [| 0; 1; 2; 3; 4; 5 |] in
      let type_values = [| '0'; '1'; 'E'; 'F'; 'J'; 'w'; 'x' |] in
      let entries =
        List.init count ~f:(fun index ->
          { price = Random.State.int64 random Int64.max_value
          ; size = Int64.of_int32 (Random.State.int32 random Int32.max_value)
          ; security_id = Int64.of_int32 (Random.State.int32 random Int32.max_value)
          ; rpt_seq = Int64.of_int (index + 1)
          ; orders = Int64.of_int (Random.State.int random 1_000_000)
          ; level = Random.State.int random 256
          ; action = action_values.(Random.State.int random (Array.length action_values))
          ; entry_type = type_values.(Random.State.int random (Array.length type_values))
          ; tradeable = Int64.of_int (Random.State.int random 1_000_000)
          })
      in
      let events = G.decode_payload (decoder ()) (packet 1L [ message entries ]) in
      [%test_result: int] (List.length (updates events)) ~expect:count;
      [%test_result: int] (List.length (diagnostics events)) ~expect:0)
;;

let%test_unit "unsupported selected-template construct reports the template and element" =
  let xml =
    "<?xml version=\"1.0\"?><messageSchema package=\"x\" id=\"1\" version=\"1\" \
     description=\"x\" byteOrder=\"littleEndian\"><types/><message name=\"Selected\" \
     id=\"1\" blockLength=\"0\"><data name=\"tail\"/></message></messageSchema>"
  in
  match Cme_schema.Schema_xml.of_string xml with
  | _ -> assert false
  | exception Cme_schema.Schema_xml.Schema_error message ->
    assert (
      String.is_substring message ~substring:"unsupported <data> in template Selected")
;;
