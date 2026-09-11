(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "ingress_fifo.ml" *)
(* UDP beat elasticity. Timestamp is sampled with accepted first beats and stored as zero
   on all other entries. No packet context is shared between buffered packets.
*)

open! Hardcaml

module I = struct
  type 'a t =
    { (* Application clock; synchronous reset overrides enable. *)
      clock_i : 'a
    ; reset_i : 'a
    ; en_i : 'a
    ; (* Trusted, low-byte-first UDP payload. *)
      data_i : 'a [@bits 64]
    ; keep_i : 'a [@bits 8]
    ; first_i : 'a
    ; last_i : 'a
    ; ingress_timestamp_i : 'a [@bits 64]
    ; valid_i : 'a
    ; ready_i : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { ready_o : 'a
    ; valid_o : 'a
    ; data_o : 'a [@bits 64]
    ; keep_o : 'a [@bits 8]
    ; first_o : 'a
    ; last_o : 'a
    ; ingress_timestamp_o : 'a [@bits 64]
    }
  [@@deriving hardcaml]
end

let create
  ?(depth = Cme_config.default.ingress_fifo_depth)
  (* extra feature for ready checking on pipeline depths *)
  ?(greedy_admission = false)
  scope
  (i : _ I.t)
  =
  let item : _ Cme_types.Ingress_beat.t =
    { beat = { data = i.data_i; keep = i.keep_i; first = i.first_i; last = i.last_i }
    ; ingress_timestamp = Signal.mux2 i.first_i i.ingress_timestamp_i (Signal.zero 64)
    }
  in
  let fifo =
    Elastic_fifo.create
      ~depth
      ~greedy_admission
      scope
      ~clock:i.clock_i
      ~reset:i.reset_i
      ~en:i.en_i
      ~data:(Cme_types.Ingress_beat.Of_signal.pack item)
      ~valid:i.valid_i
      ~ready:i.ready_i
  in
  let item = Cme_types.Ingress_beat.Of_signal.unpack fifo.data in
  { O.ready_o = fifo.ready
  ; valid_o = fifo.valid
  ; data_o = item.beat.data
  ; keep_o = item.beat.keep
  ; first_o = item.beat.first
  ; last_o = item.beat.last
  ; ingress_timestamp_o = item.ingress_timestamp
  }
;;

let hierarchical
  ?(depth = Cme_config.default.ingress_fifo_depth)
  ?(greedy_admission = false)
  ?instance
  scope
  i
  =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical
    ?instance
    ~name:"cme_ingress_fifo"
    ~scope
    (create ~depth ~greedy_admission)
    i
;;
