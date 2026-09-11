(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "stream_fixture.ml" *)
(* Byte-string sources, executable stream contract assertions, and a transport-only
   fixture. No fixture payload uses the public parser's normalized-event interface.
*)

open! Core
open! Hardcaml
open! Cme_of_hardcaml

type beat =
  { data : Bits.t
  ; keep : int
  ; first : bool
  ; last : bool
  ; timestamp : Bits.t
  }

let check condition message = if not condition then failwith message
let int width n = Bits.of_int_trunc ~width n
let is_set r = Bits.to_bool !r
let get r = Bits.to_int_trunc !r

let packet ?(timestamp = Bits.zero 64) bytes =
  let length = String.length bytes in
  check (length > 0) "empty UDP payload has no stream representation";
  List.init
    ((length + 7) / 8)
    ~f:(fun word ->
      let count = Int.min 8 (length - (word * 8)) in
      let data =
        List.init 8 ~f:(fun lane ->
          (* Poison invalid lanes to ensure consumers honor keep. *)
          int 8 (if lane < count then Char.to_int bytes.[(word * 8) + lane] else 0xa5))
        |> Bits.concat_lsb
      in
      { data
      ; keep = (1 lsl count) - 1
      ; first = word = 0
      ; last = (word * 8) + count = length
      ; timestamp
      })
;;

let bytes beat =
  List.init (Int.popcount beat.keep) ~f:(fun n ->
    Bits.select beat.data ~high:((n * 8) + 7) ~low:(n * 8)
    |> Bits.to_int_trunc
    |> Char.of_int_exn)
  |> String.of_char_list
;;

module Monitor = struct
  type t =
    { mutable open_packet : bool
    ; mutable stalled : beat option
    }

  let create () = { open_packet = false; stalled = None }

  let same a b =
    Bits.equal a.data b.data
    && a.keep = b.keep
    && Bool.equal a.first b.first
    && Bool.equal a.last b.last
    && ((not a.first) || Bits.equal a.timestamp b.timestamp)
  ;;

  let observe t ~reset ~active ~valid ~ready beat =
    if reset
    then (
      t.open_packet <- false;
      t.stalled <- None)
    else if active
    then (
      Option.iter t.stalled ~f:(fun old ->
        check (valid && same old beat) "stream changed while stalled");
      if valid
      then (
        check (beat.keep > 0 && beat.keep <= 255) "zero or oversized keep";
        check (beat.keep land (beat.keep + 1) = 0) "noncontiguous keep";
        check (beat.last || beat.keep = 255) "partial non-final beat";
        if ready
        then (
          check (Bool.equal beat.first (not t.open_packet)) "invalid first/last framing";
          t.open_packet <- not beat.last));
      t.stalled <- (if valid && not ready then Some beat else None))
  ;;
end

let drive (i : _ Ingress_fifo.I.t) beat ~valid =
  (* Exact Udp_rx_64_mac_top application mapping. app_start_o is intentionally absent. *)
  let app_tdata_o = beat.data in
  let app_tkeep_o = int 8 beat.keep in
  let app_tfirst_o = Bits.of_bool beat.first in
  let app_tlast_o = Bits.of_bool beat.last in
  let app_tvalid_o = Bits.of_bool valid in
  i.data_i := app_tdata_o;
  i.keep_i := app_tkeep_o;
  i.first_i := app_tfirst_o;
  i.last_i := app_tlast_o;
  i.valid_i := app_tvalid_o;
  i.ingress_timestamp_i := beat.timestamp
;;

let output (o : _ Ingress_fifo.O.t) =
  { data = !(o.data_o)
  ; keep = get o.keep_o
  ; first = is_set o.first_o
  ; last = is_set o.last_o
  ; timestamp = !(o.ingress_timestamp_o)
  }
;;

let finish_cycle sim =
  Cyclesim.cycle_at_clock_edge sim;
  Cyclesim.cycle_after_clock_edge sim
;;

module Pass_through = struct
  module I = Ingress_fifo.I
  module O = Ingress_fifo.O

  let create ?(depth = Cme_config.default.ingress_fifo_depth) scope (i : _ I.t) =
    let open Signal in
    let aligner_ready = wire 1 in
    let fifo =
      Ingress_fifo.hierarchical
        ~depth
        ~instance:"ingress"
        scope
        { i with ready_i = aligner_ready }
    in
    let consume_valid = wire 1 in
    let consume_count = wire 4 in
    let aligned =
      Byte_aligner.hierarchical
        ~instance:"aligner"
        scope
        { clock_i = i.clock_i
        ; reset_i = i.reset_i
        ; en_i = i.en_i
        ; data_i = fifo.data_o
        ; keep_i = fifo.keep_o
        ; first_i = fifo.first_o
        ; last_i = fifo.last_o
        ; ingress_timestamp_i = fifo.ingress_timestamp_o
        ; valid_i = fifo.valid_o
        ; consume_valid_i = consume_valid
        ; consume_count_i = consume_count
        }
    in
    aligner_ready <-- aligned.ready_o;
    let complete = aligned.available_o >=:. 8 |: aligned.boundary_o in
    let valid = aligned.valid_o &: complete in
    let count =
      mux2
        (aligned.available_o >=:. 8)
        (of_int_trunc ~width:4 8)
        (uresize aligned.available_o ~width:4)
    in
    consume_count <-- count;
    consume_valid <-- (valid &: i.ready_i);
    { O.ready_o = fifo.ready_o
    ; valid_o = valid
    ; data_o = sel_bottom aligned.data_o ~width:64
    ; keep_o = mux count (List.init 9 ~f:(fun n -> of_int_trunc ~width:8 ((1 lsl n) - 1)))
    ; first_o = aligned.first_o
    ; last_o = aligned.boundary_o &: (aligned.available_o <=:. 8)
    ; ingress_timestamp_o = aligned.ingress_timestamp_o
    }
  ;;
end
