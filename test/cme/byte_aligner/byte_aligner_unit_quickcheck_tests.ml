(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "byte_aligner_unit_quickcheck_tests.ml" *)
(* Coverage requirements are assertions over plain typed scenario observations. *)

open! Core
open Byte_aligner_testbench

let assert_coverage ?(max_consume = 8) (result : Observation.t) =
  [%test_result: bool list] result.offsets ~expect:(List.init 8 ~f:(Fn.const true));
  [%test_result: bool list]
    result.counts
    ~expect:(List.init (max_consume + 1) ~f:(Fn.const true));
  assert (result.full_window && result.two_slot_retirement && result.packet_isolation);
  assert (result.consumed > 1000)
;;

let%test_unit "two-beat combined collectors consume 0..15 without crossing packets" =
  Quickcheck.test
    ~trials:6
    ~seed:(`Deterministic "phase6-aligner-wide-consumes")
    ~sexp_of:[%sexp_of: int]
    ~shrinker:Int.quickcheck_shrinker
    (Int.gen_incl 1 100000)
    ~f:(fun seed -> assert_coverage ~max_consume:15 (run ~seed ~max_consume:15 ()))
;;

let%test_unit "all offsets, consume counts, two-slot retirement and packet isolation" =
  assert_coverage (run ())
;;

let%test_unit "independent accepted-byte queue under reproducible traffic" =
  Quickcheck.test
    ~trials:6
    ~seed:(`Deterministic "byte-aligner-schedules")
    ~sexp_of:[%sexp_of: int]
    ~shrinker:Int.quickcheck_shrinker
    (Int.gen_incl 1 100000)
    ~f:(fun seed -> assert_coverage (run ~seed ()))
;;

let%test_unit "excessive consume is rejected, zero holds state, final consume retires" =
  List.iter (run_limits ()) ~f:(fun o ->
    [%test_result: int] o.available ~expect:3;
    [%test_result: int] o.offset ~expect:0;
    [%test_result: bool] o.ready ~expect:(o.request <= 3);
    (* Literal 128-bit abc, independent of driver packing or RTL extraction. *)
    [%test_result: string]
      o.data
      ~expect:(String.make 104 '0' ^ "011000110110001001100001");
    [%test_result: int] o.after_available ~expect:(if o.request = 3 then 0 else 3);
    [%test_result: bool] o.after_valid ~expect:(o.request <> 3))
;;
