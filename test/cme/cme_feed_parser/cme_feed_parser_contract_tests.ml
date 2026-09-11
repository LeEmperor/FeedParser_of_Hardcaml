(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "cme_feed_parser_contract_tests.ml" *)
(* Structural and provisional ABI checks; no cycle simulation is needed here. *)

open! Core
open! Hardcaml
open! Cme_of_hardcaml
module Parser = Cme_feed_parser

let check condition message = if not condition then failwith message

let expect_bits label actual expected =
  check (Bits.equal actual expected) ("unexpected " ^ label)
;;

let expected_inputs =
  [ "clock_i", 1
  ; "reset_i", 1
  ; "en_i", 1
  ; "data_i", 64
  ; "keep_i", 8
  ; "valid_i", 1
  ; "first_i", 1
  ; "last_i", 1
  ; "ingress_timestamp_i", 64
  ; "session_reset_i", 1
  ; "resync_valid_i", 1
  ; "resync_next_seq_i", 32
  ; "event_ready_i", 1
  ]
;;

let expected_outputs =
  [ "ready_o", 1; "control_ready_o", 1; "event_valid_o", 1; "event_o", 677 ]
;;

let test_rtl_ports () =
  let circuit = Parser.circuit () in
  let rtl = Rtl.full_hierarchy (Rtl.create Verilog [ circuit ]) |> Rope.to_string in
  let declarations =
    String.split_lines rtl
    |> List.map ~f:String.strip
    |> List.filter ~f:(fun line ->
      String.is_prefix line ~prefix:"input " || String.is_prefix line ~prefix:"output ")
    |> List.sort ~compare:String.compare
  in
  let declaration direction (name, width) =
    if width = 1
    then sprintf "%s %s;" direction name
    else sprintf "%s [%d:0] %s;" direction (width - 1) name
  in
  let expected =
    List.map expected_inputs ~f:(declaration "input")
    @ List.map expected_outputs ~f:(declaration "output")
    |> List.sort ~compare:String.compare
  in
  check (List.equal String.equal declarations expected) "generated RTL port ABI changed";
  check
    (String.is_substring rtl ~substring:"module cme_mdp3_feed_parser (")
    "generated RTL module name changed"
;;

let test_event_layout () =
  let module T = Cme_types in
  check (T.Event.width = 677) "provisional event width changed; review the contract";
  let empty = T.Event.map T.Event.port_widths ~f:Bits.zero in
  let event =
    { empty with
      kind = Bits.of_int_trunc ~width:2 T.Event_kind.diagnostic
    ; packet = { empty.packet with ingress_timestamp = Bits.ones 64 }
    ; price_mantissa = Bits.of_string "64'h8000000000000001"
    ; diagnostic_code = Bits.of_int_trunc ~width:8 T.Diagnostic_code.sequence_gap
    ; diagnostic_byte_offset = Bits.of_int_trunc ~width:16 0x1234
    }
  in
  let packed = T.Event.Of_bits.pack event in
  expect_bits "event kind at bits 1:0" (Bits.select packed ~high:1 ~low:0) event.kind;
  expect_bits
    "timestamp at bits 65:2"
    (Bits.select packed ~high:65 ~low:2)
    event.packet.ingress_timestamp;
  expect_bits
    "signed price container at bits 486:423"
    (Bits.select packed ~high:486 ~low:423)
    event.price_mantissa;
  expect_bits
    "diagnostic code at bits 627:620"
    (Bits.select packed ~high:627 ~low:620)
    event.diagnostic_code;
  expect_bits
    "diagnostic offset at bits 676:661"
    (Bits.select packed ~high:676 ~low:661)
    event.diagnostic_byte_offset;
  T.Event.iter2 event (T.Event.Of_bits.unpack packed) ~f:(expect_bits "event round trip");
  check
    (List.equal
       Int.equal
       [ T.Event_kind.mbp_update; T.Event_kind.end_of_event; T.Event_kind.diagnostic ]
       [ 0; 1; 2 ])
    "event kind encodings changed";
  check
    (List.equal
       Int.equal
       [ T.Diagnostic_code.none
       ; T.Diagnostic_code.sequence_gap
       ; T.Diagnostic_code.duplicate_or_late
       ; T.Diagnostic_code.truncated_packet_header
       ; T.Diagnostic_code.invalid_message_size
       ; T.Diagnostic_code.message_beyond_packet
       ; T.Diagnostic_code.unsupported_template
       ; T.Diagnostic_code.schema_incompatibility
       ; T.Diagnostic_code.invalid_enum
       ; T.Diagnostic_code.internal_overflow
       ]
       (List.init 10 ~f:Fn.id))
    "diagnostic encodings changed"
