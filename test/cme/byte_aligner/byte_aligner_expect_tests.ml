(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "byte_aligner_expect_tests.ml" *)
(* Compact peek/consume trace, with assertions in the unit suite. *)

open! Core
open Byte_aligner_testbench

let%expect_test "partial final abc and consume limits" =
  List.iter (run_limits ()) ~f:(fun o ->
    print_s
      [%sexp
        { request = (o.request : int)
        ; available = (o.available : int)
        ; ready = (o.ready : bool)
        ; after_available = (o.after_available : int)
        }]);
  [%expect
    {|
    ((request 4) (available 3) (ready false) (after_available 3))
    ((request 8) (available 3) (ready false) (after_available 3))
    ((request 9) (available 3) (ready false) (after_available 3))
    ((request 15) (available 3) (ready false) (after_available 3))
    ((request 0) (available 3) (ready true) (after_available 3))
    ((request 3) (available 3) (ready true) (after_available 0))
    |}]
;;
