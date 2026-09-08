(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "byte_aligner_testbench.ml" *)
(* Peek/consume Step driver. Ready/valid and windows use before_edge; held state uses
   after_edge. Independent accepted-byte queue never borrows a following packet.

   The aligner stores three beats but exposes only the leading two, so the model tags each
   accepted byte with the beat that carried it and clips the expected window to the first
   two resident beats. *)

open! Core
open! Hardcaml
open! Cme_of_hardcaml
open Hardcaml_verif
open Stream_test_support.Stream_fixture

let idle = List.hd_exn (packet "x")

type byte =
  { value : char
  ; first : bool
  ; last : bool
  ; offset : int
  ; timestamp : Bits.t
  ; (* Which accepted beat carried this byte; only the two leading beats are visible. *)
    beat : int
  }

module Dut = struct
  include Byte_aligner

  let name = "byte_aligner"
end

module Fixture = Sim_fixture.Make (Dut)
module Step = Fixture.Step

module Observation = struct
  type t =
    { consumed : int
    ; offsets : bool list
    ; counts : bool list
    ; full_window : bool
    ; two_slot_retirement : bool
    ; packet_isolation : bool
    }
  [@@deriving sexp, equal]
end

let run ?(seed = 1) ?(max_consume = 8) () =
  let module Dut = struct
    include Byte_aligner

    let create = create_with_limit ~max_consume
    let name = "byte_aligner"
  end
  in
  let module Fixture = Sim_fixture.Make (Dut) in
  let module Step = Fixture.Step in
  let random = Random.State.make [| 0x434d45; seed |] in
  let chance n = Random.State.int random n = 0 in
  let testbench (handler : Step.Handler.t @ local) _ =
    let source = Cme_verif.Stream_scenarios.packets random in
    let todo, pending = ref source, ref None in
    let expected = Queue.create () in
    let input_offset = ref 0 in
    let input_beat = ref 0 in
    let current_timestamp = ref (Bits.zero 64) in
    let offsets = Array.create ~len:8 false in
    let counts = Array.create ~len:(max_consume + 1) false in
    let saw_full, saw_two_pop, saw_boundary_block = ref false, ref false, ref false in
    let cycle, consumed = ref 0, ref 0 in
    while
      !cycle < 200000
      && (!cycle < 302
          || not
               (List.is_empty !todo && Option.is_none !pending && Queue.is_empty expected)
         )
    do
      let reset = List.mem [ 0; 80; 300 ] !cycle ~equal:Int.equal in
      let enabled = not (!cycle = 80 || (!cycle >= 40 && !cycle < 50) || chance 17) in
      if reset
      then (
        todo := source;
        pending := None;
        Queue.clear expected;
        input_offset := 0);
      if (not reset)
         && Option.is_none !pending
         && (not (List.is_empty !todo))
         && not (chance 4)
      then pending := Some (List.hd_exn !todo);
      let offered = Option.value !pending ~default:idle in
      let rec current_packet = function
        | [] -> []
        | b :: rest -> b :: (if b.last then [] else current_packet rest)
      in
      (* slot2 is storage behind the window: only the head beat and, when the head is not
         the packet's last beat, the one behind it can be peeked. *)
      let resident =
        List.group (Queue.to_list expected) ~break:(fun a b -> a.beat <> b.beat)
      in
      let visible =
        match resident with
        | [] -> []
        | [ head ] -> head
        | head :: tail :: _ -> head @ tail
      in
      let window = current_packet visible in
      let available = List.length window in
      let request = Random.State.int random (1 + Int.min max_consume available) in
      let command_valid = !cycle >= 60 && not (chance 3) in
      let edge =
        Step.cycle
          handler
          { clock_i = Bits.gnd
          ; reset_i = Bits.of_bool reset
          ; en_i = Bits.of_bool enabled
          ; data_i = offered.data
          ; keep_i = int 8 offered.keep
          ; first_i = Bits.of_bool offered.first
          ; last_i = Bits.of_bool offered.last
          ; ingress_timestamp_i =
              (if offered.first then offered.timestamp else int 64 !cycle)
          ; valid_i = Bits.of_bool (Option.is_some !pending)
          ; consume_count_i = int 4 request
          ; consume_valid_i = Bits.of_bool command_valid
          }
      in
      let o = Step.O_data.before_edge edge in
      let after = Step.O_data.after_edge edge in
      let active = enabled && not reset in
      if not reset
      then
        check
          (Bits.to_int_trunc o.available_o = available)
          (sprintf
             "aligner available byte count cycle=%d actual=%d expected=%d"
             !cycle
             (Bits.to_int_trunc o.available_o)
             available);
      check
        (Bool.equal (Bits.to_bool o.valid_o) (active && available > 0))
        "aligner valid";
      if not reset
      then
        check
          (Bool.equal
             (Bits.to_bool o.boundary_o)
             (List.exists window ~f:(fun b -> b.last)))
          "aligner boundary lookahead";
      check
        (Bool.equal (Bits.to_bool o.consume_ready_o) (active && available > 0))
        "legal consume readiness";
      if not active
      then check (not (Bits.to_bool o.ready_o)) "disabled aligner input handshake";
      List.iteri window ~f:(fun lane b ->
        let actual =
          Bits.select o.data_o ~high:((lane * 8) + 7) ~low:(lane * 8) |> Bits.to_int_trunc
        in
        check
          (actual = Char.to_int b.value)
          "aligner byte window corrupted or borrowed next packet");
      if (not reset) && available < 16
      then
        check
          (Bits.equal
             (Bits.select o.data_o ~high:127 ~low:(available * 8))
             (Bits.zero (128 - (available * 8))))
          "aligner exposed invalid lanes";
      Option.iter (List.hd window) ~f:(fun b ->
        check (Bool.equal (Bits.to_bool o.first_o) b.first) "aligner first marker";
        check (Bits.to_int_trunc o.packet_byte_offset_o = b.offset) "accepted-byte offset";
        check (Bits.equal o.ingress_timestamp_o b.timestamp) "aligner packet context";
        offsets.(b.offset land 7) <- true);
      if available = 16 then saw_full := true;
      if available < Queue.length expected then saw_boundary_block := true;
      if command_valid && Bits.to_bool o.consume_ready_o
      then (
        counts.(request) <- true;
        Option.iter (List.hd window) ~f:(fun b ->
          if request > 8 - (b.offset land 7)
             && List.exists (List.take window request) ~f:(fun b -> b.last)
          then saw_two_pop := true);
        for _ = 1 to request do
          ignore (Queue.dequeue_exn expected : byte)
        done;
        consumed := !consumed + request);
      if Option.is_some !pending && Bits.to_bool o.ready_o
      then (
        if offered.first
        then (
          input_offset := 0;
          current_timestamp := offered.timestamp);
        let s = bytes offered in
        String.iteri s ~f:(fun n value ->
          Queue.enqueue
            expected
            { value
            ; first = offered.first && n = 0
            ; last = offered.last && n = String.length s - 1
            ; offset = !input_offset + n
            ; timestamp = !current_timestamp
            ; beat = !input_beat
            });
        input_offset := !input_offset + String.length s;
        incr input_beat;
        todo := List.tl_exn !todo;
        pending := None);
      let held_offset, held_data = o.packet_byte_offset_o, o.data_o in
      if (not reset) && ((not active) || (not command_valid) || request = 0)
      then
        check
          (Bits.equal held_offset after.packet_byte_offset_o)
          "offset advanced without consuming";
      if (not active) && not reset
      then check (Bits.equal held_data after.data_o) "aligner changed during disable";
      incr cycle
    done;
    check (!cycle < 200000 && Queue.is_empty expected) "aligner timed out";
    { Observation.consumed = !consumed
    ; offsets = Array.to_list offsets
    ; counts = Array.to_list counts
    ; full_window = !saw_full
    ; two_slot_retirement = !saw_two_pop
    ; packet_isolation = !saw_boundary_block
    }
  in
  Fixture.run_with_timeout ~timeout:200005 ~testbench
;;

module Limit_observation = struct
  type t =
    { request : int
    ; available : int
    ; offset : int
    ; ready : bool
    ; data : string
    ; after_available : int
    ; after_valid : bool
    }
  [@@deriving sexp, equal]
end

let run_limits () =
  let testbench (handler : Step.Handler.t @ local) _ =
    let idle : Bits.t Dut.I.t =
      { clock_i = Bits.gnd
      ; reset_i = Bits.vdd
      ; en_i = Bits.gnd
      ; data_i = Bits.of_string "64'hffffffff00636261"
      ; keep_i = int 8 7
      ; first_i = Bits.vdd
      ; last_i = Bits.vdd
      ; ingress_timestamp_i = Bits.ones 64
      ; valid_i = Bits.gnd
      ; consume_valid_i = Bits.gnd
      ; consume_count_i = int 4 0
      }
    in
    ignore (Step.cycle handler idle : Step.O_data.t);
    let load = { idle with reset_i = Bits.gnd; en_i = Bits.vdd; valid_i = Bits.vdd } in
    ignore (Step.cycle handler load : Step.O_data.t);
    let rec loop (handler : Step.Handler.t @ local) = function
      | [] -> []
      | request :: rest ->
        let edge =
          Step.cycle
            handler
            { load with
              valid_i = Bits.gnd
            ; consume_valid_i = Bits.vdd
            ; consume_count_i = int 4 request
            }
        in
        let o = Step.O_data.before_edge edge in
        let after = Step.O_data.after_edge edge in
        let observation : Limit_observation.t =
          { request
          ; available = Bits.to_int_trunc o.available_o
          ; offset = Bits.to_int_trunc o.packet_byte_offset_o
          ; ready = Bits.to_bool o.consume_ready_o
          ; data = Bits.to_bstr o.data_o
          ; after_available = Bits.to_int_trunc after.available_o
          ; after_valid = Bits.to_bool after.valid_o
          }
        in
        observation :: loop handler rest
    in
    loop handler [ 4; 8; 9; 15; 0; 3 ]
  in
  Fixture.run_with_timeout ~timeout:12 ~testbench
;;
