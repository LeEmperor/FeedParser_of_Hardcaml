(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "event_fifo.ml" *)
(* Reusable ordered storage for packed normalized events. *)

open! Hardcaml

module I = struct
  type 'a t =
    { (* Application clock; synchronous reset overrides enable. *)
      clock_i : 'a
    ; reset_i : 'a
    ; en_i : 'a
    ; (* Complete Event.Of_signal.pack payloads, held until accepted. *)
      event_i : 'a [@bits Cme_types.Event.width]
    ; event_valid_i : 'a
    ; event_ready_i : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { event_ready_o : 'a
    ; event_valid_o : 'a
    ; event_o : 'a [@bits Cme_types.Event.width]
    }
  [@@deriving hardcaml]
end

let create
  ?(depth = Cme_config.default.event_fifo_depth)
  ?(fallthrough = false)
  ?(greedy_admission = false)
  scope
  (i : _ I.t)
  =
  let fifo =
    Elastic_fifo.create
      ~depth
      ~fallthrough
      ~greedy_admission
      scope
      ~clock:i.clock_i
      ~reset:i.reset_i
      ~en:i.en_i
      ~data:i.event_i
      ~valid:i.event_valid_i
      ~ready:i.event_ready_i
  in
  { O.event_ready_o = fifo.ready; event_valid_o = fifo.valid; event_o = fifo.data }
;;

let hierarchical
  ?(depth = Cme_config.default.event_fifo_depth)
  ?(fallthrough = false)
  ?(greedy_admission = false)
  ?instance
  scope
  i
  =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical
    ?instance
    ~name:"cme_event_fifo"
    ~scope
    (create ~depth ~fallthrough ~greedy_admission)
    i
;;
