(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "validation_core_expect_tests.ml" *)
(* A readable trace of the mixed selected/filtered board scenario. *)

open! Core
open Validation_core_testbench

let%expect_test "mixed selected and filtered traffic" =
  let result =
    run
      [ selected (simple 1L)
      ; filtered (simple 900L)
      ; selected (simple 2L)
      ; selected (simple 2L)
      ; selected (simple 4L)
      ]
  in
  print_s [%sexp (result : Observation.t)];
  [%expect
    {|
    ((packets 4) (updates 3) (end_of_event 3) (diagnostics 2) (crc_errors 0)
     (ip_errors 0) (sequence_gaps 1) (duplicates 1) (filtered_beats 10)
     (filtered_while_parser_busy 10))
    |}]
;;
