(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "schema_fixture.ml" *)
(* Independently encoded schema-valid template-46 packets and classic-PCAP wrappers. *)

open! Core

let schema_file = "../../../docs/templates.xml"

let le width value =
  String.init width ~f:(fun index ->
    Int64.bit_and (Int64.shift_right_logical value (index * 8)) 0xffL
    |> Int64.to_int_exn
    |> Char.of_int_exn)
;;

let be16 value =
  String.init 2 ~f:(fun index ->
    Char.of_int_exn ((value lsr ((1 - index) * 8)) land 0xff))
;;

let set_le bytes offset width value =
  for index = 0 to width - 1 do
    Bytes.set
      bytes
      (offset + index)
      (Int64.bit_and (Int64.shift_right_logical value (index * 8)) 0xffL
       |> Int64.to_int_exn
       |> Char.of_int_exn)
  done
;;

type entry =
  { price : int64
  ; size : int64
  ; security_id : int64
  ; rpt_seq : int64
  ; orders : int64
  ; level : int
  ; action : int
  ; entry_type : char
  ; tradeable : int64
  }

let default_entry =
  { price = -123L
  ; size = 10L
  ; security_id = 1234L
  ; rpt_seq = 7L
  ; orders = 3L
  ; level = 2
  ; action = 1
  ; entry_type = '0'
  ; tradeable = 9L
  }
;;

let encode_entry ~version ~block_length entry =
  let bytes = Bytes.make block_length '\000' in
  set_le bytes 0 8 entry.price;
  set_le bytes 8 4 entry.size;
  set_le bytes 12 4 entry.security_id;
  set_le bytes 16 4 entry.rpt_seq;
  set_le bytes 20 4 entry.orders;
  Bytes.set bytes 24 (Char.of_int_exn entry.level);
  Bytes.set bytes 25 (Char.of_int_exn entry.action);
  Bytes.set bytes 26 entry.entry_type;
  if version >= 10 then set_le bytes 27 4 entry.tradeable;
  Bytes.to_string bytes
;;

let message
  ?(template = 46)
  ?(schema = 1)
  ?(version = 13)
  ?(root_block = 11)
  ?(entry_block = 32)
  ?(order_block = 24)
  ?(order_count = 0)
  ?(transact_time = 123L)
  ?(match_event_indicator = 0)
  entries
  =
  let root = Bytes.make root_block '\000' in
  if root_block >= 8 then set_le root 0 8 transact_time;
  if root_block >= 9 then Bytes.set root 8 (Char.of_int_exn match_event_indicator);
  let mbp_dimension =
    le 2 (Int64.of_int entry_block) ^ le 1 (Int64.of_int (List.length entries))
  in
  let entries =
    List.map entries ~f:(encode_entry ~version ~block_length:entry_block) |> String.concat
  in
  let order_dimension = Bytes.make 8 '\000' in
  set_le order_dimension 0 2 (Int64.of_int order_block);
  Bytes.set order_dimension 7 (Char.of_int_exn order_count);
  let orders = String.make (order_block * order_count) '\x5a' in
  let body =
    Bytes.to_string root
    ^ mbp_dimension
    ^ entries
    ^ Bytes.to_string order_dimension
    ^ orders
  in
  let size = 10 + String.length body in
  String.concat
    [ le 2 (Int64.of_int size)
    ; le 2 (Int64.of_int root_block)
    ; le 2 (Int64.of_int template)
    ; le 2 (Int64.of_int schema)
    ; le 2 (Int64.of_int version)
    ; body
    ]
;;

let raw_message ~declared_size body =
  le 2 (Int64.of_int declared_size) ^ le 2 0L ^ le 2 46L ^ le 2 1L ^ le 2 13L ^ body
;;

let packet ?(sending_time = 99L) sequence messages =
  le 4 sequence ^ le 8 sending_time ^ String.concat messages
;;

let pcap packet =
  let ethernet = String.make 12 '\000' ^ be16 0x0800 in
  let udp_length = 8 + String.length packet in
  let ip_length = 20 + udp_length in
  let ip =
    String.concat
      [ "\x45\x00"
      ; be16 ip_length
      ; "\x00\x00\x00\x00\x40\x11\x00\x00"
      ; "\x0a\x00\x00\x01\xef\x00\x00\x01"
      ]
  in
  let udp = be16 1000 ^ be16 2000 ^ be16 udp_length ^ "\x00\x00" in
  let frame = ethernet ^ ip ^ udp ^ packet in
  let global =
    "\xd4\xc3\xb2\xa1" ^ le 2 2L ^ le 2 4L ^ le 4 0L ^ le 4 0L ^ le 4 65535L ^ le 4 1L
  in
  let record =
    le 4 2L
    ^ le 4 3L
    ^ le 4 (Int64.of_int (String.length frame))
    ^ le 4 (Int64.of_int (String.length frame))
  in
  global ^ record ^ frame
;;
