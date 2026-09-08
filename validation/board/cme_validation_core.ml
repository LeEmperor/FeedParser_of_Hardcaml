(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "cme_validation_core.ml" *)
(* Destination-port selection, the feed parser, and the observability sink, composed into
   the one board block that contains no vendor primitive and no external instantiation.

   Everything from the recovered UDP payload to the UART pin lives here, so the whole
   CME-specific half of the board design is reachable from Cyclesim and therefore from
   dune runtest. [Cme_board_top] adds only the networking blackbox and the board clock,
   reset and LED plumbing, which no cycle-accurate simulation could cover anyway. *)

open! Core
open! Hardcaml
open Signal

module I = struct
  type 'a t =
    { (* Application domain, driven by the network stack's tx-side clock. *)
      clock_i : 'a
    ; reset_i : 'a
    ; en_i : 'a
    ; (* Recovered UDP payload; lane 0 is the earliest byte. *)
      data_i : 'a [@bits 64]
    ; keep_i : 'a [@bits 8]
    ; valid_i : 'a
    ; first_i : 'a
    ; last_i : 'a
    ; dst_port_i : 'a [@bits 16]
    ; (* Network status channel for the physical-frame verdicts. *)
      rx_frame_done_i : 'a
    ; crc_error_i : 'a
    ; checksum_ok_i : 'a
    ; display_i : 'a [@bits 3]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { ready_o : 'a
    ; uart_o : 'a
    ; led_o : 'a [@bits 4]
    ; update_seen_o : 'a
    ; diagnostic_seen_o : 'a
    ; network_error_seen_o : 'a
    ; counters_o : 'a [@bits 256]
    }
  [@@deriving hardcaml]
end

let default_dest_port = 31337

(* [dest_port] is the only destination UDP port admitted to the parser. Traffic on any
   other port drains at full rate without touching parser sequence state, so unrelated
   host chatter on the validation link cannot manufacture sequence gaps. The wrapper
   selects a port; it does not authenticate source IP or MAC, and it does not verify UDP
   checksums. *)
let create
  ?(dest_port = default_dest_port)
  ?uart_divisor
  ?snapshot_cycles
  scope
  (i : _ I.t)
  =
  let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in
  let active = i.en_i &: ~:(i.reset_i) in
  let ready = wire 1 in
  (* Selection is decided on the first beat and then held, so a packet whose header beat
     was admitted stays admitted even though [dst_port_i] is only meaningful at [first_i]. *)
  let selected = wire 1 in
  let select_packet =
    mux2 i.first_i (i.dst_port_i ==:. dest_port) selected -- "select_packet"
  in
  let accepted = active &: i.valid_i &: ready in
  selected <-- Signal.reg spec ~enable:(accepted &: i.first_i) select_packet;
  let parser =
    Cme_of_hardcaml.Cme_feed_parser.hierarchical
      scope
      { clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; en_i = i.en_i
      ; data_i = i.data_i
      ; keep_i = i.keep_i
      ; valid_i = i.valid_i &: select_packet
      ; first_i = i.first_i
      ; last_i = i.last_i
      ; ingress_timestamp_i = zero 64
      ; session_reset_i = gnd
      ; resync_valid_i = gnd
      ; resync_next_seq_i = zero 32
      ; event_ready_i = vdd
      }
  in
  (* A filtered packet is never offered to the parser, so it must not wait on it. *)
  ready <-- (active &: (~:select_packet |: parser.ready_o));
  let sink =
    Cme_validation_sink.hierarchical
      ?uart_divisor
      ?snapshot_cycles
      scope
      { clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; en_i = i.en_i
      ; packet_accepted_i = accepted &: i.first_i &: select_packet
      ; event_valid_i = parser.event_valid_o
      ; event_i = parser.event_o
      ; rx_frame_done_i = i.rx_frame_done_i
      ; crc_error_i = i.crc_error_i
      ; checksum_ok_i = i.checksum_ok_i
      ; display_i = i.display_i
      }
  in
  { O.ready_o = ready
  ; uart_o = sink.uart_o
  ; led_o = sink.led_o
  ; update_seen_o = sink.update_seen_o
  ; diagnostic_seen_o = sink.diagnostic_seen_o
  ; network_error_seen_o = sink.network_error_seen_o
  ; counters_o = sink.counters_o
  }
;;

let hierarchical ?dest_port ?uart_divisor ?snapshot_cycles ?instance scope i =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical
    ?instance
    ~name:"cme_validation_core"
    ~scope
    (create ?dest_port ?uart_divisor ?snapshot_cycles)
    i
;;
