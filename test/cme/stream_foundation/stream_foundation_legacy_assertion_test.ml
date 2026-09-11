(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "stream_foundation_legacy_assertion_test.ml" *)
(* Phase 1 byte, framing, context, handshake, reset, and sustained-rate scoreboards. *)

(* Tags: [{ "DEPRECATED" ; "ASSERTION_TEST" }] *)

open! Core
open! Hardcaml
open! Cme_of_hardcaml
module F = Stream_test_support.Stream_fixture
open F

let scope () = Scope.create ~flatten_design:true ()
let idle = List.hd_exn (packet "x")
let random = Random.State.make [| 0x434d45; 1 |]
let chance n = Random.State.int random n = 0

let payload length salt =
  String.init length ~f:(fun n -> Char.of_int_exn (((n * 37) + salt) land 255))
;;

let packets () =
  List.init 300 ~f:(fun n ->
    let length = if n < 40 then n + 1 else 1 + Random.State.int random 257 in
    packet ~timestamp:(int 64 (1000 + n)) (payload length n))
  |> List.concat
;;

let test_monitor () =
  let reject f =
    check
      (try
         f ();
         false
       with
       | Failure _ -> true)
      "contract monitor failed to reject a violation"
  in
  let observe monitor ?(valid = true) ?(ready = true) beat =
    F.Monitor.observe monitor ~reset:false ~active:true ~valid ~ready beat
  in
  List.iter [ 0; 5; 0xfe ] ~f:(fun keep ->
    reject (fun () -> observe (F.Monitor.create ()) { idle with keep }));
  reject (fun () -> observe (F.Monitor.create ()) { idle with last = false });
  reject (fun () -> observe (F.Monitor.create ()) { idle with first = false });
  List.iter
    [ { idle with data = Bits.ones 64 }
    ; { idle with keep = 3 }
    ; { idle with first = false }
    ; { idle with last = false }
    ; { idle with timestamp = Bits.ones 64 }
    ]
    ~f:(fun changed ->
      let monitor = F.Monitor.create () in
      observe monitor ~ready:false idle;
      reject (fun () -> observe monitor changed));
  let monitor = F.Monitor.create () in
  observe monitor ~ready:false idle;
  reject (fun () -> observe monitor ~valid:false idle);
  F.Monitor.observe monitor ~reset:true ~active:false ~valid:false ~ready:false idle;
  observe monitor idle;
  check
    (String.equal (bytes (List.hd_exn (packet "abcdefgh"))) "abcdefgh")
    "byte source order"
;;

let test_stream ~depth ~pass ~continuous ~shim_gaps ~resets =
  let module S = Cyclesim.With_interface (Ingress_fifo.I) (Ingress_fifo.O) in
  let sim =
    S.create
      (if pass
       then F.Pass_through.create ~depth (scope ())
       else Ingress_fifo.create ~depth (scope ()))
  in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs ~clock_edge:Before sim in
  Ingress_fifo.I.iter2 i Ingress_fifo.I.port_widths ~f:(fun r w -> r := Bits.zero w);
  let source = packets () in
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
    let reset = !cycle = 0 || (resets && List.mem [ 70; 300 ] !cycle ~equal:Int.equal) in
    let enabled =
      continuous
      || not
           ((!cycle >= 40 && !cycle < 50) || (!cycle >= 120 && !cycle < 130) || chance 13)
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
    drive i offered ~valid:(Option.is_some !pending);
    i.reset_i := Bits.of_bool reset;
    i.en_i := Bits.of_bool enabled;
    i.ready_i := Bits.of_bool ready;
    Cyclesim.cycle_before_clock_edge sim;
    let active = enabled && not reset in
    let app_tready_i = is_set o.ready_o in
    let valid = is_set o.valid_o in
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
      check (Bits.equal actual.timestamp wanted.timestamp) "transport timestamp ownership";
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
    let held_data = !(o.data_o) in
    finish_cycle sim;
    if (not active) && not reset
    then (
      let after = Cyclesim.outputs sim in
      check (Bits.equal held_data !(after.data_o)) "disable changed pending payload");
    incr cycle;
    done_
    := List.is_empty !todo
       && Option.is_none !pending
       && Queue.is_empty expected
       && !cycle > 301
  done;
  check !done_ "stream simulation timed out";
  check
    (!input_count > 1000 && !output_count > 1000 && !simultaneous > 0)
    "insufficient stream coverage";
  if (not pass) && not continuous then check (!full > 0) "FIFO never reached full";
  printf
    "PASS: %s depth=%d continuous=%b shim_gaps=%b resets=%b (%d beats)\n"
    (if pass then "FIFO + aligner" else "ingress FIFO")
    depth
    continuous
    shim_gaps
    resets
    !output_count
;;

