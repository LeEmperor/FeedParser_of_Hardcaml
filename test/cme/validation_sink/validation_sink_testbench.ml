(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "validation_sink_testbench.ml" *)
(* Board-observability scenarios: a software counter model checked every cycle, and an
   independent UART receiver that decodes the serial pin without looking inside the DUT.

   The UART decoder deliberately samples only [uart_o], recovering byte framing from the
   pin the way the host does, so a serializer that emitted the right bytes with the wrong
   start/stop framing would still fail here. Record atomicity is checked by requiring
   every decoded counter tuple to be one the counters actually held simultaneously, and
   the check is kept honest by counting the records during whose transmission the live
   counters moved -- a run where nothing advanced mid-record proves nothing. *)

open! Core
open! Hardcaml
open Hardcaml_verif
module T = Cme_of_hardcaml.Cme_types
module Sink = Cme_board_validation.Cme_validation_sink

let counter_count = 8
let record_bytes = 36
let magic = [ 'C'; 'M'; 'E'; '7' ]

module Observation = struct
  type t =
    { records : int
    ; (* Records transmitted while the live counters were still advancing. *)
      records_over_moving_counters : int
    ; final : int list
    ; frozen_cycles : int
    }
  [@@deriving sexp, equal]
end

let unpack_counters bits =
  List.init counter_count ~f:(fun k ->
    Bits.to_int_trunc (Bits.select bits ~high:((32 * k) + 31) ~low:(32 * k)))
;;

(* Recover 8N1 bytes from the pin alone. Within a record the stop bit of one byte is
   immediately followed by the next start bit, so every bit centre is a fixed offset from
   the single falling edge that opens the record. *)
let decode_records ~uart_divisor pin =
  let n = Array.length pin in
  let sample i = if i < n then pin.(i) else true in
  let records = ref [] in
  let i = ref 1 in
  while !i < n do
    if (not pin.(!i)) && pin.(!i - 1)
    then (
      let start = !i in
      let bit j = sample (start + (j * uart_divisor) + (uart_divisor / 2)) in
      let last_bit = ((record_bytes * 10) - 1) * uart_divisor in
      if start + last_bit + (uart_divisor / 2) < n
      then (
        let bytes =
          List.init record_bytes ~f:(fun b ->
            let at k = bit ((b * 10) + k) in
            if at 0 then failwith "UART start bit was not low";
            if not (at 9) then failwith "UART stop bit was not high";
            List.init 8 ~f:(fun k -> if at (k + 1) then 1 lsl k else 0)
            |> List.fold ~init:0 ~f:( + ))
        in
        records := (start, bytes) :: !records;
        i := start + (record_bytes * 10 * uart_divisor) - 1)
      else i := n)
    else incr i
  done;
  List.rev !records
;;

