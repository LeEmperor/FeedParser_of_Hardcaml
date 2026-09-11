(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "xilinx_reports.ml" *)
(* Explicit device reporting; without -run only Verilog/XDC/Tcl are generated. FIFO
   capacities are fixed here and printed with every invocation. *)

open! Core
open! Async
open Cme_of_hardcaml
open Cme_report_support.Report_support
module Stream = Stream_test_support.Stream_fixture.Pass_through
module Ingress_command = Reports.Command.With_interface (Ingress_fifo.I) (Ingress_fifo.O)
module Event_command = Reports.Command.With_interface (Event_fifo.I) (Event_fifo.O)
module Aligner_command = Reports.Command.With_interface (Byte_aligner.I) (Byte_aligner.O)
module Stream_command = Reports.Command.With_interface (Stream.I) (Stream.O)

module Parser_command =
  Reports.Command.With_interface (Cme_feed_parser.I) (Cme_feed_parser.O)

let () =
  Command_unix.run
    (Command.group
       ~summary:
         "CME device reports: ingress depth 64, event depth 16; parser is an inactive \
          skeleton"
       [ ( "ingress-fifo"
         , report_command ~name:"cme_ingress_fifo" (fun flags ->
             printf
               "Target: ingress-fifo; ingress depth=64; event depth=16 (where applicable)\n";
             Ingress_command.run
               ~primitive_groups:[]
               ~name:"cme_ingress_fifo"
               ~flags
               (fun scope i -> Ingress_fifo.create ~depth:64 scope i)) )
       ; ( "event-fifo"
         , report_command ~name:"cme_event_fifo" (fun flags ->
             printf
               "Target: event-fifo; ingress depth=64; event depth=16 (where applicable)\n";
             Event_command.run
               ~primitive_groups:[]
               ~name:"cme_event_fifo"
               ~flags
               (fun scope i -> Event_fifo.create ~depth:16 scope i)) )
       ; ( "byte-aligner"
         , report_command ~name:"cme_byte_aligner" (fun flags ->
             printf
               "Target: byte-aligner; ingress depth=64; event depth=16 (where applicable)\n";
             Aligner_command.run
               ~primitive_groups:[]
               ~name:"cme_byte_aligner"
               ~flags
               Byte_aligner.create) )
       ; ( "stream-foundation"
         , report_command ~name:"cme_stream_fixture" (fun flags ->
             printf
               "Target: stream-foundation; ingress depth=64; event depth=16 (where \
                applicable)\n";
             Stream_command.run
               ~primitive_groups:[]
               ~name:"cme_stream_fixture"
               ~flags
               (fun scope i -> Stream.create ~depth:64 scope i)) )
       ; ( "cme-feed-parser"
         , report_command ~name:"cme_feed_parser" (fun flags ->
             printf
               "Target: cme-feed-parser; ingress depth=64; event depth=16 (where \
                applicable)\n";
             Parser_command.run
               ~primitive_groups:[]
               ~name:"cme_feed_parser"
               ~flags
               (fun scope i -> Cme_feed_parser.create ~config:Cme_config.default scope i))
         )
       ])
;;
