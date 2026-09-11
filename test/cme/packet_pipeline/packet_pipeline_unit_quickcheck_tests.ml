(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "packet_pipeline_unit_quickcheck_tests.ml" *)
(* Independent packet/sequence expectations, boundary controls, and seeded stress. *)

open! Core
open Packet_pipeline_testbench

let%test_unit "literal little-endian header and high-bit timestamp" =
  let payload = "\x78\x56\x34\x12\xef\xcd\xab\x89\x67\x45\x23\x81abcde" in
  let o = run ~stalls:false [ { payload; timestamp = 0xffff_ffff_ffff_ffffL } ] in
  [%test_result: Item.t list]
    o.items
    ~expect:
      [ Start
          ( { timestamp = -1L
            ; seq = 0x1234_5678L
            ; sending_time = 0x8123_4567_89ab_cdefL
            ; header_present = true
            ; channel_valid = true
            }
          , "abcde"
          , true )
      ]
;;

let%test_unit "every short payload and body tail, header-only, no packet contamination" =
  let packets =
    List.init 11 ~f:(fun i -> short (i + 1))
    @ List.init 81 ~f:(fun i ->
      packet
        (Int64.of_int i)
        (String.init i ~f:(fun j -> Char.of_int_exn (((j * 29) + i) land 255))))
  in
  List.iter [ run; Small.run; Tiny.run ] ~f:(fun run ->
    let o = run ~sink_block_until:90 packets in
    assert (o.output_stalls > 0);
    assert (List.length o.items > 90))
;;

let%test_unit "initialization, gap validity persists, duplicate/late, wrap and half range"
  =
  let sequences = [ 0xffff_fffeL; 0xffff_ffffL; 0L; 3L; 3L; 2L; 4L; 0x8000_0005L; 5L ] in
  let o = run (List.map sequences ~f:(fun seq -> packet seq "123456789abcdef")) in
  let diagnostics =
    List.filter_map o.items ~f:(function
      | Diagnostic (_, code, expected, _) -> Some (code, expected)
      | _ -> None)
  in
  [%test_result: (int * int64 option) list]
    diagnostics
    ~expect:[ 1, Some 1L; 2, Some 4L; 2, Some 4L; 2, Some 5L ];
  let validity =
    List.filter_map o.items ~f:(function
      | Start (c, _, _) -> Some c.channel_valid
      | _ -> None)
  in
  [%test_result: bool list] validity ~expect:[ true; true; true; false; false; false ]
;;

let%test_unit "short header after a gap snapshots invalidity without sequence advance" =
  let o = run [ packet 10L ""; packet 12L ""; short 7; packet 13L "" ] in
  assert (
    List.exists o.items ~f:(function
      | Diagnostic (c, 3, None, 7) ->
        (not c.channel_valid) && (not c.header_present) && Int64.equal c.seq 0L
      | _ -> false))
;;

let%test_unit "quiescent control wins simultaneous first, session reset wins resync" =
  let o =
    run
      ~stalls:false
      ~controls:[ control ~session_reset:true ~resync:999L 0 ]
      [ packet 42L "" ]
  in
  [%test_result: int list] (List.map o.controls ~f:snd) ~expect:[ 0 ];
  assert (
    List.for_all o.items ~f:(function
      | Start (c, _, _) -> c.channel_valid
      | _ -> false))
;;

let%test_unit "resync establishes expected value before first packet" =
  let o =
    run
      ~controls:[ control ~resync:100L 0 ]
      [ packet 99L "dropped"; packet 100L "ok"; packet 103L "gap" ]
  in
  [%test_result: int list]
    (List.filter_map o.items ~f:(function
      | Diagnostic (_, code, _, _) -> Some code
      | _ -> None))
    ~expect:[ 2; 1 ]
;;

let%test_unit "busy fence completes open packet, blocks next first, waits on downstream" =
  let first = packet 50L (String.make 160 'a') in
  let o =
    Tiny.run
      ~stalls:false
      ~sink_block_until:80
      ~downstream_busy_until:180
      ~controls:[ control ~resync:90L 1 ]
      [ first; packet 90L "next" ]
  in
  [%test_result: int list] (List.map o.controls ~f:snd) ~expect:[ 22 ];
  assert (List.for_all o.controls ~f:(fun (cycle, _) -> cycle >= 180));
  assert (o.input_stalls > 0 && o.output_stalls > 0)
;;

let%test_unit "busy pulse is not latched" =
  let o =
    Tiny.run
      ~stalls:false
      ~controls:[ control ~resync:900L ~pulse:true 1 ]
      [ packet 20L (String.make 100 'x'); packet 21L "ok" ]
  in
  assert (List.is_empty o.controls);
  assert (
    List.for_all o.items ~f:(function
      | Diagnostic _ -> false
      | _ -> true))
;;

let%test_unit "session reset restores baseline after gap and queued diagnostics drain" =
  let o =
    run
      ~stalls:false
      ~sink_block_until:100
      ~controls:[ control ~session_reset:true 4 ]
      [ packet 1L ""; packet 4L ""; packet 0L "reset" ]
  in
  [%test_result: int list] (List.map o.controls ~f:snd) ~expect:[ 4 ];
  assert (List.for_all o.controls ~f:(fun (cycle, _) -> cycle > 100));
  assert (
    List.exists o.items ~f:(function
      | Start (c, "reset", _) -> c.channel_valid
      | _ -> false))
;;

