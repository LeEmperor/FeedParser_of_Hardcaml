(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "validation_sink_unit_quickcheck_tests.ml" *)
(* Counter arithmetic, UART framing and record atomicity over seeded schedules. *)

open! Core
open Validation_sink_testbench

let%test_unit "counters, UART framing and record atomicity across seeds" =
  List.iter [ 1; 2; 3; 7; 11 ] ~f:(fun seed ->
    let result = run ~seed () in
    (* Each assertion below would pass vacuously on a silent run, so require traffic. *)
    [%test_pred: int] (fun n -> n >= 3) result.records;
    [%test_pred: int] (fun n -> n > 0) result.records_over_moving_counters;
    [%test_pred: int] (fun n -> n > 0) result.frozen_cycles;
    [%test_pred: int list] (List.for_all ~f:(fun n -> n > 0)) result.final)
;;

let%test_unit "baud divisor does not change the decoded record content" =
  let final divisor = (run ~seed:5 ~uart_divisor:divisor ()).final in
  [%test_result: int list] (final 7) ~expect:(final 4);
  [%test_result: int list] (final 16) ~expect:(final 4)
;;

(* The record is emitted on a fixed idle interval, so a longer interval must produce
   strictly fewer records over the same number of cycles while counting identically. *)
let%test_unit "snapshot interval sets record rate without disturbing counters" =
  let sparse = run ~seed:4 ~snapshot_cycles:600 () in
  let dense = run ~seed:4 ~snapshot_cycles:137 () in
  [%test_result: int list] sparse.final ~expect:dense.final;
  [%test_pred: int * int] (fun (a, b) -> a < b) (sparse.records, dense.records)
;;

let%test_unit "a long quiet run still frames every record correctly" =
  let result = run ~seed:9 ~cycles:12000 ~uart_divisor:3 ~snapshot_cycles:97 () in
  [%test_pred: int] (fun n -> n >= 10) result.records
;;
