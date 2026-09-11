(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "message_pipeline_testbench.ml" *)
(* Message boundary scoreboard. The software model reads literal payload bytes and models
   admission independently; Step transfers are sampled before the edge. *)

open! Core
open! Hardcaml
open! Cme_of_hardcaml
open Hardcaml_verif
module Stream = Stream_test_support.Stream_fixture
module T = Cme_types

module Context = struct
  type t =
    { timestamp : int64
    ; seq : int64
    ; sending_time : int64
    ; header_present : bool
    ; channel_valid : bool
    }
  [@@deriving sexp, equal, compare]
end

module Header = struct
  type t =
    { size : int
    ; block : int
    ; template : int
    ; schema : int
    ; version : int
    ; present : bool
    ; offset : int
    }
  [@@deriving sexp, equal, compare]
end

module Item = struct
  type t =
    | Message of Context.t * Header.t * string
    | Diagnostic of Context.t * Header.t * int * int64 option * int
  [@@deriving sexp, equal, compare]
end

let absent offset : Header.t =
  { size = 0; block = 0; template = 0; schema = 0; version = 0; present = false; offset }
;;

type packet =
  { payload : string
  ; timestamp : int64
  }
[@@deriving sexp]

type control =
  { after_beats : int
  ; session_reset : bool
  ; resync : int64 option
  ; pulse : bool
  }
[@@deriving sexp]

module Observation = struct
  type t =
    { items : Item.t list
    ; controls : (int * int) list
    ; input_stalls : int
    ; output_stalls : int
    ; cut_through : bool
    ; cancelled_work : bool
    ; cycles : int
    }
  [@@deriving sexp]
end

let wrap n = Int64.bit_and n 0xffff_ffffL

let le s offset count =
  List.init count ~f:(fun n ->
    Int64.shift_left (Int64.of_int (Char.to_int s.[offset + n])) (8 * n))
  |> List.fold ~init:0L ~f:Int64.bit_or
;;

let encode_le n count =
  String.init count ~f:(fun lane ->
    Int64.to_int_exn (Int64.bit_and (Int64.shift_right_logical n (8 * lane)) 255L)
    |> Char.of_int_exn)
;;

let packet
  ?(timestamp = 0xfedc_ba98_7654_3210L)
  ?(sending_time = 0x8877_6655_4433_2211L)
  seq
  body
  =
  { payload = encode_le seq 4 ^ encode_le sending_time 8 ^ body; timestamp }
;;

let short n =
  { payload = String.init n ~f:(fun i -> Char.of_int_exn (240 - i))
  ; timestamp = Int64.of_int n
  }
;;

let control ?(session_reset = false) ?resync ?(pulse = false) after_beats =
  { after_beats; session_reset; resync; pulse }
;;

let message ?(template = 42) ?(block = 0) ?(schema = 1) ?(version = 13) ?size body =
  let size = Option.value size ~default:(10 + String.length body) in
  String.concat
    (List.map [ size; block; template; schema; version ] ~f:(fun n ->
       encode_le (Int64.of_int n) 2))
  ^ body
;;

let header payload offset : Header.t =
  let field n = Int64.to_int_exn (le payload (offset + n) 2) in
  { size = field 0
  ; block = field 2
  ; template = field 4
  ; schema = field 6
  ; version = field 8
  ; present = true
  ; offset
  }
;;

let walk context payload =
  let length = String.length payload in
  let rec next offset =
    let diag h code pos = Item.Diagnostic (context, h, code, None, pos) in
    if offset = length
    then []
    else if length - offset < 10
    then [ diag (absent offset) 5 length ]
    else (
      let h = header payload offset in
      if h.size < 10
      then [ diag h 4 offset ]
      else (
        let unsupported = h.template <> 42 && h.template <> 0x9876 in
        let errors = if unsupported then [ diag h 6 (offset + 4) ] else [] in
        if offset + h.size > length
        then errors @ [ diag h 5 length ]
        else
          (if unsupported
           then errors
           else
             [ Item.Message
                 (context, h, String.sub payload ~pos:(offset + 10) ~len:(h.size - 10))
             ])
          @ next (offset + h.size)))
  in
  next 12
;;

