(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "packet_header_invariant_tests.ml" *)
(* The consume request handed to the aligner must fit its four-bit port, and the aligner
   must always be able to honour it.

   [consume_count] is narrowed from the five-bit [request_bytes] with a plain uresize,
   which selects the low bits and says nothing. Nothing can reach sixteen on that path
   today - [required] is twelve, [body_count] is capped at eight, and the bare
   [available_o] arm is reachable only under [~enough] - but that argument is spread over
   three separate signals in two modules, and the failure it guards against is silent at
   the port boundary. So it is asserted on the internal node every cycle instead.

   The second invariant is the one that lets packet_header ignore [consume_ready_o]
   entirely: it assumes the aligner accepts every request it makes. That holds only while
   the count stays nonzero and within [available_o]. Violating it stalls the stage rather
   than corrupting it, which is the safer failure but not a loud one.

   Coverage is asserted too, because both invariants are trivially true on a stimulus that
   never reaches the interesting arms: the suite fails unless it saw a full twelve-byte
   grab, a short-header grab, a full body beat and a short tail beat.

   Tags: [{ "ACTIVE" ; "TEST" ; "INVARIANT" ; "PACKET_HEADER" }]
*)

open! Core
open! Hardcaml
open Cme_of_hardcaml
module Sim = Cyclesim.With_interface (Packet_header.I) (Packet_header.O)

(* [available] lives inside the aligner instance; the rest are packet_header's own. All
   are plain [--] names, so they survive flattening unmangled. *)
let request_bytes = "packet_header_request_bytes"
let consume_count = "packet_header_consume_count"
let consume_valid = "packet_header_consume_valid"
let state = "packet_header_state"
let available = "available"
let traced = [ request_bytes; consume_count; consume_valid; state; available ]

(* Binary encoding follows State.all, which is declaration order. *)
let collecting = 0
let body = 1

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
  Sim.create ~config (Packet_header.create scope)
;;

let node sim name =
  match Cyclesim.lookup_node_or_reg_by_name sim name with
  | Some n -> n
  | None ->
    let seen =
      (Cyclesim.traced sim).internal_signals
      |> List.concat_map ~f:(fun (s : Cyclesim.Traced.internal_signal) -> s.mangled_names)
    in
    raise_s
      [%message
        "probe is not traced; did the -- name change?"
          (name : string)
          (seen : string list)]
;;

let value n = Bits.to_int_trunc (Cyclesim.Node.to_bits n)

module Coverage = struct
  type t =
    { mutable header_full : int (* twelve-byte grab with the whole header visible *)
    ; mutable header_short : int (* boundary reached before twelve bytes *)
    ; mutable body_full : int (* a full eight-byte body beat *)
    ; mutable body_tail : int (* the short final beat of a packet *)
    ; mutable consumes : int
    }

  let create () =
    { header_full = 0; header_short = 0; body_full = 0; body_tail = 0; consumes = 0 }
  ;;
end

(* Called between cycle_before_clock_edge and cycle_at_clock_edge, so these are exactly
   the values the aligner sees this cycle. *)
let check ~cycle ~(cov : Coverage.t) probes =
  let req, cnt, vld, st, avail = probes in
  if value vld = 1
  then (
    let req = value req
    and cnt = value cnt
    and st = value st
    and avail = value avail in
    let fail message =
      raise_s
        [%message
          message
            (cycle : int)
            ~request_bytes:(req : int)
            ~consume_count:(cnt : int)
            ~state:(st : int)
            ~available:(avail : int)]
    in
    (* The narrowing uresize dropped a bit. *)
    if cnt <> req then fail "consume_count is not request_bytes; the uresize truncated";
    if req > 12 then fail "request exceeds the twelve-byte bound";
    (* packet_header never reads consume_ready_o, so every request must be acceptable. *)
    if cnt = 0
    then fail "zero-byte request; the aligner will refuse it and the stage hangs";
    if cnt > avail then fail "request exceeds available; the aligner will refuse it";
    cov.consumes <- cov.consumes + 1;
    if st = collecting
    then
      if cnt = 12
      then cov.header_full <- cov.header_full + 1
      else cov.header_short <- cov.header_short + 1
    else if st = body
    then
      if cnt = 8
      then cov.body_full <- cov.body_full + 1
      else cov.body_tail <- cov.body_tail + 1)
