open! Core
open! Hardcaml
open! Hardcaml_networking
open! Uart

(* RTL generators, one subcommand per emittable artifact. An explicit target is required,
   matching hardcaml_networking's generator. Output paths are resolved from the repository
   root even when this executable is invoked from [lib/common]. *)

module Circ_uart = Circuit.With_interface (Uart_test_top.I) (Uart_test_top.O)

module Circ_cme =
  Circuit.With_interface
    (Cme_of_hardcaml.Cme_feed_parser.I)
    (Cme_of_hardcaml.Cme_feed_parser.O)

module Circ_board =
  Circuit.With_interface
    (Cme_board_validation.Cme_feed_parser_validation_harness_arty.I)
    (Cme_board_validation.Cme_feed_parser_validation_harness_arty.O)

module Circ_byte_aligner =
  Circuit.With_interface (Cme_of_hardcaml.Byte_aligner.I) (Cme_of_hardcaml.Byte_aligner.O)

let emit ~scope ~path ?(notice = "") circuit =
  let rtl =
    Rtl.full_hierarchy
      (Rtl.create ~database:(Scope.circuit_database scope) Verilog [ circuit ])
  in
  let root = Option.value (Sys.getenv "DUNE_SOURCEROOT") ~default:"." in
  let output = Filename.concat root path in
  Out_channel.write_all output ~data:(notice ^ Rope.to_string rtl);
  Stdio.printf "wrote %s\n" output
;;

let target ~summary ~build =
  Command.basic
    ~summary
    (Command.Param.return (fun () ->
       let scope = Scope.create ~flatten_design:false () in
       build scope))
;;

let uart_cmd =
  target ~summary:"UART test top -> uart_test_top.v" ~build:(fun scope ->
    emit
      ~scope
      ~path:"uart_test_top.v"
      (Circ_uart.create_exn ~name:"uart_test_top" (Uart_test_top.create scope)))
;;

let cme_cmd =
  target ~summary:"CME MDP 3.0 feed parser -> cme_mdp3_feed_parser.v" ~build:(fun scope ->
    emit
      ~scope
      ~path:"cme_mdp3_feed_parser.v"
      ~notice:"// CME MDP 3.0 template-46 MBP parser; schema ID 1, pinned version 13.\n"
      (Circ_cme.create_exn
         ~name:"cme_mdp3_feed_parser"
         (Cme_of_hardcaml.Cme_feed_parser.create scope)))
;;

let board_cmd =
  target
    ~summary:
      "native Arty CME feed-parser harness -> cme_feed_parser_validation_harness_arty.v"
    ~build:(fun scope ->
      let module B = Cme_board_validation.Cme_feed_parser_validation_harness_arty in
      emit
        ~scope
        ~path:"cme_feed_parser_validation_harness_arty.v"
        ~notice:"// Native Arty A7-100T CME feed-parser validation harness.\n"
        (Circ_board.create_exn
           ~name:"cme_feed_parser_validation_harness_arty"
           (B.create scope)))
;;

let board_sim_cmd =
  target
    ~summary:
      "native Arty harness with accelerated UART -> \
       cme_feed_parser_validation_harness_arty_sim.v"
    ~build:(fun scope ->
      let module B = Cme_board_validation.Cme_feed_parser_validation_harness_arty in
      emit
        ~scope
        ~path:"cme_feed_parser_validation_harness_arty_sim.v"
        ~notice:
          "// Native board harness with accelerated UART timing for Phase 7 simulation.\n"
        (Circ_board.create_exn
           ~name:"cme_feed_parser_validation_harness_arty_sim"
           (B.create ~uart_divisor:4 ~snapshot_cycles:200 scope)))
;;

let byte_aligner_cmd =
  target ~summary:"CME byte aligner -> cme_byte_aligner.v" ~build:(fun scope ->
    emit
      ~scope
      ~path:"cme_byte_aligner.v"
      ~notice:
        "// CME byte aligner; max_consume 8. DUT for validation/synth_harness.sv.\n"
      (Circ_byte_aligner.create_exn
         ~name:"cme_byte_aligner"
         (Cme_of_hardcaml.Byte_aligner.create scope)))
;;

let () =
  Command_unix.run
    (Command.group
       ~summary:"CME Hardcaml RTL generators (specify a target)"
       [ "uart", uart_cmd
       ; "cme", cme_cmd
       ; "cme_feed_parser_validation_harness_arty", board_cmd
       ; "cme_feed_parser_validation_harness_arty_sim", board_sim_cmd
       ; "byte-aligner", byte_aligner_cmd
       ])
;;