let run ?(seed = 1) ?(cycles = 6000) ?(uart_divisor = 4) ?(snapshot_cycles = 137) () =
  let module Dut = struct
    module I = Sink.I
    module O = Sink.O

    let name = "cme_validation_sink"
    let create scope i = Sink.create ~uart_divisor ~snapshot_cycles scope i
  end
  in
  let module Fixture = Sim_fixture.Make (Dut) in
  let module Step = Fixture.Step in
  let random = Random.State.make [| 0x434d45; seed |] in
  let chance n = Random.State.int random n = 0 in
  let testbench (handler : Step.Handler.t @ local) _ =
    let model = Array.create ~len:counter_count 0 in
    let crc_pending = ref false in
    let pin = Array.create ~len:(cycles + 1) true in
    let history = Queue.create () in
    let seen = Hash_set.Poly.create () in
    let frozen_cycles = ref 0 in
    for cycle = 0 to cycles do
      let reset = cycle = 0 in
      let enabled = not (chance 13) in
      let event_valid = (not (chance 3)) && cycle > 2 in
      let kind = Random.State.int random 3 in
      let dcode = Random.State.int random 4 in
      let packet_accepted = chance 5 in
      let frame_done = chance 7 in
      let crc_error = chance 2 in
      let checksum_ok = not (chance 4) in
      let event =
        T.Event.Of_bits.pack
          { (T.Event.map T.Event.port_widths ~f:Bits.zero) with
            kind = Bits.of_int_trunc ~width:T.Event_kind.width kind
          ; diagnostic_code = Bits.of_int_trunc ~width:T.Diagnostic_code.width dcode
          }
      in
      let edge =
        Step.cycle
          handler
          { clock_i = Bits.gnd
          ; reset_i = Bits.of_bool reset
          ; en_i = Bits.of_bool enabled
          ; packet_accepted_i = Bits.of_bool packet_accepted
          ; event_valid_i = Bits.of_bool event_valid
          ; event_i = event
          ; rx_frame_done_i = Bits.of_bool frame_done
          ; crc_error_i = Bits.of_bool crc_error
          ; checksum_ok_i = Bits.of_bool checksum_ok
          ; display_i = Bits.of_int_trunc ~width:3 (Random.State.int random 8)
          }
      in
      let before = Step.O_data.before_edge edge in
      let after = Step.O_data.after_edge edge in
      pin.(cycle) <- Bits.to_bool before.uart_o;
      let active = enabled && not reset in
      (* The register holds the previous cycle's frame_done, so the old value decides this
         cycle's CRC verdict and only then is it replaced. *)
      let was_pending = !crc_pending in
      if reset
      then (
        Array.fill model ~pos:0 ~len:counter_count 0;
        crc_pending := false)
      else if active
      then (
        let bump k = model.(k) <- model.(k) + 1 in
        if packet_accepted then bump 0;
        if event_valid
        then
          if kind = T.Event_kind.mbp_update
          then bump 1
          else if kind = T.Event_kind.end_of_event
          then bump 2
          else if kind = T.Event_kind.diagnostic
          then (
            bump 3;
            if dcode = T.Diagnostic_code.sequence_gap then bump 6;
            if dcode = T.Diagnostic_code.duplicate_or_late then bump 7);
        if was_pending && crc_error then bump 4;
        if frame_done && not checksum_ok then bump 5;
        crc_pending := frame_done);
      let observed = unpack_counters after.counters_o in
      let expected = Array.to_list model in
      if not (List.equal Int.equal observed expected)
      then
        raise_s
          [%message
            "counter mismatch" (cycle : int) (observed : int list) (expected : int list)];
      if not active then incr frozen_cycles;
      Queue.enqueue history (cycle, expected);
      Hash_set.add seen expected;
      let display = List.nth_exn expected 0 in
      ignore display
    done;
    let records = decode_records ~uart_divisor pin in
    let counters_at cycle =
      Queue.to_list history
      |> List.filter ~f:(fun (c, _) -> c <= cycle)
      |> List.last
      |> Option.map ~f:snd
    in
    let moving = ref 0 in
    List.iter records ~f:(fun (start, bytes) ->
      let text = List.take bytes 4 |> List.map ~f:Char.of_int_exn in
      if not (List.equal Char.equal text magic)
      then raise_s [%message "bad UART magic" (text : char list)];
      let payload =
        List.drop bytes 4
        |> List.chunks_of ~length:4
        |> List.map ~f:(fun word ->
          List.foldi word ~init:0 ~f:(fun k acc b -> acc + (b lsl (8 * k))))
      in
      (* A torn record mixes two sample points, producing a tuple the counters never held
         at one instant. *)
      if not (Hash_set.mem seen payload)
      then raise_s [%message "torn UART record" (start : int) (payload : int list)];
      let finish = start + (record_bytes * 10 * uart_divisor) in
      match counters_at start, counters_at finish with
      | Some a, Some b -> if not (List.equal Int.equal a b) then incr moving
      | _ -> ());
    { Observation.records = List.length records
    ; records_over_moving_counters = !moving
    ; final = Array.to_list model
    ; frozen_cycles = !frozen_cycles
    }
  in
  Fixture.run_with_timeout ~timeout:(cycles + 10) ~testbench
;;
