(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "ingress_fifo_expect_tests.ml" *)
(* Small reviewed traces reuse the unit-test scenario. *)

open! Core
open Ingress_fifo_testbench

let%expect_test "two asymmetric packets, second with a partial final beat" =
  let result = run_literal () in
  List.iter result.received ~f:(fun b ->
    print_s
      [%sexp
        { data = (sprintf "0x%016Lx" b.data : string)
        ; keep = (sprintf "0x%02x" b.keep : string)
        ; first = (b.first : bool)
        ; last = (b.last : bool)
        ; timestamp = (sprintf "0x%016Lx" b.timestamp : string)
        }]);
  [%expect
    {|
    ((data 0xfedcba9876543210) (keep 0xff) (first true) (last true)
     (timestamp 0x0000000000000000))
    ((data 0xa5a5a5a5a5636261) (keep 0x07) (first true) (last true)
     (timestamp 0x0000000000000000))
    |}]
;;
