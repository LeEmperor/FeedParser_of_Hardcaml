(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "cme_feed_parser_legacy_assertion_test.ml" *)
(* Executable Phase 0 contract checks. These validate an inactive skeleton, not packet
   parsing, sequencing, FIFO behavior, or throughput.
*)

(* Tags: [{ "DEPRECATED" ; "ASSERTION_TEST" }] *)

open! Core
open! Hardcaml
open! Cme_of_hardcaml
module Parser = Cme_feed_parser
module Sim = Cyclesim.With_interface (Parser.I) (Parser.O)

let check condition message = if not condition then failwith message

let expect_bits label actual expected =
  check (Bits.equal actual expected) ("unexpected " ^ label)
;;

let test_inactive () =
  let sim = Sim.create (Parser.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs sim in
  Parser.I.iter2 i Parser.I.port_widths ~f:(fun port width -> port := Bits.zero width);
  let cycle () =
    Cyclesim.cycle sim;
    expect_bits "ready_o" !(o.ready_o) Bits.gnd;
    expect_bits "control_ready_o" !(o.control_ready_o) Bits.gnd;
    expect_bits "event_valid_o" !(o.event_valid_o) Bits.gnd;
    expect_bits "event_o" !(o.event_o) (Bits.zero 677)
  in
  let restart () =
    (* The skeleton never accepts an offer, so reset explicitly cancels it before a
       different payload or control is presented. *)
    i.reset_i := Bits.vdd;
    i.valid_i := Bits.gnd;
    i.session_reset_i := Bits.gnd;
    i.resync_valid_i := Bits.gnd;
    cycle ();
    i.reset_i := Bits.gnd
  in
  cycle ();
  (* Reset both with enable low and high; simultaneous payload/control requests must not
     be acknowledged by the skeleton, even with a ready consumer. *)
  List.iter [ false; true ] ~f:(fun enabled ->
    i.en_i := Bits.of_bool enabled;
    i.reset_i := Bits.vdd;
    i.valid_i := Bits.vdd;
    i.first_i := Bits.vdd;
    i.last_i := Bits.vdd;
    i.keep_i := Bits.of_int_trunc ~width:8 0xff;
    i.session_reset_i := Bits.vdd;
    i.resync_valid_i := Bits.vdd;
    i.event_ready_i := Bits.vdd;
    cycle ());
  i.reset_i := Bits.gnd;
  i.data_i := Bits.of_string "64'hfedcba9876543210";
  i.ingress_timestamp_i := Bits.of_string "64'h123456789abcdef0";
  i.resync_next_seq_i := Bits.ones 32;
  (* Held first/last qualifiers, every legal final keep, output backpressure, enable
     changes, and bubbles. No offered beat is ever transferred. *)
  List.iter [ false; true; false; true ] ~f:(fun enabled ->
    i.en_i := Bits.of_bool enabled;
    List.iter [ false; true ] ~f:(fun output_ready ->
      i.event_ready_i := Bits.of_bool output_ready;
      for byte_count = 1 to 8 do
        restart ();
        i.valid_i := Bits.vdd;
        i.keep_i := Bits.of_int_trunc ~width:8 ((1 lsl byte_count) - 1);
        cycle ();
        cycle ()
      done;
      restart ();
      cycle ()));
  (* Normal active operation and independent control requests are also inactive. *)
  i.en_i := Bits.vdd;
  i.event_ready_i := Bits.vdd;
  List.iter
    [ false, false; true, false; false, true ]
    ~f:(fun (reset, resync) ->
      restart ();
      i.valid_i := Bits.vdd;
      i.session_reset_i := Bits.of_bool reset;
      i.resync_valid_i := Bits.of_bool resync;
      cycle ());
  i.reset_i := Bits.vdd;
  i.en_i := Bits.gnd;
  cycle ()
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

let () =
  test_rtl_ports ();
  test_event_layout ();
  test_hierarchy ();
  test_configuration ();
  test_inactive ();
  print_endline
    "PASS: CME Phase 0 interfaces, event ABI, configuration, and inactive reset/enable \
     smoke checks"
;;
