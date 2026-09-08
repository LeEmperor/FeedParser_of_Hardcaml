(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "validation_core_testbench.ml" *)
(* Board integration from the recovered UDP payload to the UART pin: destination-port
   selection, the feed parser, and the counter sink.

   Packets are tagged with the UDP port the network stack would report. The scenario
   interleaves selected and filtered traffic so the central board claim -- that unrelated
   host chatter on the validation link cannot perturb parser sequence state -- is
   exercised rather than assumed. Sequence numbers are assigned only to selected packets,
   so if a filtered packet ever reached the parser the very next selected packet would
   raise a sequence-gap diagnostic and the expected counters would not match. *)

open! Core
open! Hardcaml
open Hardcaml_verif
module F = Schema_test_support.Schema_fixture
module Stream = Stream_test_support.Stream_fixture
module Core_dut = Cme_board_validation.Cme_validation_core

let dest_port = 31337
let counter_count = 8

module Observation = struct
  type t =
    { packets : int
    ; updates : int
    ; end_of_event : int
    ; diagnostics : int
    ; crc_errors : int
    ; ip_errors : int
    ; sequence_gaps : int
    ; duplicates : int
    ; filtered_beats : int
    ; (* Cycles a filtered packet was accepted while the parser was refusing input. *)
      filtered_while_parser_busy : int
    }
  [@@deriving sexp, compare, equal]
end

let unpack bits =
  List.init counter_count ~f:(fun k ->
    Bits.to_int_trunc (Bits.select bits ~high:((32 * k) + 31) ~low:(32 * k)))
;;

(* [packets] pairs a UDP payload with the port it arrives on. *)
let run ?(seed = 1) ?(stalls = true) ?(uart_divisor = 4) ?(snapshot_cycles = 4000) packets
  =
  let module Dut = struct
    module I = Core_dut.I
    module O = Core_dut.O

    let name = "cme_validation_core"
    let create scope i = Core_dut.create ~dest_port ~uart_divisor ~snapshot_cycles scope i
  end
  in
  let module Fixture = Sim_fixture.Make (Dut) in
  let module Step = Fixture.Step in
  let random = Random.State.make [| seed; 0x424f41 |] in
  let chance n = stalls && Random.State.int random n = 0 in
  let source =
    List.concat_map packets ~f:(fun (port, payload) ->
      Stream.packet payload |> List.map ~f:(fun beat -> port, beat))
  in
  let testbench (handler : Step.Handler.t @ local) _ =
    let todo = ref source in
    let filtered_beats = ref 0 in
    let filtered_while_parser_busy = ref 0 in
    let counters = ref (List.init counter_count ~f:(fun _ -> 0)) in
    let cycle = ref 0 in
    let idle_after = ref 0 in
    while (not (List.is_empty !todo && !idle_after > 400)) && !cycle < 60000 do
      let reset = !cycle = 0 in
      let enabled = (not reset) && not (chance 23) in
      let offer = (not (List.is_empty !todo)) && not (chance 5) in
      let port, beat =
        match !todo with
        | (p, b) :: _ -> p, b
        | [] -> dest_port, List.hd_exn (Stream.packet "x")
      in
      let edge =
        Step.cycle
          handler
          { clock_i = Bits.gnd
          ; reset_i = Bits.of_bool reset
          ; en_i = Bits.of_bool enabled
          ; data_i = beat.data
          ; keep_i = Bits.of_int_trunc ~width:8 beat.keep
          ; valid_i = Bits.of_bool offer
          ; first_i = Bits.of_bool (offer && beat.first)
          ; last_i = Bits.of_bool (offer && beat.last)
          ; dst_port_i = Bits.of_int_trunc ~width:16 port
          ; rx_frame_done_i = Bits.gnd
          ; crc_error_i = Bits.gnd
          ; checksum_ok_i = Bits.vdd
          ; display_i = Bits.zero 3
          }
      in
      let before = Step.O_data.before_edge edge in
      let after = Step.O_data.after_edge edge in
      let ready = Bits.to_bool before.ready_o in
      if offer && ready
      then (
        todo := List.tl_exn !todo;
        if port <> dest_port then incr filtered_beats;
        idle_after := 0)
      else incr idle_after;
      (* Filtered traffic must never inherit the parser's backpressure. A filtered beat
         accepted in a cycle where a selected beat would have been refused is the only
         evidence that the two paths are genuinely decoupled. *)
      if offer && port <> dest_port && ready && enabled && not reset
      then incr filtered_while_parser_busy;
      counters := unpack after.counters_o;
      incr cycle
    done;
    if not (List.is_empty !todo) then failwith "core testbench failed to drain";
    match !counters with
    | [ packets; updates; ends; diagnostics; crc; ip; gaps; duplicates ] ->
      { Observation.packets
      ; updates
      ; end_of_event = ends
      ; diagnostics
      ; crc_errors = crc
      ; ip_errors = ip
      ; sequence_gaps = gaps
      ; duplicates
      ; filtered_beats = !filtered_beats
      ; filtered_while_parser_busy = !filtered_while_parser_busy
      }
    | _ -> failwith "counter unpacking"
  in
  Fixture.run_with_timeout ~timeout:60010 ~testbench
;;

let selected payload = dest_port, payload
let filtered ?(port = dest_port + 1) payload = port, payload

(* MatchEventIndicator bit 7 is LastMsgOfEvent: without it the parser emits the update but
   no end-of-event marker. The board sender in validation/phase7/board_cases.py sets it,
   so the simulation stimulus sets it too and the two agree on expected counters. *)
let last_msg_of_event = 0x80

let simple ?(match_event_indicator = last_msg_of_event) sequence =
  F.packet sequence [ F.message ~match_event_indicator [ F.default_entry ] ]
;;