let%test_unit "reset while disabled cancels header, body, gap and duplicate work" =
  List.iter [ 2; 4; 8; 20; 40 ] ~f:(fun reset_at ->
    let o =
      Tiny.run
        ~stalls:false
        ~reset_at
        ~sink_block_until:70
        [ packet 5L ""; packet 7L (String.make 240 'g'); packet 7L "dup"; packet 8L "ok" ]
    in
    assert o.cancelled_work)
;;

let%test_unit "seeded packet and sequence stress with bubbles, pauses and stalls" =
  Quickcheck.test
    ~trials:30
    ~seed:(`Deterministic "phase2-canonical-packets")
    ~sexp_of:[%sexp_of: int]
    ~shrinker:Int.quickcheck_shrinker
    (Int.gen_incl 1 100000)
    ~f:(fun seed ->
      let random = Random.State.make [| seed |] in
      let seq = ref 0xffff_fff0L in
      let packets =
        List.init 70 ~f:(fun _ ->
          let n = Random.State.int random 12 in
          if n = 0
          then short (1 + Random.State.int random 11)
          else (
            let observed =
              match n with
              | 1 -> wrap Int64.(!seq - 1L)
              | 2 -> wrap Int64.(!seq + 3L)
              | 3 -> wrap Int64.(!seq + 0x8000_0000L)
              | _ -> !seq
            in
            if n <> 1 && n <> 3 then seq := wrap Int64.(observed + 1L);
            packet
              ~timestamp:(Int64.of_int (Random.State.int random 100000))
              observed
              (String.init (Random.State.int random 257) ~f:(fun _ ->
                 Char.of_int_exn (Random.State.int random 256)))))
      in
      ignore (Small.run ~seed packets : Observation.t))
;;

let%test_unit "eight-byte short header cannot borrow a buffered following packet" =
  let o = run ~stalls:false ~sink_block_until:50 [ short 8; packet 123L "next" ] in
  [%test_result: int] (List.length o.items) ~expect:2;
  assert (
    List.exists o.items ~f:(function
      | Diagnostic (_, 3, None, 8) -> true
      | _ -> false));
  assert (
    List.exists o.items ~f:(function
      | Start (c, "next", true) -> Int64.equal c.seq 123L && c.channel_valid
      | _ -> false))
;;

let%test_unit "split header with Arty byte-source-like gaps" =
  ignore
    (Tiny.run
       ~stalls:false
       ~beat_gap:7
       [ short 8; short 9; short 11; packet 0xffff_ffffL ""; packet 0L "abcdefghi" ]
     : Observation.t)
;;

let%test_unit "resync recovers validity after gap" =
  let o =
    run
      ~stalls:false
      ~controls:[ control ~resync:100L 4 ]
      [ packet 1L ""; packet 4L ""; packet 100L "back" ]
  in
  assert (
    List.exists o.items ~f:(function
      | Start (c, "back", _) -> c.channel_valid
      | _ -> false));
  [%test_result: int] (List.length o.controls) ~expect:1
;;

let%test_unit "fence waits for complete long duplicate drain" =
  let o =
    Tiny.run
      ~stalls:false
      ~sink_stall_windows:[ 8, 60 ]
      ~controls:[ control ~resync:90L 3 ]
      [ packet 50L ""; packet 50L (String.make 256 'd'); packet 90L "next" ]
  in
  [%test_result: int list] (List.map o.controls ~f:snd) ~expect:[ 36 ];
  [%test_result: int]
    (List.count o.items ~f:(function
      | Diagnostic (_, 2, _, _) -> true
      | _ -> false))
    ~expect:1
;;

let%test_unit "reset cancels stalled sequence diagnostics and admitted body" =
  List.iter [ 5L; 7L ] ~f:(fun seq ->
    List.iter [ 8; 10 ] ~f:(fun stall_start ->
      let o =
        Tiny.run
          ~stalls:false
          ~sink_stall_windows:[ stall_start, 50 ]
          ~reset_at:20
          [ packet 5L ""; packet seq (String.make 120 'x'); packet 8L "next" ]
      in
      assert o.cancelled_work))
;;

let%test_unit "bounded storage admits body cut-through before UDP last" =
  let o =
    Tiny.run
      ~stalls:false
      [ packet 0L (String.init 4096 ~f:(fun n -> Char.of_int_exn (n land 255))) ]
  in
  assert o.cut_through;
  [%test_result: int] (List.length o.items) ~expect:512
;;

let%test_unit "canonical packed ABI and complete portable hierarchy" =
  let open Hardcaml in
  let open Cme_of_hardcaml in
  let module P = Packet_pipeline in
  let module C = Circuit.With_interface (P.I) (P.O) in
  let scope = Scope.create ~flatten_design:false () in
  let circuit = C.create_exn ~name:"packet_wrapper" (P.create scope) in
  [%test_result: int] (List.length (Circuit.instantiations circuit)) ~expect:3;
  [%test_result: int] Cme_types.packet_item_width ~expect:917;
  List.iter (P.I.to_list P.I.port_names) ~f:(fun name ->
    assert (String.is_suffix name ~suffix:"_i"));
  List.iter (P.O.to_list P.O.port_names) ~f:(fun name ->
    assert (String.is_suffix name ~suffix:"_o"));
  let rtl =
    Rtl.create ~database:(Scope.circuit_database scope) Verilog [ circuit ]
    |> Rtl.full_hierarchy
    |> Rope.to_string
  in
  List.iter
    [ "cme_ingress_fifo"
    ; "cme_byte_aligner"
    ; "cme_packet_header"
    ; "cme_single_feed_sequencer"
    ]
    ~f:(fun name -> assert (String.is_substring rtl ~substring:("module " ^ name ^ " (")))
;;
