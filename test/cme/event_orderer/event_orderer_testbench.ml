(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "event_orderer_testbench.ml" *)
(* Step fixture with a delayed synthetic decoder. Each body token yields an update;
   successful completion adds an end event. Abort discards only incomplete work. *)

open! Core
open! Hardcaml
open! Cme_of_hardcaml
open Hardcaml_verif
module T = Cme_types

module Token = struct
  type t =
    | Start of int * bool
    | Empty of int
    | Body of bool
    | Diagnostic of int * int
  [@@deriving sexp, equal, compare]
end

module Event = struct
  type t =
    { kind : int
    ; seq : int
    ; index : int
    ; code : int
    }
  [@@deriving sexp, equal, compare]
end

module Observation = struct
  type t =
    { events : Event.t list
    ; stalls : int
    ; aborts : int
    ; completions : int
    }
  [@@deriving sexp]
end

let int width n = Bits.of_int_trunc ~width n

let event (e : Event.t) =
  T.Event.Of_bits.pack
    { (T.Event.Of_bits.zero ()) with
      kind = int 2 e.kind
    ; packet = { (T.Packet_context.Of_bits.zero ()) with packet_seq = int 32 e.seq }
    ; entry_index = int 16 e.index
    ; diagnostic_code = int 8 e.code
    }
;;

let update seq index : Event.t = { kind = 0; seq; index; code = 0 }
let ending seq : Event.t = { kind = 1; seq; index = 0; code = 0 }
let diagnostic seq code : Event.t = { kind = 2; seq; index = 0; code }

let encode = function
  | Token.Empty seq ->
    T.Message_item.Of_bits.pack
      { (T.Message_item.Of_bits.zero ()) with
        body_empty = Bits.vdd
      ; packet = { (T.Packet_context.Of_bits.zero ()) with packet_seq = int 32 seq }
      }
  | Token.Diagnostic (seq, code) ->
    T.Message_item.Of_bits.pack
      { (T.Message_item.Of_bits.zero ()) with
        kind = int 2 2
      ; diagnostic = T.Event.Of_bits.unpack (event (diagnostic seq code))
      }
  | (Start (_, last) | Body last) as token ->
    let first, seq =
      match token with
      | Start (seq, _) -> true, seq
      | _ -> false, 0
    in
    T.Message_item.Of_bits.pack
      { (T.Message_item.Of_bits.zero ()) with
        kind = int 2 (if first then 0 else 1)
      ; packet = { (T.Packet_context.Of_bits.zero ()) with packet_seq = int 32 seq }
      ; beat =
          { data = int 64 123
          ; keep = int 8 255
          ; first = Bits.of_bool first
          ; last = Bits.of_bool last
          }
      }
;;

let expected tokens =
  let seq, index = ref 0, ref 0 in
  List.concat_map tokens ~f:(function
    | Token.Empty s -> [ ending s ]
    | Token.Start (s, last) ->
      seq := s;
      index := 1;
      [ update s 0 ] @ if last then [ ending s ] else []
    | Body last ->
      let n = !index in
      incr index;
      [ update !seq n ] @ if last then [ ending !seq ] else []
    | Diagnostic (s, code) -> [ diagnostic s code ])
;;

module Dut = struct
  include Event_orderer

  let name = "event_orderer"
end

module Fixture = Sim_fixture.Make (Dut)
module Step = Fixture.Step

