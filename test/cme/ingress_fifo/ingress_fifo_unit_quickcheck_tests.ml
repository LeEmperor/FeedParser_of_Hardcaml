(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "ingress_fifo_unit_quickcheck_tests.ml" *)
(* Unit and reproducible generated transport properties, consuming plain observations. *)

open! Core
open Ingress_fifo_testbench

(* A push and a pop in the same cycle need a slot that is already free, so a one-deep FIFO
   manages it only under greedy admission. Both modes are exercised so that the depth-1
   difference is covered as the configuration it is, rather than asserted as a missing
   capability. See docs/retargeting.md. *)
let%test_unit "exact capacity, non-greedy admission, wrap, pauses and reset cancellation" =
  List.iter [ 1; 2; 3; 64 ] ~f:(fun depth ->
    let result = run depth in
    assert (result.outputs > 1000);
    assert (result.full > 0);
    if depth > 1
    then assert (result.simultaneous > 0)
    else assert (result.simultaneous = 0))
;;

let%test_unit "greedy admission restores full-rate replacement at every depth" =
  List.iter [ 1; 2; 3; 64 ] ~f:(fun depth ->
    let result = run ~greedy_admission:true depth in
    assert (result.outputs > 1000);
    assert (result.full > 0);
    assert (result.simultaneous > 0))
;;

(* Depth 2, not 1: the default non-greedy admission cannot refill the slot it drains, so a
   one-deep elastic FIFO admits on alternate cycles and has no full-rate pass-through. Its
   sustained rate is carried by depth - 1 slots. Depth 1 is covered under greedy admission
   below. See docs/phase6_notes.md. *)
let%test_unit "continuous input and output after startup" =
  List.iter [ 2; 3; 64 ] ~f:(fun depth ->
    let result = run ~continuous:true ~resets:false depth in
    [%test_result: int] result.outputs ~expect:result.inputs;
    assert (result.outputs > 1000))
;;

let%test_unit "continuous input and output at depth 1 under greedy admission" =
  List.iter [ 1; 2; 64 ] ~f:(fun depth ->
    let result = run ~continuous:true ~resets:false ~greedy_admission:true depth in
    [%test_result: int] result.outputs ~expect:result.inputs;
    assert (result.outputs > 1000))
;;

let%test_unit "literal lane order and partial final keep" =
  let result = run_literal () in
  [%test_result: (int64 * int * bool * bool * int64) list]
    (List.map result.received ~f:(fun b -> b.data, b.keep, b.first, b.last, b.timestamp))
    ~expect:
      [ Int64.of_string "0xfedcba9876543210", 255, true, true, 0L
      ; Int64.of_string "0xa5a5a5a5a5636261", 7, true, true, 0L
      ]
;;

let%test_unit "generated packet bytes survive bubbles and backpressure" =
  Quickcheck.test
    ~trials:20
    ~seed:(`Deterministic "ingress_fifo-packets")
    ~sexp_of:[%sexp_of: string list]
    ~shrinker:(List.quickcheck_shrinker String.quickcheck_shrinker)
    ~shrink_attempts:(`Limit 50)
    (Quickcheck.Generator.list_with_length
       5
       (Quickcheck.Generator.map
          (Quickcheck.Generator.list_with_length 33 Char.quickcheck_generator)
          ~f:String.of_char_list))
    ~f:(fun payloads ->
      (* Empty payloads have no wire representation; filter them after shrinking. *)
      let payloads = List.filter payloads ~f:(fun s -> not (String.is_empty s)) in
      let result = run ~payloads ~resets:false 3 in
      let actual =
        List.concat_map result.received ~f:(fun b ->
          List.init (Int.popcount b.keep) ~f:(fun lane ->
            Int64.to_int_trunc
              (Int64.bit_and (Int64.shift_right_logical b.data (8 * lane)) 255L)
            |> Char.of_int_exn))
        |> String.of_char_list
      in
      [%test_result: string] actual ~expect:(String.concat payloads))
;;