;;

type beat =
  { data : int64
  ; keep : int
  ; first : bool
  ; last : bool
  }

(* Packet lengths chosen to land on every arm: under twelve is the truncated diagnostic,
   exactly twelve is the header-only marker, and the rest carry a body whose final beat is
   usually short. *)
let length_gen =
  Quickcheck.Generator.weighted_union
    [ 1., Int.gen_incl 1 11
    ; 1., Quickcheck.Generator.return 12
    ; 1., Int.gen_incl 13 20
    ; 2., Int.gen_incl 21 64
    ]
;;

let beats_of ~random ~len =
  let n = (len + 7) / 8 in
  List.init n ~f:(fun k ->
    let bytes = Int.min 8 (len - (k * 8)) in
    { data = Splittable_random.int64 random ~lo:Int64.min_value ~hi:Int64.max_value
    ; keep = (1 lsl bytes) - 1
    ; first = k = 0
    ; last = k = n - 1
    })
;;

let bool_with random ~p = Float.( < ) (Splittable_random.float random ~lo:0. ~hi:1.) p

let run ~seed ~cycles =
  let sim = create_sim () in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs ~clock_edge:Before sim in
  let probes =
    ( node sim request_bytes
    , node sim consume_count
    , node sim consume_valid
    , node sim state
    , node sim available )
  in
  let cov = Coverage.create () in
  let random = Splittable_random.of_int seed in
  let pending = ref [] in
  let refill () =
    if List.is_empty !pending
    then (
      let len = Quickcheck.Generator.generate length_gen ~size:8 ~random in
      pending := beats_of ~random ~len)
  in
  i.reset_i := Bits.vdd;
  i.en_i := Bits.vdd;
  i.ready_i := Bits.vdd;
  Cyclesim.cycle sim;
  i.reset_i := Bits.gnd;
  for cycle = 1 to cycles do
    refill ();
    (* Random gaps on the way in and random backpressure on the way out, so the aligner is
       exercised both starved and full. *)
    let present = bool_with random ~p:0.85 in
    (match !pending with
     | b :: _ when present ->
       i.data_i := Bits.of_int64_trunc ~width:64 b.data;
       i.keep_i := Bits.of_int_trunc ~width:8 b.keep;
       i.first_i := Bits.of_bool b.first;
       i.last_i := Bits.of_bool b.last;
       i.ingress_timestamp_i := Bits.random ~width:64;
       i.valid_i := Bits.vdd
     | _ ->
       i.valid_i := Bits.gnd;
       i.first_i := Bits.gnd;
       i.last_i := Bits.gnd);
    i.ready_i := Bits.of_bool (bool_with random ~p:0.8);
    i.en_i := Bits.of_bool (bool_with random ~p:0.95);
    Cyclesim.cycle_check sim;
    Cyclesim.cycle_before_clock_edge sim;
    check ~cycle ~cov probes;
    let accepted = present && Bits.to_bool !(o.ready_o) in
    Cyclesim.cycle_at_clock_edge sim;
    Cyclesim.cycle_after_clock_edge sim;
    if accepted then pending := List.tl_exn !pending
  done;
  cov
;;

let%test_unit "consume requests stay inside the four-bit port and the aligner always \
               accepts them"
  =
  let cov = run ~seed:0x5eed ~cycles:4000 in
  (* A stimulus that never reached an arm would pass the invariants vacuously. *)
  if cov.header_full = 0
     || cov.header_short = 0
     || cov.body_full = 0
     || cov.body_tail = 0
     || cov.consumes < 500
  then
    raise_s
      [%message
        "stimulus did not reach every consume arm"
          ~header_full:(cov.header_full : int)
          ~header_short:(cov.header_short : int)
          ~body_full:(cov.body_full : int)
          ~body_tail:(cov.body_tail : int)
          ~consumes:(cov.consumes : int)]
;;

let%test_unit "invariants hold across a spread of seeds" =
  List.iter [ 1; 7; 13; 101; 9001 ] ~f:(fun seed ->
    ignore (run ~seed ~cycles:1500 : Coverage.t))
;;
