(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "generate_stream_fixture.ml" *)
(* Full hierarchy exports for the optional Yosys hierarchy and Icarus elaboration checks. *)

open! Core
open! Hardcaml
open! Cme_of_hardcaml

let () =
  let directory =
    match Array.to_list (Sys.get_argv ()) with
    | [ _; directory ] -> directory
    | _ -> failwith "usage: generate_stream_fixture.exe OUTPUT_DIRECTORY"
  in
  let emit name circuit scope =
    let rtl =
      Rtl.create ~database:(Scope.circuit_database scope) Verilog [ circuit ]
      |> Rtl.full_hierarchy
      |> Rope.to_string
    in
    Out_channel.write_all (Filename.concat directory (name ^ ".v")) ~data:rtl
  in
  let scope = Scope.create ~flatten_design:false () in
  let module C = Circuit.With_interface (Ingress_fifo.I) (Ingress_fifo.O) in
  emit
    "cme_ingress_fifo"
    (C.create_exn ~name:"cme_ingress_fifo" (Ingress_fifo.create scope))
    scope;
  let scope = Scope.create ~flatten_design:false () in
  let module C = Circuit.With_interface (Event_fifo.I) (Event_fifo.O) in
  emit
    "cme_event_fifo"
    (C.create_exn ~name:"cme_event_fifo" (Event_fifo.create scope))
    scope;
  let scope = Scope.create ~flatten_design:false () in
  let module C = Circuit.With_interface (Byte_aligner.I) (Byte_aligner.O) in
  emit
    "cme_byte_aligner"
    (C.create_exn ~name:"cme_byte_aligner" (Byte_aligner.create scope))
    scope;
  let scope = Scope.create ~flatten_design:false () in
  let module C =
    Circuit.With_interface
      (Stream_test_support.Stream_fixture.Pass_through.I)
      (Stream_test_support.Stream_fixture.Pass_through.O)
  in
  emit
    "cme_stream_fixture"
    (C.create_exn
       ~name:"cme_stream_fixture"
       (Stream_test_support.Stream_fixture.Pass_through.create scope))
    scope;
  let scope = Scope.create ~flatten_design:false () in
  let module C = Circuit.With_interface (Cme_feed_parser.I) (Cme_feed_parser.O) in
  emit
    "cme_mdp3_feed_parser"
    (C.create_exn ~name:"cme_mdp3_feed_parser" (Cme_feed_parser.create scope))
    scope;
  let scope = Scope.create ~flatten_design:false () in
  let module C = Circuit.With_interface (Packet_pipeline.I) (Packet_pipeline.O) in
  emit
    "cme_packet_pipeline"
    (C.create_exn ~name:"cme_packet_pipeline" (Packet_pipeline.create scope))
    scope;
  let scope = Scope.create ~flatten_design:false () in
  let module C = Circuit.With_interface (Sbe_message_iterator.I) (Sbe_message_iterator.O)
  in
  emit
    "cme_sbe_message_iterator"
    (C.create_exn
       ~name:"cme_sbe_message_iterator"
       (Sbe_message_iterator.create ~supported_templates:[ 42 ] scope))
    scope;
  let scope = Scope.create ~flatten_design:false () in
  let module C = Circuit.With_interface (Message_pipeline.I) (Message_pipeline.O) in
  emit
    "cme_message_pipeline"
    (C.create_exn
       ~name:"cme_message_pipeline"
       (Message_pipeline.create ~supported_templates:[ 42 ] scope))
    scope;
  let scope = Scope.create ~flatten_design:false () in
  let module C = Circuit.With_interface (Event_orderer.I) (Event_orderer.O) in
  emit
    "cme_event_orderer"
    (C.create_exn ~name:"cme_event_orderer" (Event_orderer.create scope))
    scope;
  ()
;;
