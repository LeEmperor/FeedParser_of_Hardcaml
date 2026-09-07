(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "byte_aligner_invariant_tests.ml" *)
(* slot0_bytes / slot1_bytes must never diverge from byte_count of their slot's keep.

   The aligner registers these counts alongside the slots so the priority encoder stays
   off the critical path. That is only sound while the count registers mirror
   next_slot0 / next_slot1 exactly. A divergence silently mis-sizes the peek window and
   is invisible at the port boundary until a specific beat pattern hits it, so this
   suite probes the internal nodes directly and asserts the invariant on every cycle.

   Tags: [{ "ACTIVE" ; "TEST" ; "INVARIANT" ; "BYTE_ALIGNER" }]
*)

open! Core
open! Hardcaml
open Cme_of_hardcaml
module Sim = Cyclesim.With_interface (Byte_aligner.I) (Byte_aligner.O)

(* Packed Ingress_beat layout: [63:0] data, [71:64] keep, [72] first, [73] last,
   [137:74] ingress_timestamp. Only the keep field matters here. *)
let keep_high = 71
let keep_low = 64
let traced = [ "slot0"; "slot1"; "slot0_bytes"; "slot1_bytes" ]

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
  Sim.create ~config (Byte_aligner.create scope)
;;

let node sim name =
  match Cyclesim.lookup_node_or_reg_by_name sim name with
  | Some n -> n
  | None ->
    raise_s
      [%message "internal signal is not traced; did the -- name change?" (name : string)]
;;

(* Independent model of Byte_aligner.byte_count: index of the highest set bit, plus one.
   Deliberately written from the spec rather than reusing the RTL function, so a change
   to either side shows up here. *)
let byte_count_model keep =
  let rec go n acc =
    if n >= 8 then acc else go (n + 1) (if keep land (1 lsl n) <> 0 then n + 1 else acc)
  in
  go 0 0
;;

let check_invariant ~cycle sim ~slot ~count =
  let slot_bits = Cyclesim.Node.to_bits (node sim slot) in
  let keep =
    Bits.to_int_trunc (Bits.select slot_bits ~high:keep_high ~low:keep_low)
  in
  let expect = byte_count_model keep in
  let actual = Bits.to_int_trunc (Cyclesim.Node.to_bits (node sim count)) in
  if actual <> expect
  then
    raise_s
      [%message
        "registered byte count diverged from byte_count of its slot's keep mask"
          (cycle : int)
          (slot : string)
          (count : string)
          (keep : int)
          ~expected:(expect : int)
          ~got:(actual : int)]
;;

(* Contiguous low-lane masks are the aligner's stated input contract. *)
let contiguous_keep_gen = Int.gen_incl 0 8 |> Quickcheck.Generator.map ~f:(fun n ->
  (1 lsl n) - 1)

let bool_gen = Quickcheck.Generator.map (Int.gen_incl 0 1) ~f:(fun n -> n = 1)

type stimulus =
  { keep : int
  ; valid : bool
  ; first : bool
  ; last : bool
  ; consume_valid : bool
  ; consume_count : int
  ; en : bool
  }

let stimulus_gen =
  let open Quickcheck.Generator.Let_syntax in
  let%map keep = contiguous_keep_gen
  and valid = bool_gen
  and first = bool_gen
  and last = bool_gen
  and consume_valid = bool_gen
  and consume_count = Int.gen_incl 0 15
  and en = Quickcheck.Generator.weighted_union [ 9., return true; 1., return false ] in
  { keep; valid; first; last; consume_valid; consume_count; en }
;;

let run_trace ~seed ~cycles =
  let sim = create_sim () in
  let i = Cyclesim.inputs sim in
  let random = Splittable_random.of_int seed in
  i.reset_i := Bits.vdd;
  i.en_i := Bits.vdd;
  Cyclesim.cycle sim;
  check_invariant ~cycle:0 sim ~slot:"slot0" ~count:"slot0_bytes";
  check_invariant ~cycle:0 sim ~slot:"slot1" ~count:"slot1_bytes";
  i.reset_i := Bits.gnd;
  for cycle = 1 to cycles do
    let s =
      Quickcheck.Generator.generate stimulus_gen ~size:8 ~random
    in
    i.data_i := Bits.random ~width:64;
    i.keep_i := Bits.of_int_trunc ~width:8 s.keep;
    i.first_i := Bits.of_bool s.first;
    i.last_i := Bits.of_bool s.last;
    i.ingress_timestamp_i := Bits.random ~width:64;
    i.valid_i := Bits.of_bool s.valid;
    i.consume_valid_i := Bits.of_bool s.consume_valid;
    i.consume_count_i := Bits.of_int_trunc ~width:4 s.consume_count;
    i.en_i := Bits.of_bool s.en;
    Cyclesim.cycle sim;
    check_invariant ~cycle sim ~slot:"slot0" ~count:"slot0_bytes";
    check_invariant ~cycle sim ~slot:"slot1" ~count:"slot1_bytes"
  done
;;

let%test_unit "slot byte counts mirror byte_count of their slot keep under random traffic" =
  Quickcheck.test
    ~trials:8
    ~seed:(`Deterministic "byte-aligner-count-mirror")
    ~sexp_of:[%sexp_of: int]
    ~shrinker:Int.quickcheck_shrinker
    (Int.gen_incl 1 100000)
    ~f:(fun seed -> run_trace ~seed ~cycles:400)
;;

let%test_unit "invariant holds across reset while slots are occupied" =
  let sim = create_sim () in
  let i = Cyclesim.inputs sim in
  i.en_i := Bits.vdd;
  i.reset_i := Bits.gnd;
  (* Fill both slots with full beats. *)
  i.keep_i := Bits.of_int_trunc ~width:8 0xff;
  i.valid_i := Bits.vdd;
  i.first_i := Bits.vdd;
  for _ = 1 to 4 do
    Cyclesim.cycle sim;
    i.first_i := Bits.gnd
  done;
  check_invariant ~cycle:4 sim ~slot:"slot0" ~count:"slot0_bytes";
  check_invariant ~cycle:4 sim ~slot:"slot1" ~count:"slot1_bytes";
  (* Reset must clear slots and counts together: byte_count 0 = 0. *)
  i.reset_i := Bits.vdd;
  Cyclesim.cycle sim;
  check_invariant ~cycle:5 sim ~slot:"slot0" ~count:"slot0_bytes";
  check_invariant ~cycle:5 sim ~slot:"slot1" ~count:"slot1_bytes";
  [%test_result: int]
    (Bits.to_int_trunc (Cyclesim.Node.to_bits (node sim "slot0_bytes")))
    ~expect:0
;;
