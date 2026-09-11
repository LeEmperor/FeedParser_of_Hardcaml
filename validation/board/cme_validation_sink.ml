(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "cme_validation_sink.ml" *)
(* Board observability for the CME feed parser: eight counters over the normalized event
   stream and the network status channel, an LED view selected by sw[3:1], and atomic
   36-byte UART status records.

   This is the Hardcaml replacement for the former hand-written cme_validation_sink.sv.
   Two things improve by the move. The event ABI is now read through
   [Event.Of_signal.unpack] instead of the hand-maintained literal slice
   [event_data[627:620]], so a field added to [Cme_types.Event] can no longer silently
   shift the diagnostic code out from under the counters. And the module is an ordinary
   DUT, so the counters and the UART serializer are exercised by dune runtest rather than
   only by the board simulation.

   The parser is deliberately NOT instantiated here; [Cme_validation_core] composes it
   with this sink. Keeping them apart lets the sink's suite drive synthetic events
   directly instead of having to provoke each event kind through a full parse. *)

open! Core
open! Hardcaml
open Signal
open Always
module T = Cme_of_hardcaml.Cme_types

(* ASCII "CME7" read back as a little-endian 32-bit word: byte 0 is 'C'. *)
let magic = 0x37454D43
let magic_bytes = 4
let counter_width = 32
let counter_count = 8
let record_bytes = magic_bytes + (counter_count * counter_width / 8)
let snapshot_width = record_bytes * 8

