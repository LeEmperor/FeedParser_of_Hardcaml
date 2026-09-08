open! Core
open! Hardcaml
open! Hardcaml_networking
open! Uart

let uart_circuit () =
  let scope = Scope.create ~flatten_design:false () in
  let module Circ = Circuit.With_interface (Uart_test_top.I) (Uart_test_top.O) in
  ( Circ.create_exn ~name:"uart_test_top" (Uart_test_top.create scope)
  , Scope.circuit_database scope )
;;

let cme_circuit () =
  let scope = Scope.create ~flatten_design:false () in
  let module P = Cme_of_hardcaml.Cme_feed_parser in
  let module Circ = Circuit.With_interface (P.I) (P.O) in
  ( Circ.create_exn ~name:"cme_mdp3_feed_parser" (P.create scope)
  , Scope.circuit_database scope )
;;

let board_circuit () =
  let scope = Scope.create ~flatten_design:false () in
  let module B = Cme_board_validation.Cme_board_top in
  let module Circ = Circuit.With_interface (B.I) (B.O) in
  Circ.create_exn ~name:"cme_board_top" (B.create scope), Scope.circuit_database scope
;;

(* Same datapath as the board build with the UART timing collapsed, so an Icarus run
   observes complete status records in a few hundred microseconds instead of a second.
   Only the divisors differ; the module name is distinct so the two can never be confused
   for one another in a synthesis script. *)
let core_sim_circuit () =
  let scope = Scope.create ~flatten_design:false () in
  let module C = Cme_board_validation.Cme_validation_core in
  let module Circ = Circuit.With_interface (C.I) (C.O) in
  ( Circ.create_exn
      ~name:"cme_validation_core_sim"
      (C.create ~uart_divisor:4 ~snapshot_cycles:200 scope)
  , Scope.circuit_database scope )
;;

let byte_aligner_circuit () =
  let scope = Scope.create ~flatten_design:false () in
  let module A = Cme_of_hardcaml.Byte_aligner in
  let module Circ = Circuit.With_interface (A.I) (A.O) in
  Circ.create_exn ~name:"cme_byte_aligner" (A.create scope), Scope.circuit_database scope
;;

let () =
  let filename, (circ, database), notice =
    match Array.to_list (Sys.get_argv ()) with
    | [ _ ] | [ _; "uart" ] -> "uart_test_top.v", uart_circuit (), ""
    | [ _; "cme" ] ->
      ( "cme_mdp3_feed_parser.v"
      , cme_circuit ()
      , "// CME MDP 3.0 template-46 MBP parser; schema ID 1, pinned version 13.\n" )
    | [ _; "board" ] ->
      ( "cme_board_top.v"
      , board_circuit ()
      , "// Arty A7-100T CME feed-parser validation harness. Instantiates \
         udp_rx_64_mac_top,\n\
         // emitted by hardcaml_networking's own `udp-rx-64` target.\n" )
    | [ _; "core-sim" ] ->
      ( "cme_validation_core_sim.v"
      , core_sim_circuit ()
      , "// Board datapath with accelerated UART timing, for validation/phase7 only.\n" )
    | [ _; "byte-aligner" ] ->
      ( "cme_byte_aligner.v"
      , byte_aligner_circuit ()
      , "// CME byte aligner; max_consume 8. DUT for validation/synth_harness.sv.\n" )
    | _ -> failwith "usage: generate.exe [uart|cme|board|core-sim|byte-aligner]"
  in
  let hier = Rtl.create ~database Verilog [ circ ] in
  let rtl = Rtl.full_hierarchy hier in
  Out_channel.write_all filename ~data:(notice ^ Rope.to_string rtl);
  Stdio.printf "Generated %s\n" filename
;;
