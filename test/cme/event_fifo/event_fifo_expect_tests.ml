(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "event_fifo_expect_tests.ml" *)
(* One-entry FIFO: drain-then-accept replacement, enable pause, reset cancellation. *)

open! Core
open Event_fifo_testbench

let%expect_test "one-entry elasticity" =
  List.iter (run_literal ()) ~f:(fun o -> print_s [%sexp (o : Edge_observation.t)]);
  [%expect
    {|
    ((phase reset)
     (before ((ready false) (valid false) (low_byte 0) (high_bit false)))
     (after ((ready false) (valid false) (low_byte 0) (high_bit false))))
    ((phase enqueue)
     (before ((ready true) (valid false) (low_byte 0) (high_bit false)))
     (after ((ready false) (valid true) (low_byte 129) (high_bit true))))
    ((phase stall)
     (before ((ready false) (valid true) (low_byte 129) (high_bit true)))
     (after ((ready false) (valid true) (low_byte 129) (high_bit true))))
    ((phase pause)
     (before ((ready false) (valid false) (low_byte 129) (high_bit true)))
     (after ((ready false) (valid false) (low_byte 129) (high_bit true))))
    ((phase drain_only)
     (before ((ready false) (valid true) (low_byte 129) (high_bit true)))
     (after ((ready true) (valid false) (low_byte 129) (high_bit true))))
    ((phase accept)
     (before ((ready true) (valid false) (low_byte 129) (high_bit true)))
     (after ((ready false) (valid true) (low_byte 50) (high_bit true))))
    ((phase drain)
     (before ((ready false) (valid true) (low_byte 50) (high_bit true)))
     (after ((ready true) (valid false) (low_byte 50) (high_bit true))))
    ((phase enqueue_again)
     (before ((ready true) (valid false) (low_byte 50) (high_bit true)))
     (after ((ready false) (valid true) (low_byte 255) (high_bit true))))
    ((phase reset_disabled)
     (before ((ready false) (valid false) (low_byte 255) (high_bit true)))
     (after ((ready false) (valid false) (low_byte 0) (high_bit false))))
    ((phase resume_empty)
     (before ((ready true) (valid false) (low_byte 0) (high_bit false)))
     (after ((ready true) (valid false) (low_byte 0) (high_bit false))))
    |}]
;;
