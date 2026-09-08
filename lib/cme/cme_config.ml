(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "cme_config.ml" *)
(* Elaboration-time storage parameters for the portable core. Phase 0 validates these
   parameters but does not instantiate storage yet.
*)

type t =
  { ingress_fifo_depth : int
  ; event_fifo_depth : int
  }

(* Ingress carries 65 rather than 64 beats: Elastic_fifo admission is non-greedy, so the
   last slot cannot be refilled in the cycle it drains, and the extra slot restores the
   effective 64-beat elasticity. See docs/phase6_notes.md. *)
let default = { ingress_fifo_depth = 65; event_fifo_depth = 16 }

let validate t =
  if t.ingress_fifo_depth < 1 then invalid_arg "ingress_fifo_depth must be positive";
  if t.event_fifo_depth < 1 then invalid_arg "event_fifo_depth must be positive"
;;