;;

let test_hierarchy () =
  let scope = Scope.create ~flatten_design:false () in
  let module C = Circuit.With_interface (Parser.I) (Parser.O) in
  let circuit =
    C.create_exn ~name:"parser_wrapper" (Parser.hierarchical ~instance:"parser" scope)
  in
  check (List.length (Circuit.instantiations circuit) = 1) "missing parser child";
  let rtl =
    Rtl.create ~database:(Scope.circuit_database scope) Verilog [ circuit ]
    |> Rtl.full_hierarchy
    |> Rope.to_string
  in
  check
    (String.is_substring rtl ~substring:"module cme_mdp3_feed_parser (")
    "hierarchy omitted parser implementation"
;;

let test_configuration () =
  check (Cme_config.default.ingress_fifo_depth = 64) "default ingress depth changed";
  check (Cme_config.default.event_fifo_depth = 16) "default event depth changed";
  ignore
    (Parser.circuit ~config:{ ingress_fifo_depth = 1; event_fifo_depth = 3 } ()
     : Circuit.t);
  List.iter
    [ { Cme_config.ingress_fifo_depth = 0; event_fifo_depth = 16 }
    ; { Cme_config.ingress_fifo_depth = 64; event_fifo_depth = -1 }
    ]
    ~f:(fun config ->
      let rejected =
        try
          ignore (Parser.circuit ~config () : Circuit.t);
          false
        with
        | Invalid_argument _ -> true
      in
      check rejected "invalid FIFO configuration accepted")
;;

let%test_unit "public RTL port ABI" = test_rtl_ports ()
let%test_unit "provisional event layout and reserved encodings" = test_event_layout ()
let%test_unit "parser child is registered and emitted" = test_hierarchy ()
let%test_unit "configuration defaults and invalid capacities" = test_configuration ()

let%test_unit "event storage rejects zero and negative capacity" =
  List.iter [ 0; -1 ] ~f:(fun depth ->
    let module C = Circuit.With_interface (Event_fifo.I) (Event_fifo.O) in
    check
      (try
         ignore
           (C.create_exn
              ~name:"invalid"
              (Event_fifo.create ~depth (Scope.create ~flatten_design:true ()))
            : Circuit.t);
         false
       with
       | Invalid_argument _ -> true)
      "invalid storage depth accepted")
;;

let%test_unit "transport fixture registers and emits both portable children" =
  let module P = Stream_test_support.Stream_fixture.Pass_through in
  let module C = Circuit.With_interface (P.I) (P.O) in
  let scope = Scope.create ~flatten_design:false () in
  let circuit = C.create_exn ~name:"stream_wrapper" (P.create ~depth:3 scope) in
  [%test_result: int] (List.length (Circuit.instantiations circuit)) ~expect:2;
  let rtl =
    Rtl.create ~database:(Scope.circuit_database scope) Verilog [ circuit ]
    |> Rtl.full_hierarchy
    |> Rope.to_string
  in
  List.iter [ "cme_ingress_fifo"; "cme_byte_aligner" ] ~f:(fun name ->
    check
      (String.is_substring rtl ~substring:("module " ^ name ^ " ("))
      ("missing child implementation: " ^ name))
;;
