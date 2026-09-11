(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "event_orderer.ml" *)
(* Serialize iterator diagnostics and decoder events. Completion is a handshake after the
   message terminal item and all decoder events have entered ordered storage. An
   in-message truncation is delivered to the decoder once, then emitted after completion. *)

open! Hardcaml
open Signal

module I = struct
  type 'a t =
    { (* Application domain; synchronous reset overrides enable. *)
      clock_i : 'a
    ; reset_i : 'a
    ; en_i : 'a
    ; (* Iterator's ordered stream. *)
      item_i : 'a [@bits Cme_types.message_item_width]
    ; valid_i : 'a
    ; (* Decoder accepts start/body and a terminal diagnostic on this same seam. *)
      decoder_ready_i : 'a
    ; decoder_event_i : 'a [@bits Cme_types.Event.width]
    ; decoder_event_valid_i : 'a
    ; decoder_done_i : 'a
    ; (* Ordered storage or external event sink. *)
      event_ready_i : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { ready_o : 'a
    ; decoder_item_o : 'a [@bits Cme_types.message_item_width]
    ; decoder_valid_o : 'a
    ; decoder_event_ready_o : 'a
    ; decoder_done_ready_o : 'a
    ; event_o : 'a [@bits Cme_types.Event.width]
    ; event_valid_o : 'a
    ; idle_o : 'a
    }
  [@@deriving hardcaml]
end

let create (_scope : Scope.t) (i : _ I.t) =
  let module T = Cme_types in
  let active = i.en_i &: ~:(i.reset_i) in
  let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in
  let busy, closed, pending = wire 1, wire 1, wire 1 in
  let item = T.Message_item.Of_signal.unpack i.item_i in
  let diagnostic = item.kind ==:. T.Message_item_kind.diagnostic in
  let start = item.kind ==:. T.Message_item_kind.start in
  let abort = busy &: ~:closed &: diagnostic in
  let route = ~:pending &: mux2 busy ~:closed (start &: ~:diagnostic) in
  let decoder_valid = active &: i.valid_i &: route in
  let decoder_transfer = decoder_valid &: i.decoder_ready_i in
  let terminal = diagnostic |: item.body_empty |: item.beat.last in
  let event_ready = active &: busy &: i.event_ready_i in
  (* Allow done alongside the last event transfer, but never retire a stalled event. *)
  let done_ready =
    active &: busy &: closed &: (~:(i.decoder_event_valid_i) |: i.event_ready_i)
  in
  let done_transfer = done_ready &: i.decoder_done_i in
  let standalone = ~:busy &: ~:pending &: diagnostic in
  let saved =
    reg spec ~enable:(decoder_transfer &: abort) (T.Event.Of_signal.pack item.diagnostic)
  in
  let diagnostic_valid = ~:busy &: (pending |: (standalone &: i.valid_i)) in
  let diagnostic_transfer = active &: diagnostic_valid &: i.event_ready_i in
  busy
  <-- reg
        spec
        ~enable:active
        (mux2 (decoder_transfer &: start) vdd (mux2 done_transfer gnd busy));
  closed
  <-- reg
        spec
        ~enable:active
        (mux2 done_transfer gnd (mux2 decoder_transfer terminal closed));
  pending
  <-- reg
        spec
        ~enable:active
        (mux2 (decoder_transfer &: abort) vdd (mux2 diagnostic_transfer gnd pending));
  { O.ready_o = active &: mux2 route i.decoder_ready_i (standalone &: i.event_ready_i)
  ; decoder_item_o = i.item_i
  ; decoder_valid_o = decoder_valid
  ; decoder_event_ready_o = event_ready
  ; decoder_done_ready_o = done_ready
  ; event_o =
      mux2
        busy
        i.decoder_event_i
        (mux2 pending saved (T.Event.Of_signal.pack item.diagnostic))
  ; event_valid_o = active &: mux2 busy i.decoder_event_valid_i diagnostic_valid
  ; idle_o = ~:busy &: ~:pending
  }
;;

let hierarchical ?instance scope i =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical ?instance ~name:"cme_event_orderer" ~scope create i
;;
