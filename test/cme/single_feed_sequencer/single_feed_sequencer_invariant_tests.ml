(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "single_feed_sequencer_invariant_tests.ml" *)
(* Control fencing, silent drop, one-diagnostic-per-gap, and the signed reading of an
   unsigned sequence difference.

   The sequencer has no behavioural suite of its own; its observable output is checked
   against a software model one level up, in packet_pipeline. What that scoreboard cannot
   see are the four internal rules the module is actually built on, each of which fails
   quietly rather than loudly:

   [control] is the fence. Both [valid] and [ready] carry [~:control], so a session reset
   or resync can never land on the same cycle as a transfer. Dropping either term would
   pass every packet_pipeline scenario that does not happen to pulse a control on a
   transfer cycle, and would silently eat one item when it did.

   [dropping] is the silent-swallow state: [valid] must be low so the late or duplicate
   body never reaches the sink, and [ready] must be high so it drains rather than wedging
   the header stage behind it. Those two are separate terms in separate expressions and
   nothing structural keeps them opposed.

   [gap_sent] exists so a gap emits exactly one diagnostic. It gates [fault], and it is
   cleared only by [admit] - not by [control], which [idle] already forbids while it is
   set. The one-per-window property is a statement about a three-signal cycle through the
   flop and is asserted directly.

   [late] is [msb (packet_seq -: expected)]: a thirty-two bit unsigned difference read as
   signed. Gap and duplicate are the same subtraction distinguished only by that bit, so
   the classification flips at a delta of exactly 2^31 and must still be right when the
   sequence wraps through zero. packet_pipeline's suite reaches the wrap at zero and never
   the half-space boundary, so the bound is modelled here in unbounded integers instead.

   Coverage is asserted too: every invariant above is vacuously true on a stimulus that
   only ever sees in-order packets, so the suite fails unless the run reached a gap, a
   late packet, a drained drop, a control at idle, a control request refused while busy, a
   wrapped delta, and a delta at the half-space boundary.

   Tags: [{ "ACTIVE" ; "TEST" ; "INVARIANT" ; "SINGLE_FEED_SEQUENCER" }]
*)

open! Core
open! Hardcaml
open Cme_of_hardcaml
module T = Cme_types
module Sim = Cyclesim.With_interface (Single_feed_sequencer.I) (Single_feed_sequencer.O)

(* All plain [--] names on the sequencer's own nodes, so they survive flattening
   unmangled. Declaration order follows single_feed_sequencer.ml. *)
let traced =
  [ "active"
  ; "initialized"
  ; "expected"
  ; "channel_valid"
  ; "dropping"
  ; "gap_sent"
  ; "open_packet"
  ; "idle"
  ; "control_ready"
  ; "session_reset"
  ; "resync"
  ; "control"
  ; "start"
  ; "diagnostic"
  ; "last"
  ; "delta"
  ; "late"
  ; "fault"
  ; "emit_fault"
  ; "valid"
  ; "ready"
  ; "input_transfer"
  ; "fault_transfer"
  ; "admit"
  ]
;;

let create_sim () =
  let scope = Scope.create ~flatten_design:true () in
  let config =
    { Cyclesim.Config.default with
      is_internal_port =
        Some
          (fun s ->
            List.exists (Signal.names s) ~f:(fun n ->
              List.mem traced n ~equal:String.equal))
    }
  in
  Sim.create ~config (Single_feed_sequencer.create scope)
;;

let probes sim =
  List.map traced ~f:(fun name ->
    match Cyclesim.lookup_node_or_reg_by_name sim name with
    | Some n -> name, n
    | None ->
      let seen =
        (Cyclesim.traced sim).internal_signals
        |> List.concat_map ~f:(fun (s : Cyclesim.Traced.internal_signal) ->
          s.mangled_names)
      in
      raise_s
        [%message
          "probe is not traced; did the -- name change?"
            (name : string)
            (seen : string list)])
  |> String.Map.of_alist_exn
;;

let v p name = Bits.to_int_trunc (Cyclesim.Node.to_bits (Map.find_exn p name))
let b p name = v p name = 1

(* ------------------------------------------------------------------ *)
(* stimulus *)
(* ------------------------------------------------------------------ *)

(* One Packet_item as packet_header emits them: a start owning the context and the first
   body beat, then bodies for the rest, then optionally a sideband diagnostic. *)
type item =
  | Start of
      { seq : int
      ; body_empty : bool
      ; last : bool
      }
  | Body of { last : bool }
  | Diag

