(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "event_fifo_unit_quickcheck_tests.ml" *)
(* Complete event-word scoreboard, capacities including non-powers of two. The readiness
   equality lives in the testbench; these assertions are the coverage that keeps it from
   passing vacuously. *)

open! Core
open! Hardcaml
open! Cme_of_hardcaml
open Event_fifo_testbench

(* A push and a pop in the same cycle need a slot that is already free, so a depth-1 FIFO
   manages it only through the fallthrough bypass or under greedy admission. Every
   combination is exercised, so the depth-1 difference is covered as the configuration it
   is rather than asserted as a missing capability. See docs/retargeting.md. *)
let assert_coverage
  ?(fallthrough = false)
  ?(greedy_admission = false)
  ~depth
  (result : Observation.t)
  =
  assert (result.full > 0 && result.outputs > 1000);
  assert (result.blocked_at_full > 0);
  if depth > 1 || fallthrough || greedy_admission
  then assert (result.simultaneous > 0)
  else assert (result.simultaneous = 0)
;;

let%test_unit "fallthrough preserves capacity, held events, reset and non-greedy \
               admission"
  =
  List.iter [ 1; 3; 16 ] ~f:(fun depth ->
    assert_coverage ~fallthrough:true ~depth (run ~fallthrough:true depth))
;;

let%test_unit "depths 1, 2, 3 and 16: capacity, ordering, pause, reset and drain" =
  List.iter [ 1; 2; 3; 16 ] ~f:(fun depth -> assert_coverage ~depth (run depth))
;;

(* Greedy admission is the pre-existing contract kept as a configuration: readiness also
   accepts while full whenever the FIFO drains in the same cycle, so full-rate replacement
   is available at every depth including 1. *)
let%test_unit "greedy admission restores full-rate replacement at every depth" =
  List.iter [ 1; 2; 3; 16 ] ~f:(fun depth ->
    assert_coverage ~greedy_admission:true ~depth (run ~greedy_admission:true depth))
;;

let%test_unit "greedy admission composes with the fallthrough bypass" =
  List.iter [ 1; 3 ] ~f:(fun depth ->
    assert_coverage
      ~fallthrough:true
      ~greedy_admission:true
      ~depth
      (run ~fallthrough:true ~greedy_admission:true depth))
;;

let%test_unit "reproducible event patterns and traffic schedules" =
  Quickcheck.test
    ~trials:6
    ~seed:(`Deterministic "event-fifo-schedules")
    ~sexp_of:[%sexp_of: int]
    ~shrinker:Int.quickcheck_shrinker
    (Int.gen_incl 1 100000)
    ~f:(fun seed -> assert_coverage ~depth:3 (run ~seed 3))
;;

(* The structural half of the same rule, as for the aligner: input readiness must not be
   reachable from the downstream ready without crossing a register. Deps_for_loop_checking
   cuts at registers, so this cone is exactly the combinational logic behind
   event_ready_o. *)
let%test_unit "event_ready_o has no combinational path from event_ready_i" =
  List.iter [ 1; 3; 16 ] ~f:(fun depth ->
    let module C = Circuit.With_interface (Event_fifo.I) (Event_fifo.O) in
    let circuit =
      C.create_exn
        ~name:"cme_event_fifo"
        (Event_fifo.create ~depth (Scope.create ~flatten_design:true ()))
    in
    let named signal name = List.mem (Signal.names signal) name ~equal:String.equal in
    let ready =
      List.find_exn (Circuit.outputs circuit) ~f:(fun s -> named s "event_ready_o")
    in
    let reached =
      Signal_graph.filter
        ~deps:(module Signal_graph.Deps_for_loop_checking)
        (Signal_graph.create [ ready ])
        ~f:(fun s -> named s "event_ready_i")
    in
    if not (List.is_empty reached)
    then
      raise_s
        [%message
          "event_ready_o depends on this cycle's pop; admission must read the full flag \
           alone"
            (depth : int)
            (reached : Signal.t list)])
;;

let%test_unit "literal before/after-edge replacement, pause and reset" =
  let observations = run_literal () in
  let find phase = List.find_exn observations ~f:(fun o -> String.equal o.phase phase) in
  let stalled = find "stall" in
  assert (stalled.before.valid && not stalled.before.ready);
  [%test_result: int] stalled.before.low_byte ~expect:0x81;
  assert stalled.before.high_bit;
  let paused = find "pause" in
  assert ((not paused.before.valid) && not paused.before.ready);
  [%test_result: int] paused.after.low_byte ~expect:0x81;
  (* A full slot draining does not admit in the same cycle, and the held event stays put
     for that cycle; the replacement lands the cycle after. *)
  let drained = find "drain_only" in
  assert (drained.before.valid && not drained.before.ready);
  [%test_result: int] drained.before.low_byte ~expect:0x81;
  [%test_result: int] drained.after.low_byte ~expect:0x81;
  let accepted = find "accept" in
  assert (accepted.before.ready && not accepted.before.valid);
  [%test_result: int] accepted.after.low_byte ~expect:0x32;
  assert accepted.after.high_bit;
  assert (not (find "drain").after.valid);
  assert (not (find "reset_disabled").after.valid);
  assert (not (find "resume_empty").before.valid)
;;
