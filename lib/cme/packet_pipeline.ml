(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "packet_pipeline.ml" *)
(* Ingress, header peel, and sequencer composition for the canonical packet seam.
   downstream_idle_i must include all later contexts and queued events. *)

open! Hardcaml
open Signal

module I = struct
  type 'a t =
    { (* Application domain; synchronous reset overrides the shared enable pause. *)
      clock_i : 'a
    ; reset_i : 'a
    ; en_i : 'a
    ; (* Framed low-byte-first UDP payload; timestamp is sampled on first only. *)
      data_i : 'a [@bits 64]
    ; keep_i : 'a [@bits 8]
    ; first_i : 'a
    ; last_i : 'a
    ; ingress_timestamp_i : 'a [@bits 64]
    ; valid_i : 'a
    ; (* Consumer of the packed canonical packet stream. *)
      ready_i : 'a
    ; (* Includes downstream contexts, diagnostics, and all queued output events. *)
      downstream_idle_i : 'a
    ; session_reset_i : 'a
    ; resync_valid_i : 'a
    ; resync_next_seq_i : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { ready_o : 'a
    ; valid_o : 'a
    ; (* Cme_types.Packet_item packed in declaration order. *)
      item_o : 'a [@bits Cme_types.packet_item_width]
    ; control_ready_o : 'a
    }
  [@@deriving hardcaml]
end

[@@@ocamlformat "disable"]
let create ?(config = Cme_config.default) scope (i : _ I.t) =
  (* spec *)
  let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in

  (* config elab config *)
  Cme_config.validate config;

  let input_open = wire 1 in

  (* direct derives *)
  let request = i.session_reset_i |: i.resync_valid_i in
  let allow = ~:request |: input_open in

  (* hanger ties *)
  let header_ready, sequence_ready = wire 1, wire 1 in

  let fifo =
    Ingress_fifo.hierarchical
      ~depth:config.ingress_fifo_depth
      scope
      { clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; en_i = i.en_i
      ; data_i = i.data_i
      ; keep_i = i.keep_i
      ; first_i = i.first_i
      ; last_i = i.last_i
      ; ingress_timestamp_i = i.ingress_timestamp_i
      ; valid_i = i.valid_i &: allow
      ; ready_i = header_ready
      }
  in

  (* propagate the backpressure *)
  let ready = fifo.ready_o &: allow in
  input_open <-- Signal.reg spec ~enable:(ready &: i.valid_i) ~:(i.last_i);

  let header =
    Packet_header.hierarchical
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
      ; ready_i = sequence_ready
      }
  in

  header_ready <-- header.ready_o;

  let sequencer =
    Single_feed_sequencer.hierarchical
      scope
      { clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; en_i = i.en_i
      ; item_i = header.item_o
      ; valid_i = header.valid_o
      ; ready_i = i.ready_i
      ; quiescent_i =
          ~:input_open &: ~:(fifo.valid_o) &: header.idle_o &: i.downstream_idle_i
      ; session_reset_i = i.session_reset_i
      ; resync_valid_i = i.resync_valid_i
      ; resync_next_seq_i = i.resync_next_seq_i
      }
  in

  sequence_ready <-- sequencer.ready_o;

  { O.ready_o = ready
  ; valid_o = sequencer.valid_o
  ; item_o = sequencer.item_o
  ; control_ready_o = sequencer.control_ready_o
  }
[@@@ocamlformat "enable"]

let hierarchical ?(config = Cme_config.default) ?instance scope i =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical ?instance ~name:"cme_packet_pipeline" ~scope (create ~config) i
;;
