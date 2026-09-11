(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "packet_pipeline_expect_tests.ml" *)
(* Small reviewed canonical ordering trace using the shared scoreboard. *)

open! Core
open Packet_pipeline_testbench

let%expect_test "gap before admitted start; duplicate and truncation before next packet" =
  let o =
    run
      ~stalls:false
      [ packet ~timestamp:1L ~sending_time:2L 10L "abcd"
      ; packet ~timestamp:3L ~sending_time:4L 12L "efgh"
      ; packet ~timestamp:5L ~sending_time:6L 12L "discard"
      ; short 3
      ; packet ~timestamp:7L ~sending_time:8L 13L ""
      ]
  in
  print_s [%sexp (o.items : Item.t list)];
  [%expect
    {|
    ((Start
      ((timestamp 1) (seq 10) (sending_time 2) (header_present true)
       (channel_valid true))
      abcd true)
     (Diagnostic
      ((timestamp 3) (seq 12) (sending_time 4) (header_present true)
       (channel_valid false))
      1 (11) 0)
     (Start
      ((timestamp 3) (seq 12) (sending_time 4) (header_present true)
       (channel_valid false))
      efgh true)
     (Diagnostic
      ((timestamp 5) (seq 12) (sending_time 6) (header_present true)
       (channel_valid false))
      2 (13) 0)
     (Diagnostic
      ((timestamp 3) (seq 0) (sending_time 0) (header_present false)
       (channel_valid false))
      3 () 3)
     (Start
      ((timestamp 7) (seq 13) (sending_time 8) (header_present true)
       (channel_valid false))
      "" true))
    |}]
;;
