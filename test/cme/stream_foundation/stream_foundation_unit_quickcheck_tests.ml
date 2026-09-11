(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "stream_foundation_unit_quickcheck_tests.ml" *)
(* Unit and reproducible generated transport properties, consuming plain observations. *)

open! Core
open Stream_foundation_testbench

let%test_unit "exact capacity, replacement, wrap, pauses and reset cancellation" =
  List.iter [ 1; 2; 3; 64 ] ~f:(fun depth ->
    let result = run depth in
    assert (result.outputs > 1000 && result.simultaneous > 0);
    ())
;;

let%test_unit "continuous input and output after startup" =
  List.iter [ 1; 3; 64 ] ~f:(fun depth ->
    let result = run ~continuous:true ~resets:false depth in
    [%test_result: int] result.outputs ~expect:result.inputs;
    assert (result.outputs > 1000))
;;

let%test_unit "literal lane order and partial final keep" =
  let result = run_literal () in
  [%test_result: (int64 * int * bool * bool * int64) list]
    (List.map result.received ~f:(fun b -> b.data, b.keep, b.first, b.last, b.timestamp))
    ~expect:
      [ Int64.of_string "0xfedcba9876543210", 255, true, true, 0L
      ; Int64.of_string "0x636261", 7, true, true, 0L
      ]
;;

let%test_unit "generated packet bytes survive bubbles and backpressure" =
  Quickcheck.test
    ~trials:20
    ~seed:(`Deterministic "stream_foundation-packets")
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

let%test_unit "Arty shim gaps and zero timestamp" =
  let result = run ~shim_gaps:true 3 in
  assert (result.outputs > 1000);
  List.iter result.received ~f:(fun b -> [%test_result: int64] b.timestamp ~expect:0L)
;;
