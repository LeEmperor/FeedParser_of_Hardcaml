(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "cme_types.ml" *)
(* Direction-neutral parser contracts. Event payloads pack in declaration order, first
   field at the least significant bits. Phase 4 confirms these field widths against CME
   Production schema ID 1/version 13, template 46; see docs/phase4_schema.md.
*)

open! Hardcaml

(* this encoded the extra tags that an event may have attached to it;

   we encode the width of the field itself into it's owning module; how staticy
*)
module Event_kind = struct
  let width = 2
  let mbp_update = 0
  let end_of_event = 1
  let diagnostic = 2
end

(* John Error Code *)
module Diagnostic_code = struct
  let width = 8
  let none = 0
  let sequence_gap = 1
  let duplicate_or_late = 2
  let truncated_packet_header = 3
  let invalid_message_size = 4
  let message_beyond_packet = 5
  let unsupported_template = 6
  let schema_incompatibility = 7
  let invalid_enum = 8
  let internal_overflow = 9
end

module Beat = struct
  type 'a t =
    { data : 'a [@bits 64]
    ; keep : 'a [@bits 8]
    ; first : 'a
    ; last : 'a
    }
  [@@deriving hardcaml]
end

module Ingress_beat = struct
  type 'a t =
    { beat : 'a Beat.t
    ; ingress_timestamp : 'a [@bits 64]
    }
  [@@deriving hardcaml]
end

module Packet_context = struct
  type 'a t =
    { ingress_timestamp : 'a [@bits 64]
    ; source_id : 'a (* which parser or session has given us this *)
    ; packet_seq : 'a [@bits 32]
    ; sending_time : 'a [@bits 64] (* encoded in the 12B of MDP3 Packet Header *)
    ; packet_header_present : 'a (* metadata *)
    ; channel_valid : 'a (* extra sideband *)
    }
  [@@deriving hardcaml]
end

module Message_context = struct
  type 'a t =
    { msg_size : 'a [@bits 16] (* standard MDP3 Message Items (Msg header contents) *)
    ; block_length : 'a [@bits 16]
    ; template_id : 'a [@bits 16]
    ; schema_id : 'a [@bits 16]
    ; schema_version : 'a [@bits 16]
    ; message_header_present : 'a
    ; transaction_time : 'a [@bits 64]
    ; transaction_time_present : 'a
    ; packet_byte_offset : 'a [@bits 16]
    }
  [@@deriving hardcaml]
end

(* this is the main composed item that is emitted out for normalized book existence kind
   represents some extra metadata about a messsage -> for example this beat being handed
   to downstream has SBE header inside of it, or it has the last of a given UDP payload
   inside of it
*)
module Event = struct
  type 'a t =
    { kind : 'a [@bits Event_kind.width]
    ; packet : 'a Packet_context.t
    ; message : 'a Message_context.t
    ; entry_index : 'a [@bits 16]
    ; entry_count : 'a [@bits 16]
    ; security_id : 'a [@bits 32]
    ; rpt_seq : 'a [@bits 32]
    ; price_mantissa : 'a [@bits 64]
    ; price_is_null : 'a
    ; entry_size : 'a [@bits 32]
    ; entry_size_is_null : 'a
    ; number_of_orders : 'a [@bits 32]
    ; number_of_orders_is_null : 'a
    ; price_level : 'a [@bits 8]
    ; update_action : 'a [@bits 8]
    ; entry_type : 'a [@bits 8]
    ; tradeable_size : 'a [@bits 32] (* extras for later *)
    ; tradeable_size_is_null : 'a
    ; match_event_indicator : 'a [@bits 8]
    ; message_last : 'a
    ; diagnostic_code : 'a [@bits Diagnostic_code.width]
    ; expected_seq : 'a [@bits 32]
    ; expected_seq_present : 'a
    ; diagnostic_byte_offset : 'a [@bits 16]
    }
  [@@deriving hardcaml]

  let width = List.fold_left ( + ) 0 (to_list port_widths)
end

(* does this have Of_signal derived on it? *)
module Packet_item_kind = struct
  let width = 2
  let start = 0
  let body = 1
  let diagnostic = 2
end

module Packet_item = struct
  (* One ordered ready/valid channel. Start owns context and the first body beat; body
     carries subsequent header-stripped bytes; diagnostic carries an Event.

     An empty start has no beat and completely represents a header-only packet.
  *)
  type 'a t =
    { kind : 'a [@bits Packet_item_kind.width]
    ; context : 'a Packet_context.t
    ; body_empty : 'a
    ; beat : 'a Beat.t
    ; diagnostic : 'a Event.t
    }
  [@@deriving hardcaml]
end

let packet_item_width =
  List.fold_left ( + ) 0 (Packet_item.to_list Packet_item.port_widths)
;;

module Message_item_kind = struct
  let width = 2
  (* this is the size of the tag field; aka the "kind" tag is of Message_item_kind.width *)

  let start = 0
  let body = 1
  let diagnostic = 2
end

module Message_item = struct
  (* As for Packet_item, with context alongside the first body beat and the ten-byte
     message prefix removed. Body beats stop at MsgSize, even when the UDP packet
     continues in the same input beat.
  *)
  type 'a t =
    { kind : 'a [@bits Message_item_kind.width]
    ; packet : 'a Packet_context.t
    ; message : 'a Message_context.t
    ; body_empty : 'a
    ; beat : 'a Beat.t
    ; diagnostic : 'a Event.t
    }
  [@@deriving hardcaml]
end

let message_item_width =
  List.fold_left ( + ) 0 (Message_item.to_list Message_item.port_widths)
;;