let run ?(seed = 1) ?(stalls = true) ?reset_at ?(sink_block_until = 0) tokens =
  let random = Random.State.make [| seed; 0x534245 |] in
  let chance n = stalls && Random.State.int random n = 0 in
  let testbench (handler : Step.Handler.t @ local) _ =
    let todo = ref tokens in
    let pending = ref None in
    let outputs = Queue.create () in
    let owned = ref None in
    let index = ref 0 in
    let terminal_at = ref None in
    let held_event, held_decoder = ref None, ref None in
    let events, cycles, stall_count, aborts, completions =
      ref [], ref 0, ref 0, ref 0, ref 0
    in
    let finished = ref false in
    while (not !finished) && !cycles < 30000 do
      let reset = !cycles = 0 || Option.equal Int.equal reset_at (Some !cycles) in
      let enabled = (not reset) && not (chance 17) in
      if reset
      then (
        todo := tokens;
        pending := None;
        Queue.clear outputs;
        owned := None;
        index := 0;
        terminal_at := None;
        held_event := None;
        held_decoder := None;
        events := [];
        aborts := 0;
        completions := 0);
      if (not reset) && Option.is_none !pending && not (chance 4)
      then pending := List.hd !todo;
      let offered =
        Option.value_map !pending ~default:(Bits.zero T.message_item_width) ~f:encode
      in
      let output = Queue.peek outputs in
      let decoder_event =
        Option.value_map output ~default:(Bits.zero T.Event.width) ~f:event
      in
      let sink_ready = !cycles >= sink_block_until && not (chance 3) in
      let decoder_ready = not (chance 3) in
      (* Completion may coincide with the last event, but must wait if it stalls. *)
      let done_offer =
        Option.exists !terminal_at ~f:(fun at -> !cycles >= at + 7)
        && Queue.length outputs <= 1
      in
      let edge =
        Step.cycle
          handler
          { clock_i = Bits.gnd
          ; reset_i = Bits.of_bool reset
          ; en_i = Bits.of_bool enabled
          ; item_i = offered
          ; valid_i = Bits.of_bool (Option.is_some !pending)
          ; decoder_ready_i = Bits.of_bool decoder_ready
          ; decoder_event_i = decoder_event
          ; decoder_event_valid_i = Bits.of_bool (Option.is_some output)
          ; decoder_done_i = Bits.of_bool done_offer
          ; event_ready_i = Bits.of_bool sink_ready
          }
      in
      let o = Step.O_data.before_edge edge in
      let ready, valid = Bits.to_bool o.ready_o, Bits.to_bool o.event_valid_o in
      let decoder_valid = Bits.to_bool o.decoder_valid_o in
      if not enabled
      then
        assert (
          (not ready)
          && (not valid)
          && (not decoder_valid)
          && (not (Bits.to_bool o.decoder_event_ready_o))
          && not (Bits.to_bool o.decoder_done_ready_o));
      if not reset
      then (
        Option.iter !held_event ~f:(fun old ->
          assert (Bits.equal old o.event_o);
          if enabled then assert valid);
        Option.iter !held_decoder ~f:(fun old ->
          assert (Bits.equal old o.decoder_item_o);
          if enabled then assert decoder_valid));
      if valid then held_event := if sink_ready then None else Some o.event_o;
      if decoder_valid
      then held_decoder := if decoder_ready then None else Some o.decoder_item_o;
      if valid && not sink_ready then incr stall_count;
      if valid && sink_ready
      then (
        let e = T.Event.Of_bits.unpack o.event_o in
        let observed : Event.t =
          { kind = Bits.to_int_trunc e.kind
          ; seq = Bits.to_int_trunc e.packet.packet_seq
          ; index = Bits.to_int_trunc e.entry_index
          ; code = Bits.to_int_trunc e.diagnostic_code
          }
        in
        assert (Bits.equal o.event_o (event observed));
        events := observed :: !events);
      if Option.is_some output && Bits.to_bool o.decoder_event_ready_o
      then ignore (Queue.dequeue_exn outputs : Event.t);
      if done_offer && Bits.to_bool o.decoder_done_ready_o
      then (
        assert (Queue.is_empty outputs);
        owned := None;
        terminal_at := None;
        incr completions);
      if decoder_valid && decoder_ready
      then (
        assert ready;
        assert (Bits.equal offered o.decoder_item_o);
        match Option.value_exn !pending with
        | Token.Empty seq ->
          assert (Option.is_none !owned);
          owned := Some seq;
          index := 0;
          Queue.enqueue outputs (ending seq);
          terminal_at := Some !cycles
        | Token.Start (seq, last) ->
          assert (Option.is_none !owned);
          owned := Some seq;
          index := 1;
          Queue.enqueue outputs (update seq 0);
          if last
          then (
            Queue.enqueue outputs (ending seq);
            terminal_at := Some !cycles)
        | Body last ->
          let seq = Option.value_exn !owned in
          Queue.enqueue outputs (update seq !index);
          incr index;
          if last
          then (
            Queue.enqueue outputs (ending seq);
            terminal_at := Some !cycles)
        | Diagnostic (_, code) ->
          assert (code = 5 && Option.is_some !owned && Option.is_none !terminal_at);
          terminal_at := Some !cycles;
          incr aborts);
      if Option.is_some !pending && ready
      then (
        todo := List.tl_exn !todo;
        pending := None);
      finished
      := !cycles > 0
         && Option.value_map reset_at ~default:true ~f:(fun at -> !cycles > at)
         && List.is_empty !todo
         && Option.is_none !pending
         && Option.is_none !owned
         && Queue.is_empty outputs
         && Bits.to_bool o.idle_o;
      incr cycles
    done;
    assert !finished;
    let events = List.rev !events in
    [%test_result: Event.t list] events ~expect:(expected tokens);
    { Observation.events
    ; stalls = !stall_count
    ; aborts = !aborts
    ; completions = !completions
    }
  in
  Fixture.run_with_timeout ~timeout:30005 ~testbench
;;

let recovery =
  [ Token.Diagnostic (1, 1)
  ; Start (1, false)
  ; Body false
  ; Diagnostic (1, 5)
  ; Diagnostic (2, 6)
  ; Start (2, true)
  ; Diagnostic (3, 2)
  ; Start (4, false)
  ; Body true
  ]
;;
