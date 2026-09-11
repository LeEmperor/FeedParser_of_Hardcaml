(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "cme_feed_parser_unit_quickcheck_tests.ml" *)
(* Phase 0 inactivity must be deliberately replaced when real parsing is integrated. *)

open! Core
open Cme_feed_parser_testbench

let assert_inactive observations =
  let expected : Output_snapshot.t =
    { ready = false; control_ready = false; event_valid = false; event_is_zero = true }
  in
  List.iter observations ~f:(fun (o : Observation.t) ->
    [%test_result: Output_snapshot.t] o.before ~expect:expected;
    [%test_result: Output_snapshot.t] o.after ~expect:expected)
;;

let%test_unit "inactive across reset, enable, keeps, traffic and control requests" =
  assert_inactive (run ())
;;

let%test_unit "arbitrary 64-bit inputs remain unacknowledged" =
  Quickcheck.test
    ~trials:8
    ~seed:(`Deterministic "phase0-inactive")
    ~sexp_of:[%sexp_of: int64]
    ~shrinker:Int64.quickcheck_shrinker
    Int64.quickcheck_generator
    ~f:(fun data -> assert_inactive (run ~data ()))
;;