let pack = function
  | Start { seq; body_empty; last } ->
    T.Packet_item.Of_bits.pack
      { (T.Packet_item.Of_bits.zero ()) with
        kind = Bits.of_int_trunc ~width:T.Packet_item_kind.width T.Packet_item_kind.start
      ; context =
          { (T.Packet_context.Of_bits.zero ()) with
            packet_seq = Bits.of_int_trunc ~width:32 seq
          ; packet_header_present = Bits.vdd
          ; channel_valid = Bits.vdd
          }
      ; body_empty = Bits.of_bool body_empty
      ; beat =
          { (T.Beat.Of_bits.zero ()) with
            keep = Bits.of_int_trunc ~width:8 0xff
          ; first = Bits.vdd
          ; last = Bits.of_bool last
          }
      }
  | Body { last } ->
    T.Packet_item.Of_bits.pack
      { (T.Packet_item.Of_bits.zero ()) with
        kind = Bits.of_int_trunc ~width:T.Packet_item_kind.width T.Packet_item_kind.body
      ; beat =
          { (T.Beat.Of_bits.zero ()) with
            keep = Bits.of_int_trunc ~width:8 0xff
          ; last = Bits.of_bool last
          }
      }
  | Diag ->
    T.Packet_item.Of_bits.pack
      { (T.Packet_item.Of_bits.zero ()) with
        kind =
          Bits.of_int_trunc ~width:T.Packet_item_kind.width T.Packet_item_kind.diagnostic
      ; diagnostic =
          { (T.Event.Of_bits.zero ()) with
            kind = Bits.of_int_trunc ~width:T.Event_kind.width T.Event_kind.diagnostic
          ; diagnostic_code =
              Bits.of_int_trunc
                ~width:T.Diagnostic_code.width
                T.Diagnostic_code.truncated_packet_header
          }
      }
;;

let mask32 n = n land 0xffff_ffff
let bool_with random ~p = Float.( < ) (Splittable_random.float random ~lo:0. ~hi:1.) p

(* Sequence numbers are shaped off the sequencer's own [expected], so the interesting
   deltas are hit on purpose rather than waited for. The half-space arms straddle 2^31
   exactly, where [late] flips; the wrap arms cross zero. *)
let seq_for ~random ~expected =
  match Splittable_random.int random ~lo:0 ~hi:99 with
  | n when n < 55 -> expected
  | n when n < 65 -> mask32 (expected + Splittable_random.int random ~lo:2 ~hi:10)
  | n when n < 75 -> mask32 (expected - 1)
  | n when n < 82 -> mask32 (expected - Splittable_random.int random ~lo:2 ~hi:20)
  | n when n < 88 -> mask32 (expected + 0x7fff_ffff)
  | n when n < 94 -> mask32 (expected + 0x8000_0000)
  | _ -> mask32 (expected + 0x8000_0001)
;;

let packet ~random ~expected =
  let seq = seq_for ~random ~expected in
  let beats = Splittable_random.int random ~lo:0 ~hi:4 in
  let items =
    if beats = 0
    then [ Start { seq; body_empty = true; last = true } ]
    else
      Start { seq; body_empty = false; last = beats = 1 }
      :: List.init (beats - 1) ~f:(fun k -> Body { last = k = beats - 2 })
  in
  if bool_with random ~p:0.15 then items @ [ Diag ] else items
;;

(* ------------------------------------------------------------------ *)
(* observations *)
(* ------------------------------------------------------------------ *)

module Coverage = struct
  type t =
    { mutable admits : int
    ; mutable gap_faults : int (* fault_transfer with ~late: a gap diagnostic *)
    ; mutable late_faults : int (* fault_transfer with late: enters dropping *)
    ; mutable drop_cycles : int
    ; mutable session_resets : int
    ; mutable resyncs : int
    ; mutable refused_requests : int
        (* control asked for while not idle or not quiescent *)
    ; mutable wrapped_deltas : int (* forward delta whose addition crossed 2^32 *)
    ; mutable boundary_deltas : int (* delta within one of the 2^31 half-space edge *)
    ; mutable first_admits : int (* admit while ~initialized *)
    }

  let create () =
    { admits = 0
    ; gap_faults = 0
    ; late_faults = 0
    ; drop_cycles = 0
    ; session_resets = 0
    ; resyncs = 0
    ; refused_requests = 0
    ; wrapped_deltas = 0
    ; boundary_deltas = 0
    ; first_admits = 0
    }
  ;;
end

(* [gaps_since_admit] carries the one-per-window rule across cycles; everything else in
   the check is combinational within the cycle. *)
type state = { mutable gaps_since_admit : int }

(* Called between cycle_before_clock_edge and cycle_at_clock_edge, so every value here is
   exactly what the flops are about to sample. *)
