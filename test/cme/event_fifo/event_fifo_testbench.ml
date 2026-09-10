(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "event_fifo_testbench.ml" *)
(* Step transfers sampled before the edge, disable-hold checked after the edge. A software
   queue monitors complete packed events, with bounded draining.

   Admission is a configuration. Non-greedy (the default) refuses the input even in a
   cycle the FIFO is draining, so the model's readiness is `occupancy < depth` and nothing
   more; greedy also accepts in that cycle. blocked_at_full counts the cycles where the
   two rules differ, which is what keeps the readiness check from passing vacuously. *)

open! Core
open! Hardcaml
open! Cme_of_hardcaml
open Hardcaml_verif
open Stream_test_support.Stream_fixture

module Observation = struct
  type t =
    { full : int
    ; simultaneous : int
    ; (* Cycles where the FIFO was full, draining, and being offered an event: exactly
         where greedy and non-greedy admission differ. *)
      blocked_at_full : int
    ; outputs : int
    }
  [@@deriving sexp, equal]
end

let run ?(seed = 1) ?(fallthrough = false) ?(greedy_admission = false) depth =
  let module Dut = struct
    module I = Event_fifo.I
    module O = Event_fifo.O

    let name = "event_fifo"
    let create scope i = Event_fifo.create ~depth ~fallthrough ~greedy_admission scope i
  end
  in
  let module Fixture = Sim_fixture.Make (Dut) in
  let module Step = Fixture.Step in
  let random = Random.State.make [| 0x434d45; seed |] in
  let chance n = Random.State.int random n = 0 in
  let testbench (handler : Step.Handler.t @ local) _ =
    let expected = Queue.create () in
    let pending = ref None in
    let held = ref None in
    let full, simultaneous, outputs = ref 0, ref 0, ref 0 in
    let blocked_at_full = ref 0 in
    for cycle = 0 to 6000 do
      let reset = List.mem [ 0; 200; 700 ] cycle ~equal:Int.equal in
      let enabled = cycle > 5000 || (cycle <> 200 && not (chance 11)) in
      let ready = cycle > 5000 || (cycle > depth + 10 && not (chance 3)) in
      if reset
      then (
        Queue.clear expected;
        pending := None;
        held := None);
      if cycle < 5000 && Option.is_none !pending
      then
        pending
        := Some
             (Bits.concat_lsb
                (List.init Cme_types.Event.width ~f:(fun _ -> Bits.of_bool (chance 2))));
      let edge =
        Step.cycle
          handler
          { clock_i = Bits.gnd
          ; reset_i = Bits.of_bool reset
          ; en_i = Bits.of_bool enabled
          ; event_i = Option.value !pending ~default:(Bits.zero Cme_types.Event.width)
          ; event_valid_i = Bits.of_bool (Option.is_some !pending)
          ; event_ready_i = Bits.of_bool ready
          }
      in
      let o = Step.O_data.before_edge edge in
      let after = Step.O_data.after_edge edge in
      let active = enabled && not reset in
      let valid, input_ready =
        Bits.to_bool o.event_valid_o, Bits.to_bool o.event_ready_o
      in
      check
        (Bool.equal
           valid
           (active
            && ((not (Queue.is_empty expected)) || (fallthrough && Option.is_some !pending)
               )))
        "event FIFO valid";
      (* Capacity is exactly `depth` in both modes; they differ only on whether a drain in
         this cycle makes room in this cycle. *)
      let draining = valid && ready in
      check
        (Bool.equal
           input_ready
           (active && (Queue.length expected < depth || (greedy_admission && draining))))
        "event FIFO exact capacity";
      if Queue.length expected = depth then incr full;
      if active && Queue.length expected = depth && Option.is_some !pending && draining
      then incr blocked_at_full;
      if active
      then (
        Option.iter !held ~f:(fun previous ->
          check (valid && Bits.equal previous o.event_o) "stalled event changed");
        held := if valid && not ready then Some o.event_o else None);
      if input_ready && Option.is_some !pending
      then (
        Queue.enqueue expected (Option.value_exn !pending);
        pending := None;
        if valid && ready then incr simultaneous);
      if valid && ready
      then (
        check
          (Bits.equal (Queue.dequeue_exn expected) o.event_o)
          "event corruption or ordering";
        incr outputs);
      let before = o.event_o in
      if (not active) && not reset
      then check (Bits.equal before after.event_o) "event changed while disabled"
    done;
    check (Queue.is_empty expected && Option.is_none !pending) "events failed to drain";
    { Observation.full = !full
    ; simultaneous = !simultaneous
    ; blocked_at_full = !blocked_at_full
    ; outputs = !outputs
    }
  in
  Fixture.run_with_timeout ~timeout:6010 ~testbench
;;

module Output_snapshot = struct
  type t =
    { ready : bool
    ; valid : bool
    ; low_byte : int
    ; high_bit : bool
    }
  [@@deriving sexp, equal]
end

module Edge_observation = struct
  type t =
    { phase : string
    ; before : Output_snapshot.t
    ; after : Output_snapshot.t
    }
  [@@deriving sexp, equal]
end

let run_literal () =
  let module Dut = struct
    module I = Event_fifo.I
    module O = Event_fifo.O

    let create scope i = Event_fifo.create ~depth:1 scope i
    let name = "event_fifo_literal"
  end
  in
  let module Fixture = Sim_fixture.Make (Dut) in
  let module Step = Fixture.Step in
  let snapshot (o : Bits.t Dut.O.t) : Output_snapshot.t =
    { ready = Bits.to_bool o.event_ready_o
    ; valid = Bits.to_bool o.event_valid_o
    ; low_byte = Bits.to_int_trunc (Bits.sel_bottom o.event_o ~width:8)
    ; high_bit = Bits.to_bool (Bits.bit o.event_o ~pos:(Cme_types.Event.width - 1))
    }
  in
  let testbench (handler : Step.Handler.t @ local) _ =
    let rec loop (handler : Step.Handler.t @ local) = function
      | [] -> []
      | (phase, reset, enabled, valid, ready, value) :: rest ->
        let event =
          Bits.concat_msb [ Bits.vdd; Bits.zero (Cme_types.Event.width - 9); int 8 value ]
        in
        let edge =
          Step.cycle
            handler
            { clock_i = Bits.gnd
            ; reset_i = Bits.of_bool reset
            ; en_i = Bits.of_bool enabled
            ; event_i = event
            ; event_valid_i = Bits.of_bool valid
            ; event_ready_i = Bits.of_bool ready
            }
        in
        let observation : Edge_observation.t =
          { phase
          ; before = snapshot (Step.O_data.before_edge edge)
          ; after = snapshot (Step.O_data.after_edge edge)
          }
        in
        observation :: loop handler rest
    in
    loop
      handler
      (* drain_only and accept are one replacement split across two cycles: non-greedy
         admission refuses the new event while the slot is still occupied, and takes it
         the cycle after the old one leaves. *)
      [ "reset", true, false, false, false, 0
      ; "enqueue", false, true, true, false, 0x81
      ; "stall", false, true, true, false, 0x32
      ; "pause", false, false, true, false, 0x32
      ; "drain_only", false, true, true, true, 0x32
      ; "accept", false, true, true, false, 0x32
      ; "drain", false, true, false, true, 0
      ; "enqueue_again", false, true, true, false, 0xff
      ; "reset_disabled", true, false, false, false, 0
      ; "resume_empty", false, true, false, true, 0
      ]
  in
  Fixture.run_with_timeout ~timeout:15 ~testbench
;;