let model expected valid (p : packet) =
  let length = String.length p.payload in
  let base : Context.t =
    { timestamp = p.timestamp
    ; seq = 0L
    ; sending_time = 0L
    ; header_present = false
    ; channel_valid = !valid
    }
  in
  if length < 12
  then [ Item.Diagnostic (base, absent 0, 3, None, length) ]
  else (
    let seq = le p.payload 0 4 in
    let context =
      { base with seq; sending_time = le p.payload 4 8; header_present = true }
    in
    let delta = Option.map !expected ~f:(fun next -> wrap Int64.(seq - next)) in
    let late = Option.exists delta ~f:(fun d -> Int64.(d >= 0x8000_0000L)) in
    let gap = Option.exists delta ~f:(fun d -> Int64.(d > 0L && d < 0x8000_0000L)) in
    if late
    then [ Item.Diagnostic (context, absent 0, 2, !expected, 0) ]
    else (
      if Option.is_none !expected then valid := true;
      if gap then valid := false;
      let context = { context with channel_valid = !valid } in
      let diagnostics =
        if gap then [ Item.Diagnostic (context, absent 0, 1, !expected, 0) ] else []
      in
      expected := Some (wrap Int64.(seq + 1L));
      diagnostics @ walk context p.payload))
;;

let context (c : Bits.t T.Packet_context.t) : Context.t =
  assert (not (Bits.to_bool c.source_id));
  { timestamp = Bits.to_int64_trunc c.ingress_timestamp
  ; seq = Bits.to_int64_trunc c.packet_seq
  ; sending_time = Bits.to_int64_trunc c.sending_time
  ; header_present = Bits.to_bool c.packet_header_present
  ; channel_valid = Bits.to_bool c.channel_valid
  }
;;

let observe_header (h : Bits.t T.Message_context.t) : Header.t =
  assert (Bits.equal h.transaction_time (Bits.zero 64));
  assert (not (Bits.to_bool h.transaction_time_present));
  { size = Bits.to_int_trunc h.msg_size
  ; block = Bits.to_int_trunc h.block_length
  ; template = Bits.to_int_trunc h.template_id
  ; schema = Bits.to_int_trunc h.schema_id
  ; version = Bits.to_int_trunc h.schema_version
  ; present = Bits.to_bool h.message_header_present
  ; offset = Bits.to_int_trunc h.packet_byte_offset
  }
;;

(* Completion-independent scoreboard: every body byte is checked immediately against the
   original packet. An abort may follow any cut-through prefix, depending on lookahead. *)
let observe packets current packed =
  let item = T.Message_item.Of_bits.unpack packed in
  let blank = T.Message_item.Of_bits.zero () in
  let kind = Bits.to_int_trunc item.kind in
  let allowed =
    match kind with
    | 0 ->
      { blank with
        packet = item.packet
      ; message = item.message
      ; body_empty = item.body_empty
      ; beat = item.beat
      }
    | 1 -> { blank with kind = item.kind; beat = item.beat }
    | 2 -> { blank with kind = item.kind; diagnostic = item.diagnostic }
    | _ -> failwith "reserved message kind"
  in
  assert (Bits.equal packed (T.Message_item.Of_bits.pack allowed));
  if kind = 2
  then (
    let d = item.diagnostic in
    assert (Bits.to_int_trunc d.kind = 2);
    let h = observe_header d.message in
    let c = context d.packet in
    let code = Bits.to_int_trunc d.diagnostic_code in
    Option.iter !current ~f:(fun (old_c, old_h, _) ->
      assert (code = 5 && Context.equal c old_c && Header.equal h old_h));
    current := None;
    let expected =
      if Bits.to_bool d.expected_seq_present
      then Some (Bits.to_int64_trunc d.expected_seq)
      else None
    in
    let allowed_event =
      { (T.Event.Of_bits.zero ()) with
        kind = d.kind
      ; packet = d.packet
      ; message = d.message
      ; diagnostic_code = d.diagnostic_code
      ; expected_seq = d.expected_seq
      ; expected_seq_present = d.expected_seq_present
      ; diagnostic_byte_offset = d.diagnostic_byte_offset
      }
    in
    assert (Bits.equal (T.Event.Of_bits.pack d) (T.Event.Of_bits.pack allowed_event));
    Some
      (Item.Diagnostic (c, h, code, expected, Bits.to_int_trunc d.diagnostic_byte_offset)))
  else (
    if kind = 0
    then (
      assert (Option.is_none !current);
      current := Some (context item.packet, observe_header item.message, ""));
    let c, h, previous = Option.value_exn !current in
    let empty = kind = 0 && Bits.to_bool item.body_empty in
    let bytes =
      if empty
      then (
        assert (Bits.equal (T.Beat.Of_bits.pack item.beat) (Bits.zero 74));
        "")
      else (
        let keep = Bits.to_int_trunc item.beat.keep in
        assert (keep > 0 && keep land (keep + 1) = 0);
        assert (Bits.to_bool item.beat.last || keep = 255);
        assert (Bool.equal (Bits.to_bool item.beat.first) (kind = 0));
        Stream.bytes
          { data = item.beat.data
          ; keep
          ; first = kind = 0
          ; last = Bits.to_bool item.beat.last
          ; timestamp = Bits.zero 64
          })
    in
    let body = previous ^ bytes in
    let p =
      List.find_exn packets ~f:(fun p ->
        String.length p.payload >= 12
        && Int64.equal (le p.payload 0 4) c.seq
        && Int64.equal p.timestamp c.timestamp)
    in
    [%test_result: string]
      body
      ~expect:(String.sub p.payload ~pos:(h.offset + 10) ~len:(String.length body));
    if empty || Bits.to_bool item.beat.last
    then (
      assert (String.length body = h.size - 10);
      current := None;
      Some (Item.Message (c, h, body)))
    else (
      current := Some (c, h, body);
      None))
