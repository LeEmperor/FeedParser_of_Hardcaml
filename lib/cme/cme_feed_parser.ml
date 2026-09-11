(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "cme_feed_parser.ml" *)
(* Portable CME MDP 3.0 parser entry point. Phase 0 INACTIVE SKELETON.

   All handshakes are held low, including control_ready_o: no payload or control is
   accepted until processing is implemented. See docs/phase0_contracts.md.
*)

open! Hardcaml

module I = struct
  type 'a t =
    { (* Application domain; active-high synchronous reset overrides enable. *)
      clock_i : 'a
    ; reset_i : 'a
    ; en_i : 'a
    ; (* Trusted UDP payload; lane 0 is the earliest byte. *)
      data_i : 'a [@bits 64]
    ; keep_i : 'a [@bits 8]
    ; valid_i : 'a
    ; first_i : 'a
    ; last_i : 'a
    ; ingress_timestamp_i : 'a [@bits 64]
    ; (* Idle-only sequencer controls; session reset wins over resync. *)
      session_reset_i : 'a
    ; resync_valid_i : 'a
    ; resync_next_seq_i : 'a [@bits 32]
    ; (* Ordered normalized-event consumer, in the same clock domain. *)
      event_ready_i : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { ready_o : 'a
    ; control_ready_o : 'a
    ; event_valid_o : 'a
    ; event_o : 'a [@bits Cme_types.Event.width]
    }
  [@@deriving hardcaml]
end

let create ?(config = Cme_config.default) (_scope : Scope.t) (_i : Signal.t I.t)
  : Signal.t O.t
  =
  Cme_config.validate config;
  { O.ready_o = Signal.gnd
  ; control_ready_o = Signal.gnd
  ; event_valid_o = Signal.gnd
  ; event_o = Signal.zero Cme_types.Event.width
  }
;;

let hierarchical ?(config = Cme_config.default) ?instance scope i =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical ?instance ~name:"cme_mdp3_feed_parser" ~scope (create ~config) i
;;

let circuit ?(config = Cme_config.default) () =
  let scope = Scope.create ~flatten_design:true () in
  let module C = Circuit.With_interface (I) (O) in
  C.create_exn ~name:"cme_mdp3_feed_parser" (create ~config scope)
;;
