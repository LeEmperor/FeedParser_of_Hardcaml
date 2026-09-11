(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "message_pipeline.ml" *)
(* Compose the canonical packet pipeline with generic SBE iteration. The downstream idle
   fence includes decoder ownership and ordered event storage. *)

open! Hardcaml
open Signal
module I = Packet_pipeline.I

module O = struct
  type 'a t =
    { ready_o : 'a
    ; valid_o : 'a
    ; (* Cme_types.Message_item packed in declaration order. *)
      item_o : 'a [@bits Cme_types.message_item_width]
    ; control_ready_o : 'a
    }
  [@@deriving hardcaml]
end

let create ?(config = Cme_config.default) ~supported_templates scope (i : _ I.t) =
  let iterator_ready, iterator_idle = wire 1, wire 1 in
  let packets =
    Packet_pipeline.hierarchical
      ~config
      scope
      { i with
        ready_i = iterator_ready
      ; downstream_idle_i = iterator_idle &: i.downstream_idle_i
      }
  in
  let messages =
    Sbe_message_iterator.hierarchical
      ~supported_templates
      scope
      { clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; en_i = i.en_i
      ; item_i = packets.item_o
      ; valid_i = packets.valid_o
      ; ready_i = i.ready_i
      }
  in
  iterator_ready <-- messages.ready_o;
  iterator_idle <-- messages.idle_o;
  { O.ready_o = packets.ready_o
  ; valid_o = messages.valid_o
  ; item_o = messages.item_o
  ; control_ready_o = packets.control_ready_o
  }
;;

let hierarchical ?(config = Cme_config.default) ~supported_templates ?instance scope i =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical
    ?instance
    ~name:"cme_message_pipeline"
    ~scope
    (create ~config ~supported_templates)
    i
;;
