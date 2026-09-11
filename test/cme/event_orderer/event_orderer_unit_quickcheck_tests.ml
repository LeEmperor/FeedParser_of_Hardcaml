(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "event_orderer_unit_quickcheck_tests.ml" *)
(* Delayed completion, terminal abort, event backpressure and enable/reset coverage. *)
open! Core
open Event_orderer_testbench

let%test_unit "abort follows completed updates, later diagnostics wait for completion" =
  let o = run ~sink_block_until:100 recovery in
  assert (o.stalls > 0);
  [%test_result: int] o.aborts ~expect:1;
  [%test_result: int] o.completions ~expect:3
;;

let%test_unit "reset cancels stalled decoder and pending abort" =
  List.iter [ 5; 12; 20; 30 ] ~f:(fun reset_at ->
    ignore (run ~reset_at ~sink_block_until:80 recovery : Observation.t))
;;

let%test_unit "seeded decoder delays, pauses and event stalls" =
  Quickcheck.test
    ~trials:50
    ~seed:(`Deterministic "phase3-event-orderer")
    ~sexp_of:[%sexp_of: int]
    ~shrinker:Int.quickcheck_shrinker
    (Int.gen_incl 1 100000)
    ~f:(fun seed -> ignore (run ~seed recovery : Observation.t))
;;

let%test_unit "zero-body message completes before a following diagnostic" =
  ignore
    (run ~sink_block_until:80 [ Token.Empty 1; Diagnostic (2, 6); Empty 3 ]
     : Observation.t)
;;
