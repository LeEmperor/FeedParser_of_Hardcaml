(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "message_pipeline_expect_tests.ml" *)
(* Compact ordered recovery trace from the shared Step scoreboard. *)

open! Core
open Message_pipeline_testbench

let%expect_test "skip and truncation preserve the next packet" =
  let o =
    run
      ~stalls:false
      [ packet 1L (message ~template:99 "skip" ^ message "ok" ^ message ~size:80 "short")
      ; packet 2L (message "next")
      ]
  in
  List.iter o.items ~f:(function
    | Message (c, h, body) ->
      print_s [%sexp (("message", c.seq, h.offset, body) : string * int64 * int * string)]
    | Diagnostic (c, h, code, _, offset) ->
      print_s
        [%sexp
          (("diagnostic", c.seq, h.offset, code, offset)
           : string * int64 * int * int * int)]);
  [%expect
    {|
    (diagnostic 1 12 6 16)
    (message 1 26 ok)
    (diagnostic 1 38 5 53)
    (message 2 12 next)
    |}]
;;
