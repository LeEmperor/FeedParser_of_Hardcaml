(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "stream_scenarios.ml" *)
(* Shared ingress and integration Step driver, protocol monitors, and queue scoreboard.
   Transfers use before_edge; state-hold checks use after_edge. Each run owns its seed.
   The byte-string oracle is independent of RTL byte extraction. *)

open! Core
open! Hardcaml
open! Cme_of_hardcaml
module F = Stream_test_support.Stream_fixture
open F
open Hardcaml_verif

module Beat = struct
  type t =
    { data : int64
    ; keep : int
    ; first : bool
    ; last : bool
    ; timestamp : int64
    }
  [@@deriving sexp, equal]
end

let observe_beat (b : F.beat) : Beat.t =
  { data = Bits.to_int64_trunc b.data
  ; keep = b.keep
  ; first = b.first
  ; last = b.last
  ; timestamp = Bits.to_int64_trunc b.timestamp
  }
;;

let output (o : Bits.t Ingress_fifo.O.t) : F.beat =
  { data = o.data_o
  ; keep = Bits.to_int_trunc o.keep_o
  ; first = Bits.to_bool o.first_o
  ; last = Bits.to_bool o.last_o
  ; timestamp = o.ingress_timestamp_o
  }
;;

let inputs ~reset ~enabled ~ready (b : F.beat) ~valid : Bits.t Ingress_fifo.I.t =
  { clock_i = Bits.gnd
  ; reset_i = Bits.of_bool reset
  ; en_i = Bits.of_bool enabled
  ; data_i = b.data
  ; keep_i = int 8 b.keep
  ; first_i = Bits.of_bool b.first
  ; last_i = Bits.of_bool b.last
  ; ingress_timestamp_i = b.timestamp
  ; valid_i = Bits.of_bool valid
  ; ready_i = Bits.of_bool ready
  }
;;

module Observation = struct
  type t =
    { cycles : int
    ; inputs : int
    ; outputs : int
    ; simultaneous : int
    ; full : int
    ; received : Beat.t list
    }
  [@@deriving sexp, equal]
end

let idle = List.hd_exn (packet "x")

let payload length salt =
  String.init length ~f:(fun n -> Char.of_int_exn (((n * 37) + salt) land 255))
;;

let packets random =
  List.init 300 ~f:(fun n ->
    let length = if n < 40 then n + 1 else 1 + Random.State.int random 257 in
    packet ~timestamp:(int 64 (1000 + n)) (payload length n))
  |> List.concat
;;

