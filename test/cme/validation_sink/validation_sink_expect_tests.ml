(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "validation_sink_expect_tests.ml" *)
(* A readable trace of one seeded board-observability run. *)

open! Core
open Validation_sink_testbench

let%expect_test "seeded sink run" =
  print_s [%sexp (run ~seed:1 () : Observation.t)];
  [%expect
    {|
    ((records 3) (records_over_moving_counters 3)
     (final (1092 1249 1209 1193 434 218 286 308)) (frozen_cycles 488))
    |}]
;;
