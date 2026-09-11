(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "validation_core_unit_quickcheck_tests.ml" *)
(* Destination-port selection and counter wiring over the composed board datapath. *)

open! Core
open Validation_core_testbench

let%test_unit "a selected packet is parsed and counted" =
  let result = run [ selected (simple 1L) ] in
  [%test_result: int] result.packets ~expect:1;
  [%test_result: int] result.updates ~expect:1;
  [%test_result: int] result.end_of_event ~expect:1;
  [%test_result: int] result.diagnostics ~expect:0
;;

(* The board claim under test: unrelated host traffic on the validation link drains
   without reaching the parser, so it can neither be counted nor break sequencing. *)
let%test_unit "filtered ports never reach the parser or its sequence state" =
  let mixed =
    [ selected (simple 1L)
    ; filtered (simple 900L)
    ; filtered ~port:0 (simple 901L)
    ; selected (simple 2L)
    ; filtered ~port:65535 (simple 902L)
    ; selected (simple 3L)
    ]
  in
  let result = run mixed in
  [%test_result: int] result.packets ~expect:3;
  [%test_result: int] result.updates ~expect:3;
  [%test_result: int] result.sequence_gaps ~expect:0;
  [%test_result: int] result.duplicates ~expect:0;
  [%test_result: int] result.diagnostics ~expect:0;
  (* Non-vacuity: filtered traffic really was offered and really was drained. *)
  [%test_pred: int] (fun n -> n > 0) result.filtered_beats;
  [%test_pred: int] (fun n -> n > 0) result.filtered_while_parser_busy
;;

let%test_unit "a gap in selected sequence numbers raises exactly one diagnostic" =
  let result = run [ selected (simple 1L); selected (simple 3L) ] in
  [%test_result: int] result.packets ~expect:2;
  [%test_result: int] result.sequence_gaps ~expect:1;
  [%test_result: int] result.duplicates ~expect:0
;;

let%test_unit "a repeated sequence number counts as a duplicate" =
  let result = run [ selected (simple 1L); selected (simple 1L) ] in
  [%test_result: int] result.packets ~expect:2;
  [%test_result: int] result.duplicates ~expect:1
;;

(* Filtered packets carry sequence numbers that would look like gaps if they leaked, so an
   identical selected stream must count identically with or without them interleaved. *)
let%test_unit "interleaved filtered traffic does not perturb any counter" =
  let selected_only =
    [ selected (simple 1L); selected (simple 2L); selected (simple 3L) ]
  in
  let interleaved =
    [ filtered (simple 500L)
    ; selected (simple 1L)
    ; filtered (simple 501L)
    ; selected (simple 2L)
    ; filtered (simple 502L)
    ; selected (simple 3L)
    ; filtered (simple 503L)
    ]
  in
  let strip (o : Observation.t) =
    { o with filtered_beats = 0; filtered_while_parser_busy = 0 }
  in
  [%test_result: Observation.t]
    (strip (run interleaved))
    ~expect:(strip (run selected_only))
;;

let%test_unit "counters are stable across seeded stall schedules" =
  let stream = [ selected (simple 1L); filtered (simple 700L); selected (simple 2L) ] in
  let strip (o : Observation.t) =
    { o with filtered_beats = 0; filtered_while_parser_busy = 0 }
  in
  let reference = strip (run ~seed:1 stream) in
  List.iter [ 2; 3; 5; 8 ] ~f:(fun seed ->
    [%test_result: Observation.t] (strip (run ~seed stream)) ~expect:reference)
;;