let run ?(seed = 1) ?payloads ~depth ~pass ~continuous ~shim_gaps ~resets () =
  let module Dut = struct
    module I = Ingress_fifo.I
    module O = Ingress_fifo.O

    let name = if pass then "stream_foundation" else "ingress_fifo"

    let create scope i =
      if pass
      then F.Pass_through.create ~depth scope i
      else Ingress_fifo.create ~depth scope i
    ;;
  end
  in
  let module Fixture = Sim_fixture.Make (Dut) in
  let module Step = Fixture.Step in
  let random = Random.State.make [| 0x434d45; seed |] in
  let chance n = Random.State.int random n = 0 in
  let testbench (handler : Step.Handler.t @ local) _ =
    let source =
      match payloads with
      | None -> packets random
      | Some xs -> List.concat_map xs ~f:(fun s -> packet s)
    in
    let received = ref [] in
    let todo = ref source in
    let pending = ref None in
    let expected = Queue.create () in
    let input_monitor, output_monitor = F.Monitor.create (), F.Monitor.create () in
    let input_count, output_count, simultaneous, full = ref 0, ref 0, ref 0, ref 0 in
    let current_timestamp = ref (Bits.zero 64) in
    let cycle = ref 0 in
    let last_send = ref (-8) in
    let done_ = ref false in
    while (not !done_) && !cycle < 200000 do
      let reset =
        !cycle = 0 || (resets && List.mem [ 70; 300 ] !cycle ~equal:Int.equal)
      in
      let enabled =
        continuous
        || not
             ((!cycle >= 40 && !cycle < 50)
              || (!cycle >= 120 && !cycle < 130)
              || chance 13)
      in
      let ready = continuous || (!cycle >= 90 && not (chance 3)) in
      if reset
      then (
        todo := source;
        pending := None;
        Queue.clear expected;
        current_timestamp := Bits.zero 64);
      if (not reset)
         && Option.is_none !pending
         && (not (List.is_empty !todo))
         && (continuous
             || (shim_gaps && !cycle - !last_send >= 8)
             || ((not shim_gaps) && not (chance 4)))
      then pending := Some (List.hd_exn !todo);
      let beat = Option.value !pending ~default:idle in
      (* The shim's timestamp is zero on Arty. Other tests supply packet context and
         deliberately vary the irrelevant timestamp on non-first input beats. *)
      let offered =
        { beat with
          timestamp =
            (if shim_gaps
             then Bits.zero 64
             else if beat.first
             then beat.timestamp
             else int 64 !cycle)
        }
      in
      let edge =
        Step.cycle
          handler
          (inputs ~reset ~enabled ~ready offered ~valid:(Option.is_some !pending))
      in
      let o = Step.O_data.before_edge edge in
      let after = Step.O_data.after_edge edge in
      let active = enabled && not reset in
      let app_tready_i = Bits.to_bool o.ready_o in
      let valid = Bits.to_bool o.valid_o in
      check (active || ((not app_tready_i) && not valid)) "disabled stream handshake";
      F.Monitor.observe
        input_monitor
        ~reset
        ~active
        ~valid:(Option.is_some !pending)
        ~ready:app_tready_i
        offered;
      let actual = output o in
      F.Monitor.observe output_monitor ~reset ~active ~valid ~ready actual;
      if not pass
      then (
        check
          (Bool.equal valid (active && not (Queue.is_empty expected)))
          "FIFO valid/occupancy";
        check
          (Bool.equal
             app_tready_i
             (active && (Queue.length expected < depth || (valid && ready))))
          "FIFO exact capacity or replacement readiness";
        if Queue.length expected = depth then incr full);
      if continuous && Option.is_some !pending && active
      then check app_tready_i "internally generated input stall";
      let pop = valid && ready in
      let push = Option.is_some !pending && app_tready_i in
      if continuous && !output_count > 0 && not (Queue.is_empty expected)
      then check valid "bubble in sustained stream output";
      if pop
      then (
        let wanted = Queue.dequeue_exn expected in
        check
          (String.equal (bytes actual) (bytes wanted))
          "transport bytes lost, duplicated, or reordered";
        check
          (actual.keep = wanted.keep
           && Bool.equal actual.first wanted.first
           && Bool.equal actual.last wanted.last)
          "transport packet boundary";
        check
          (Bits.equal actual.timestamp wanted.timestamp)
          "transport timestamp ownership";
        received := observe_beat actual :: !received;
        incr output_count);
      if push
      then (
        if offered.first then current_timestamp := offered.timestamp;
        Queue.enqueue
          expected
          { offered with
            timestamp =
              (if pass
               then !current_timestamp
               else if offered.first
               then offered.timestamp
               else Bits.zero 64)
          };
        todo := List.tl_exn !todo;
        pending := None;
        last_send := !cycle;
        incr input_count);
      if pop && push then incr simultaneous;
      let held_data = o.data_o in
      if (not active) && not reset
      then check (Bits.equal held_data after.data_o) "disable changed pending payload";
      incr cycle;
      done_
      := List.is_empty !todo
         && Option.is_none !pending
         && Queue.is_empty expected
         && !cycle > 301
    done;
    check !done_ "stream simulation timed out";
    { Observation.cycles = !cycle
    ; inputs = !input_count
    ; outputs = !output_count
    ; simultaneous = !simultaneous
    ; full = !full
    ; received = List.rev !received
    }
  in
  Fixture.run_with_timeout ~timeout:200005 ~testbench
;;