;;

module Make (Config : sig
    val depth : int
  end) =
struct
  module Dut = struct
    include Message_pipeline

    let name = "message_pipeline"

    let create scope i =
      create
        ~supported_templates:[ 42; 0x9876 ]
        ~config:{ Cme_config.default with ingress_fifo_depth = Config.depth }
        scope
        i
    ;;
  end

  module Fixture = Sim_fixture.Make (Dut)
  module Step = Fixture.Step

  let run
    ?(seed = 1)
    ?(stalls = true)
    ?(controls = [])
    ?reset_at
    ?(sink_block_until = 0)
    ?(sink_stall_windows = [])
    ?(beat_gap = 0)
    ?(downstream_busy_until = 0)
    packets
    =
    let random = Random.State.make [| 0x504832; seed |] in
    let chance n = stalls && Random.State.int random n = 0 in
    let source =
      List.concat_map packets ~f:(fun p ->
        Stream.packet ~timestamp:(Bits.of_int64_trunc ~width:64 p.timestamp) p.payload
        |> List.map ~f:(fun beat -> p, beat))
    in
    let testbench (handler : Step.Handler.t @ local) _ =
      let todo = ref source in
      let next_offer = ref 0 in
      let pending = ref None in
      let requests = ref controls in
      let expected_seq, channel_valid = ref None, ref false in
      let expected_items = Queue.create () in
      let items, accepted_controls = ref [], ref [] in
      let cycle, accepted, input_stalls, output_stalls = ref 0, ref 0, ref 0, ref 0 in
      let held_output = ref None in
      let current = ref None in
      let cancelled_work = ref false in
      let cut_through = ref false in
      let packet_count = ref 0 in
      let finished = ref false in
      let input_monitor = Stream.Monitor.create () in
      while (not !finished) && !cycle < 100000 do
        let reset = !cycle = 0 || Option.equal Int.equal reset_at (Some !cycle) in
        let enabled = (not reset) && not (chance 19) in
        if reset
        then (
          if !cycle > 0
          then
            cancelled_work
            := (not (Queue.is_empty expected_items)) || input_monitor.open_packet;
          todo := source;
          pending := None;
          requests := controls;
          next_offer := 0;
          packet_count := 0;
          expected_seq := None;
          channel_valid := false;
          Queue.clear expected_items;
          held_output := None;
          current := None;
          accepted := 0;
          items := [];
          accepted_controls := []);
        if (not reset)
           && !cycle >= !next_offer
           && Option.is_none !pending
           && (not (List.is_empty !todo))
           && not (chance 4)
        then pending := Some (List.hd_exn !todo);
        let request =
          List.hd !requests |> Option.filter ~f:(fun c -> !accepted >= c.after_beats)
        in
        let p, offered =
          Option.value
            !pending
            ~default:({ payload = "x"; timestamp = 0L }, List.hd_exn (Stream.packet "x"))
        in
        let sink_ready =
          !cycle >= sink_block_until
          && (not
                (List.exists sink_stall_windows ~f:(fun (first, last) ->
                   !cycle >= first && !cycle < last)))
          && not (chance 3)
        in
        let downstream_idle = !cycle >= downstream_busy_until in
        let edge =
          Step.cycle
            handler
            { clock_i = Bits.gnd
            ; reset_i = Bits.of_bool reset
            ; en_i = Bits.of_bool enabled
            ; data_i = offered.data
            ; keep_i = Stream.int 8 offered.keep
            ; first_i = Bits.of_bool offered.first
            ; last_i = Bits.of_bool offered.last
            ; ingress_timestamp_i =
                (if offered.first
                 then offered.timestamp
                 else Bits.of_int_trunc ~width:64 !cycle)
            ; valid_i = Bits.of_bool (Option.is_some !pending)
            ; ready_i = Bits.of_bool sink_ready
            ; downstream_idle_i = Bits.of_bool downstream_idle
            ; session_reset_i =
                Bits.of_bool (Option.exists request ~f:(fun c -> c.session_reset))
            ; resync_valid_i =
                Bits.of_bool (Option.exists request ~f:(fun c -> Option.is_some c.resync))
            ; resync_next_seq_i =
                Bits.of_int64_trunc
                  ~width:32
                  (Option.bind request ~f:(fun c -> c.resync) |> Option.value ~default:0L)
            }
        in
        let o = Step.O_data.before_edge edge in
        let ready, valid, control_ready =
          Bits.to_bool o.ready_o, Bits.to_bool o.valid_o, Bits.to_bool o.control_ready_o
        in
        Stream.Monitor.observe
          input_monitor
          ~reset
          ~active:enabled
          ~valid:(Option.is_some !pending)
          ~ready
          offered;
        if not enabled then assert ((not ready) && (not valid) && not control_ready);
        if not downstream_idle then assert (not control_ready);
        if not reset
        then
          Option.iter !held_output ~f:(fun old ->
            assert (Bits.equal old o.item_o);
            if enabled then assert valid);
        if valid && not sink_ready then incr output_stalls;
        if valid then held_output := if sink_ready then None else Some o.item_o;
        Option.iter request ~f:(fun c ->
          if control_ready
          then (
            assert (Queue.is_empty expected_items);
            assert (not ready);
            if c.session_reset
            then (
              expected_seq := None;
              channel_valid := false)
            else (
              expected_seq := c.resync;
              channel_valid := true);
            accepted_controls := (!cycle, !accepted) :: !accepted_controls);
          if control_ready || (c.pulse && enabled) then requests := List.tl_exn !requests);
        if Option.is_some !pending
        then
          if ready
          then (
            if offered.first
            then
              List.iter
                (model expected_seq channel_valid p)
                ~f:(Queue.enqueue expected_items);
            if offered.first then incr packet_count;
            incr accepted;
            todo := List.tl_exn !todo;
            pending := None;
            next_offer := !cycle + beat_gap + 1)
          else if enabled
          then incr input_stalls;
        if valid && sink_ready
        then (
          let actual = observe packets current o.item_o in
          if !packet_count = 1 && input_monitor.open_packet then cut_through := true;
          Option.iter actual ~f:(fun actual ->
            let expected = Queue.dequeue_exn expected_items in
            if not (Item.equal actual expected)
            then
              raise_s
                [%message
                  "canonical mismatch"
                    (!cycle : int)
                    (actual : Item.t)
                    (expected : Item.t)];
            items := actual :: !items));
        let reset_finished =
          Option.value_map reset_at ~default:true ~f:(fun at -> !cycle > at)
        in
        finished
        := reset_finished
           && !cycle > 0
           && List.is_empty !todo
           && Option.is_none !pending
           && List.is_empty !requests
           && control_ready;
        incr cycle
      done;
      Stream.check !finished "packet pipeline timed out";
      assert (Queue.is_empty expected_items);
      assert (Option.is_none !current);
      { Observation.items = List.rev !items
      ; controls = List.rev !accepted_controls
      ; input_stalls = !input_stalls
      ; output_stalls = !output_stalls
      ; cut_through = !cut_through
      ; cancelled_work = !cancelled_work
      ; cycles = !cycle
      }
    in
    Fixture.run_with_timeout ~timeout:100005 ~testbench
  ;;
end

module Default = Make (struct
    let depth = 64
  end)

module Small = Make (struct
    let depth = 3
  end)

module Tiny = Make (struct
    let depth = 1
  end)

let run = Default.run