let check
  ~cycle
  ~(cov : Coverage.t)
  ~(st : state)
  ~(o : Bits.t ref Single_feed_sequencer.O.t)
  ~packet_seq
  p
  =
  let active = b p "active"
  and control = b p "control"
  and control_ready = b p "control_ready"
  and idle = b p "idle"
  and dropping = b p "dropping"
  and gap_sent = b p "gap_sent"
  and open_packet = b p "open_packet"
  and valid = b p "valid"
  and ready = b p "ready"
  and emit_fault = b p "emit_fault"
  and admit = b p "admit"
  and fault_transfer = b p "fault_transfer"
  and initialized = b p "initialized"
  and start = b p "start"
  and late = b p "late"
  and delta = v p "delta"
  and expected = v p "expected" in
  let fail message =
    raise_s
      [%message
        message
          (cycle : int)
          (active : bool)
          (control : bool)
          (idle : bool)
          (dropping : bool)
          (gap_sent : bool)
          (open_packet : bool)
          (valid : bool)
          (ready : bool)
          (emit_fault : bool)
          (late : bool)
          (delta : int)
          (expected : int)
          (packet_seq : int)]
  in
  if active
  then (
    (* 1. Controls are fenced: no transfer may share a cycle with a reset or resync. *)
    if control && (valid || ready)
    then fail "a control cycle is also a transfer cycle; the ~:control fence is gone";
    (* A control only ever fires from a standstill, which is what lets gap_sent survive
       it: control_ready already demands idle, and idle demands all three flags clear. *)
    if control && (dropping || gap_sent || open_packet)
    then fail "a control fired while work was still in flight";
    if control_ready && not idle then fail "control_ready is set outside idle";
    if idle && (dropping || gap_sent || open_packet)
    then fail "idle disagrees with the three state flags it is built from";
    (* 2. Dropping is silent and unblocking. *)
    if dropping && not control
    then (
      if valid then fail "dropping is emitting; a dropped body reached the sink";
      if not ready then fail "dropping is not draining; the header stage will wedge");
    (* The faulting start is held, not consumed: the diagnostic takes this cycle and the
       admit takes the next one. *)
    if emit_fault && ready
    then fail "emit_fault consumed its start; the diagnostic replaces the item this cycle";
    if admit && emit_fault then fail "admit and emit_fault fired together";
    (* 3. One diagnostic per gap. *)
    if fault_transfer && not late
    then (
      st.gaps_since_admit <- st.gaps_since_admit + 1;
      if st.gaps_since_admit > 1
      then fail "a second gap diagnostic issued before the admit that clears gap_sent");
    if admit then st.gaps_since_admit <- 0;
    (* 4. [late] is the sign of the unsigned difference, modelled from the spec in
       unbounded integers rather than reused from the RTL. *)
    if start
    then (
      (* [packet_seq] is read off the driven item, not off any node in the cone that
         produced [delta], so the two sides of this comparison are independent. *)
      let modelled = mask32 (packet_seq - expected) in
      if delta <> modelled
      then fail "delta is not the thirty-two bit difference packet_seq - expected";
      if Bool.( <> ) late (modelled >= 0x8000_0000)
      then fail "late is not the sign the unsigned difference should be read with";
      if modelled > 0 && modelled < 0x8000_0000 && expected + modelled > 0xffff_ffff
      then cov.wrapped_deltas <- cov.wrapped_deltas + 1;
      if abs (modelled - 0x8000_0000) <= 1
      then cov.boundary_deltas <- cov.boundary_deltas + 1);
    (* 5. The first packet of a session is admitted valid whatever its sequence number. *)
    if admit && not initialized
    then (
      cov.first_admits <- cov.first_admits + 1;
      let emitted = T.Packet_item.Of_bits.unpack !(o.item_o) in
      if not (Bits.to_bool emitted.context.channel_valid)
      then fail "the first admitted packet of a session is not marked channel_valid");
    if admit then cov.admits <- cov.admits + 1;
    if fault_transfer
    then
      if late
      then cov.late_faults <- cov.late_faults + 1
      else cov.gap_faults <- cov.gap_faults + 1;
    if dropping then cov.drop_cycles <- cov.drop_cycles + 1;
    if b p "session_reset" then cov.session_resets <- cov.session_resets + 1;
    if b p "resync" then cov.resyncs <- cov.resyncs + 1)
;;

(* ------------------------------------------------------------------ *)
(* driver *)
(* ------------------------------------------------------------------ *)