let test_events depth =
  let module S = Cyclesim.With_interface (Event_fifo.I) (Event_fifo.O) in
  let sim = S.create (Event_fifo.create ~depth (scope ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs ~clock_edge:Before sim in
  Event_fifo.I.iter2 i Event_fifo.I.port_widths ~f:(fun r w -> r := Bits.zero w);
  let expected = Queue.create () in
  let pending = ref None in
  let held = ref None in
  let full, simultaneous, outputs = ref 0, ref 0, ref 0 in
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
    i.reset_i := Bits.of_bool reset;
    i.en_i := Bits.of_bool enabled;
    i.event_i := Option.value !pending ~default:(Bits.zero Cme_types.Event.width);
    i.event_valid_i := Bits.of_bool (Option.is_some !pending);
    i.event_ready_i := Bits.of_bool ready;
    Cyclesim.cycle_before_clock_edge sim;
    let active = enabled && not reset in
    let valid, input_ready = is_set o.event_valid_o, is_set o.event_ready_o in
    check (Bool.equal valid (active && not (Queue.is_empty expected))) "event FIFO valid";
    check
      (Bool.equal
         input_ready
         (active && (Queue.length expected < depth || (valid && ready))))
      "event FIFO exact capacity";
    if Queue.length expected = depth then incr full;
    if active
    then (
      Option.iter !held ~f:(fun previous ->
        check (valid && Bits.equal previous !(o.event_o)) "stalled event changed");
      held := if valid && not ready then Some !(o.event_o) else None);
    if valid && ready
    then (
      check
        (Bits.equal (Queue.dequeue_exn expected) !(o.event_o))
        "event corruption or ordering";
      incr outputs);
    if input_ready && Option.is_some !pending
    then (
      Queue.enqueue expected (Option.value_exn !pending);
      pending := None;
      if valid && ready then incr simultaneous);
    let before = !(o.event_o) in
    finish_cycle sim;
    if (not active) && not reset
    then
      check
        (Bits.equal before !((Cyclesim.outputs sim).event_o))
        "event changed while disabled"
  done;
  check (Queue.is_empty expected && Option.is_none !pending) "events failed to drain";
  check
    (!full > 0 && !simultaneous > 0 && !outputs > 1000)
    "insufficient event FIFO coverage";
  printf "PASS: event FIFO depth=%d (%d events)\n" depth !outputs
;;

type byte =
  { value : char
  ; first : bool
  ; last : bool
  ; offset : int
  ; timestamp : Bits.t
  }

let test_aligner () =
  let module S = Cyclesim.With_interface (Byte_aligner.I) (Byte_aligner.O) in
  let sim = S.create (Byte_aligner.create (scope ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs ~clock_edge:Before sim in
  Byte_aligner.I.iter2 i Byte_aligner.I.port_widths ~f:(fun r w -> r := Bits.zero w);
  let source = packets () in
  let todo, pending = ref source, ref None in
  let expected = Queue.create () in
  let input_offset = ref 0 in
  let current_timestamp = ref (Bits.zero 64) in
  let offsets = Array.create ~len:8 false in
  let counts = Array.create ~len:9 false in
  let saw_full, saw_two_pop, saw_boundary_block = ref false, ref false, ref false in
  let cycle, consumed = ref 0, ref 0 in
  while
    !cycle < 200000
    && (!cycle < 302
        || not (List.is_empty !todo && Option.is_none !pending && Queue.is_empty expected)
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
    i.data_i := offered.data;
    i.keep_i := int 8 offered.keep;
    i.first_i := Bits.of_bool offered.first;
    i.last_i := Bits.of_bool offered.last;
    i.ingress_timestamp_i := if offered.first then offered.timestamp else int 64 !cycle;
    i.valid_i := Bits.of_bool (Option.is_some !pending);
    i.reset_i := Bits.of_bool reset;
    i.en_i := Bits.of_bool enabled;
    let rec current_packet = function
      | [] -> []
      | b :: rest -> b :: (if b.last then [] else current_packet rest)
    in
    let window = current_packet (Queue.to_list expected) in
    let available = List.length window in
    let request = Random.State.int random (1 + Int.min 8 available) in
    let command_valid = !cycle >= 60 && not (chance 3) in
    i.consume_count_i := int 4 request;
    i.consume_valid_i := Bits.of_bool command_valid;
    Cyclesim.cycle_before_clock_edge sim;
    let active = enabled && not reset in
    if not reset
    then
      check
        (get o.available_o = available)
        (sprintf
           "aligner available byte count cycle=%d actual=%d expected=%d"
           !cycle
           (get o.available_o)
           available);
    check (Bool.equal (is_set o.valid_o) (active && available > 0)) "aligner valid";
    if not reset
    then
      check
        (Bool.equal (is_set o.boundary_o) (List.exists window ~f:(fun b -> b.last)))
        "aligner boundary lookahead";
    check
      (Bool.equal (is_set o.consume_ready_o) (active && available > 0))
      "legal consume readiness";
    if not active then check (not (is_set o.ready_o)) "disabled aligner input handshake";
    List.iteri window ~f:(fun lane b ->
      let actual =
        Bits.select !(o.data_o) ~high:((lane * 8) + 7) ~low:(lane * 8)
        |> Bits.to_int_trunc
      in
      check
        (actual = Char.to_int b.value)
        "aligner byte window corrupted or borrowed next packet");
    if (not reset) && available < 16
    then
      check
        (Bits.equal
           (Bits.select !(o.data_o) ~high:127 ~low:(available * 8))
           (Bits.zero (128 - (available * 8))))
        "aligner exposed invalid lanes";
    Option.iter (List.hd window) ~f:(fun b ->
      check (Bool.equal (is_set o.first_o) b.first) "aligner first marker";
      check (get o.packet_byte_offset_o = b.offset) "accepted-byte offset";
      check (Bits.equal !(o.ingress_timestamp_o) b.timestamp) "aligner packet context";
      offsets.(b.offset land 7) <- true);
    if available = 16 then saw_full := true;
    if available < Queue.length expected then saw_boundary_block := true;
    if command_valid && is_set o.consume_ready_o
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
    if Option.is_some !pending && is_set o.ready_o
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
          });
      input_offset := !input_offset + String.length s;
      todo := List.tl_exn !todo;
      pending := None);
    let held_offset, held_data = !(o.packet_byte_offset_o), !(o.data_o) in
    finish_cycle sim;
    let after = Cyclesim.outputs sim in
    if (not reset) && ((not active) || (not command_valid) || request = 0)
    then
      check
        (Bits.equal held_offset !(after.packet_byte_offset_o))
        "offset advanced without consuming";
    if (not active) && not reset
    then check (Bits.equal held_data !(after.data_o)) "aligner changed during disable";
    incr cycle
  done;
  check (!cycle < 200000 && Queue.is_empty expected) "aligner timed out";
  check
    (Array.for_all offsets ~f:Fn.id && Array.for_all counts ~f:Fn.id)
    "missing alignments or consume counts";
  check
    (!saw_full && !saw_two_pop && !saw_boundary_block)
    "missing two-beat or packet-boundary coverage";
  printf
    "PASS: aligner offsets 0..7, consumes 0..8, two-beat retirement, packet isolation \
     (%d bytes)\n"
    !consumed
;;

let test_invalid_depths () =
  List.iter [ 0; -1 ] ~f:(fun depth ->
    let module C = Circuit.With_interface (Event_fifo.I) (Event_fifo.O) in
    check
      (try
         ignore
           (C.create_exn ~name:"invalid" (Event_fifo.create ~depth (scope ()))
            : Circuit.t);
         false
       with
       | Invalid_argument _ -> true)
      "invalid storage depth accepted")
;;

let test_consume_limits () =
  let module S = Cyclesim.With_interface (Byte_aligner.I) (Byte_aligner.O) in
  let sim = S.create (Byte_aligner.create (scope ())) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs ~clock_edge:Before sim in
  Byte_aligner.I.iter2 i Byte_aligner.I.port_widths ~f:(fun r w -> r := Bits.zero w);
  i.reset_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  i.en_i := Bits.vdd;
  i.valid_i := Bits.vdd;
  i.data_i := Bits.of_string "64'hffffffff00636261";
  i.keep_i := int 8 7;
  i.first_i := Bits.vdd;
  i.last_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.valid_i := Bits.gnd;
  i.consume_valid_i := Bits.vdd;
  List.iter [ 4; 8; 9; 15; 0; 3 ] ~f:(fun count ->
    i.consume_count_i := int 4 count;
    Cyclesim.cycle_before_clock_edge sim;
    check
      (get o.available_o = 3 && get o.packet_byte_offset_o = 0)
      "rejected/zero consume advanced state";
    check
      (Bool.equal (is_set o.consume_ready_o) (count <= 3))
      "out-of-range consume acknowledged";
    check
      (Bits.equal !(o.data_o) (Bits.of_string "128'h636261"))
      "partial final keep ignored";
    finish_cycle sim);
  Cyclesim.cycle_before_clock_edge sim;
  check
    ((not (is_set o.valid_o)) && get o.available_o = 0)
    "final consume did not retire packet";
  finish_cycle sim
;;

let () =
  test_monitor ();
  test_invalid_depths ();
  test_consume_limits ();
  List.iter [ 1; 2; 3; 64 ] ~f:(fun depth ->
    test_stream ~depth ~pass:false ~continuous:false ~shim_gaps:false ~resets:true);
  List.iter [ 1; 2; 3; 16 ] ~f:test_events;
  test_aligner ();
  List.iter [ 1; 3; 64 ] ~f:(fun depth ->
    test_stream ~depth ~pass:true ~continuous:false ~shim_gaps:false ~resets:true;
    test_stream ~depth ~pass:true ~continuous:true ~shim_gaps:false ~resets:false);
  test_stream ~depth:3 ~pass:true ~continuous:false ~shim_gaps:true ~resets:true;
  print_endline "PASS: CME Phase 1 streaming foundation (reproducible seed 0x434d45, 1)"
;;