module I = struct
  type 'a t =
    { (* Application domain; synchronous reset overrides enable. *)
      clock_i : 'a
    ; reset_i : 'a
    ; en_i : 'a
    ; (* One pulse per selected packet admitted to the parser, duplicates included. *)
      packet_accepted_i : 'a
    ; (* Normalized event stream, already accepted by the consumer. *)
      event_valid_i : 'a
    ; event_i : 'a [@bits T.Event.width]
    ; (* Network status channel, in the same domain as the application stream. *)
      rx_frame_done_i : 'a
    ; crc_error_i : 'a
    ; checksum_ok_i : 'a
    ; (* sw[3:1]: which counter's low nibble reaches led[3:0]. *)
      display_i : 'a [@bits 3]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { uart_o : 'a
    ; led_o : 'a [@bits 4]
    ; update_seen_o : 'a
    ; diagnostic_seen_o : 'a
    ; network_error_seen_o : 'a
    ; counters_o : 'a [@bits 256]
    }
  [@@deriving hardcaml]
end

(* [uart_divisor] is the application clock divided by the baud rate: 25 MHz / 115200
   rounds to 217. [snapshot_cycles] is the idle gap between records, one second at 25 MHz.
   Both are lowered by the testbenches so a record fits in a short simulation. *)
let create
  ?(uart_divisor = 217)
  ?(snapshot_cycles = 25_000_000)
  (_scope : Scope.t)
  (i : _ I.t)
  =
  if uart_divisor < 2 then raise_s [%message "uart_divisor must be at least 2"];
  if snapshot_cycles < 2 then raise_s [%message "snapshot_cycles must be at least 2"];
  let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in
  let active = i.en_i &: ~:(i.reset_i) in
  let event = T.Event.Of_signal.unpack i.event_i in
  let is_kind n = i.event_valid_i &: (event.kind ==:. n) in
  let update = is_kind T.Event_kind.mbp_update in
  let end_of_event = is_kind T.Event_kind.end_of_event in
  let diagnostic = is_kind T.Event_kind.diagnostic in
  let has_code n = diagnostic &: (event.diagnostic_code ==:. n) in
  (* Udp_ipv4_rx registers crc_error_o on frame_done_o, so its verdict belongs to the
     frame that completed on the previous enabled cycle. Sampling both together would
     charge the previous frame's CRC result to this one. checksum_ok_o is already aligned
     to frame completion and needs no delay. *)
  let crc_pending = Variable.reg spec ~enable:active ~width:1 in
  let counter name increment =
    let v = Variable.reg spec ~enable:active ~width:counter_width in
    ignore (v.value -- name : Signal.t);
    v, increment
  in
  let counters =
    [ counter "packets" i.packet_accepted_i
    ; counter "updates" update
    ; counter "end_of_event" end_of_event
    ; counter "diagnostics" diagnostic
    ; counter "crc_errors" (crc_pending.value &: i.crc_error_i)
    ; counter "ip_errors" (i.rx_frame_done_i &: ~:(i.checksum_ok_i))
    ; counter "sequence_gaps" (has_code T.Diagnostic_code.sequence_gap)
    ; counter "duplicates" (has_code T.Diagnostic_code.duplicate_or_late)
    ]
  in
  compile
    ((crc_pending <-- i.rx_frame_done_i)
     :: List.map counters ~f:(fun (v, increment) ->
       when_ increment [ v <-- v.value +:. 1 ]));
  let values = List.map counters ~f:(fun (v, _) -> v.value) in
  (* Declaration order runs from the low word up, so [packets] occupies bits 31:0 and the
     host unpacks the record with a plain little-endian '<8I'. *)
  let counters_o = concat_msb (List.rev values) in
  let snapshot = Variable.reg spec ~enable:vdd ~width:snapshot_width in
  let interval_count =
    Variable.reg spec ~enable:vdd ~width:(Int.ceil_log2 snapshot_cycles)
  in
  let baud_count = Variable.reg spec ~enable:vdd ~width:(Int.ceil_log2 uart_divisor) in
  (* One 8N1 frame held LSB-first: start bit, eight data bits, stop bit. *)
  let shift = Variable.reg spec ~enable:vdd ~width:10 in
  let byte_index = Variable.reg spec ~enable:vdd ~width:(Int.ceil_log2 record_bytes) in
  let bit_index = Variable.reg spec ~enable:vdd ~width:4 in
  let busy = Variable.reg spec ~enable:vdd ~width:1 in
  let frame byte = concat_msb [ one 1; byte; zero 1 ] in
  let next_byte = select snapshot.value ~high:15 ~low:8 in
  (* The UART is not gated by [en_i]: dropping the enable mid-record would truncate a
     status record and desynchronize the host's framing. Only reset stops it. *)
  compile
    [ if_
        ~:(busy.value)
        [ if_
            (interval_count.value ==:. snapshot_cycles - 1)
            [ (* Latch every counter at once. The snapshot is immutable for the whole
                 transmission, so a record can never mix two sample points. *)
              snapshot <-- concat_msb [ counters_o; of_int_trunc ~width:32 magic ]
            ; shift <-- frame (of_int_trunc ~width:8 (magic land 0xff))
            ; interval_count <--. 0
            ; baud_count <--. 0
            ; byte_index <--. 0
            ; bit_index <--. 0
            ; busy <--. 1
            ]
            [ interval_count <-- interval_count.value +:. 1 ]
        ]
        [ if_
            (baud_count.value ==:. uart_divisor - 1)
            [ baud_count <--. 0
            ; if_
                (bit_index.value ==:. 9)
                [ bit_index <--. 0
                ; if_
                    (byte_index.value ==:. record_bytes - 1)
                    [ busy <--. 0 ]
                    [ snapshot <-- srl snapshot.value ~by:8
                    ; shift <-- frame next_byte
                    ; byte_index <-- byte_index.value +:. 1
                    ]
                ]
                [ shift <-- srl shift.value ~by:1; bit_index <-- bit_index.value +:. 1 ]
            ]
            [ baud_count <-- baud_count.value +:. 1 ]
        ]
    ];
  { O.uart_o = mux2 busy.value (lsb shift.value) vdd
  ; led_o = select (mux i.display_i values) ~high:3 ~low:0
  ; update_seen_o = reduce ~f:( |: ) (bits_lsb (List.nth_exn values 1))
  ; diagnostic_seen_o = reduce ~f:( |: ) (bits_lsb (List.nth_exn values 3))
  ; network_error_seen_o =
      reduce ~f:( |: ) (bits_lsb (List.nth_exn values 4 |: List.nth_exn values 5))
  ; counters_o
  }
;;

let hierarchical ?uart_divisor ?snapshot_cycles ?instance scope i =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical
    ?instance
    ~name:"cme_validation_sink"
    ~scope
    (create ?uart_divisor ?snapshot_cycles)
    i
;;