let run ~seed ~cycles =
  let sim = create_sim () in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs ~clock_edge:Before sim in
  let p = probes sim in
  let cov = Coverage.create () in
  let st = { gaps_since_admit = 0 } in
  let random = Splittable_random.of_int seed in
  let pending = ref [] in
  (* Idle cycles between packets. Without them the driver always has an item in hand,
     [quiescent_i] never rises, and no control ever fires - the coverage assertion below
     exists because that is silent otherwise. *)
  let gap = ref 0 in
  i.reset_i := Bits.vdd;
  i.en_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  for cycle = 1 to cycles do
    if List.is_empty !pending
    then
      if !gap > 0
      then decr gap
      else if bool_with random ~p:0.25
      then gap := Splittable_random.int random ~lo:1 ~hi:6
      else pending := packet ~random ~expected:(v p "expected");
    (match !pending with
     | it :: _ ->
       i.item_i := pack it;
       i.valid_i := Bits.vdd
     | [] -> i.valid_i := Bits.gnd);
    (* [quiescent_i] is a whole-pipeline claim in packet_pipeline, assembled there from
       the fifo, the header stage and everything downstream. The honest unit-level
       stand-in is "this driver has nothing left to hand over". *)
    i.quiescent_i := Bits.of_bool (List.is_empty !pending);
    i.ready_i := Bits.of_bool (bool_with random ~p:0.8);
    i.en_i := Bits.of_bool (bool_with random ~p:0.95);
    (* Requests are pulsed without regard for idle, so the path where one is refused and
       simply dropped - rather than latched - is exercised on purpose. *)
    let session_reset = bool_with random ~p:0.02 in
    let resync = bool_with random ~p:0.03 in
    i.session_reset_i := Bits.of_bool session_reset;
    i.resync_valid_i := Bits.of_bool resync;
    i.resync_next_seq_i
    := Bits.of_int_trunc
         ~width:32
         (match Splittable_random.int random ~lo:0 ~hi:2 with
          | 0 -> 0xffff_fffd
          | 1 -> 0x7fff_fffe
          | _ -> Splittable_random.int random ~lo:0 ~hi:0xffff);
    let hard_reset = bool_with random ~p:0.005 in
    if hard_reset
    then (
      i.reset_i := Bits.vdd;
      pending := [];
      gap := 0);
    Cyclesim.cycle_check sim;
    Cyclesim.cycle_before_clock_edge sim;
    let control = b p "control"
    and control_ready = b p "control_ready"
    and admit = b p "admit"
    and active = b p "active"
    and consumed = b p "input_transfer" in
    let expected_before = v p "expected" in
    let packet_seq =
      Bits.to_int_trunc (T.Packet_item.Of_bits.unpack !(i.item_i)).context.packet_seq
    in
    if not hard_reset then check ~cycle ~cov ~st ~o ~packet_seq p;
    if (session_reset || resync) && not control_ready
    then cov.refused_requests <- cov.refused_requests + 1;
    Cyclesim.cycle_at_clock_edge sim;
    Cyclesim.cycle_after_clock_edge sim;
    (* Register discipline: nothing but a control or an admit may move [expected]. A
       refused request that quietly latched would show up right here. *)
    if active && (not hard_reset) && (not control) && not admit
    then (
      let expected_after = v p "expected" in
      if expected_after <> expected_before
      then
        raise_s
          [%message
            "expected moved without a control or an admit"
              (cycle : int)
              (expected_before : int)
              (expected_after : int)]);
    if consumed then pending := List.tl_exn !pending;
    i.reset_i := Bits.gnd
  done;
  cov
;;

let%test_unit "control fencing, silent drop, one gap per window, and the sign of delta" =
  let cov = run ~seed:0x5eed ~cycles:6000 in
  if cov.admits < 200
     || cov.gap_faults = 0
     || cov.late_faults = 0
     || cov.drop_cycles = 0
     || cov.session_resets = 0
     || cov.resyncs = 0
     || cov.refused_requests = 0
     || cov.wrapped_deltas = 0
     || cov.boundary_deltas = 0
     || cov.first_admits = 0
  then
    raise_s
      [%message
        "stimulus did not reach every arm the invariants guard"
          ~admits:(cov.admits : int)
          ~gap_faults:(cov.gap_faults : int)
          ~late_faults:(cov.late_faults : int)
          ~drop_cycles:(cov.drop_cycles : int)
          ~session_resets:(cov.session_resets : int)
          ~resyncs:(cov.resyncs : int)
          ~refused_requests:(cov.refused_requests : int)
          ~wrapped_deltas:(cov.wrapped_deltas : int)
          ~boundary_deltas:(cov.boundary_deltas : int)
          ~first_admits:(cov.first_admits : int)]
;;

let%test_unit "invariants hold across a spread of seeds" =
  List.iter [ 1; 7; 13; 101; 9001 ] ~f:(fun seed ->
    ignore (run ~seed ~cycles:2000 : Coverage.t))
;;
