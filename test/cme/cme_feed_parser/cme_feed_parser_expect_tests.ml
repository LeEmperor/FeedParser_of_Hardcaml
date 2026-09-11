(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "cme_feed_parser_expect_tests.ml" *)
(* Compact Phase 0 golden shares the exhaustive scenario with assertions. *)

open! Core
open Cme_feed_parser_testbench

let%expect_test "inactive before and after reset, held traffic and controls" =
  let observations = run () in
  print_s
    [%sexp (List.length observations : int), (List.hd_exn observations : Observation.t)];
  [%expect
    {|
    (768
     ((before
       ((ready false) (control_ready false) (event_valid false)
        (event_is_zero true)))
      (after
       ((ready false) (control_ready false) (event_valid false)
        (event_is_zero true)))))
    |}]
;;
