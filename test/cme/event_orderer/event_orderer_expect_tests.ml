(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "event_orderer_expect_tests.ml" *)
(* Ordered decoder updates and recovery diagnostics. *)
open! Core
open Event_orderer_testbench

let%expect_test "ordered abort and successful next message" =
  let o = run ~stalls:false recovery in
  print_s [%sexp (o.events : Event.t list)];
  [%expect
    {|
    (((kind 2) (seq 1) (index 0) (code 1)) ((kind 0) (seq 1) (index 0) (code 0))
     ((kind 0) (seq 1) (index 1) (code 0)) ((kind 2) (seq 1) (index 0) (code 5))
     ((kind 2) (seq 2) (index 0) (code 6)) ((kind 0) (seq 2) (index 0) (code 0))
     ((kind 1) (seq 2) (index 0) (code 0)) ((kind 2) (seq 3) (index 0) (code 2))
     ((kind 0) (seq 4) (index 0) (code 0)) ((kind 0) (seq 4) (index 1) (code 0))
     ((kind 1) (seq 4) (index 0) (code 0)))
    |}]
;;
