(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "schema_expect_tests.ml" *)
(* Compact reviewable trace for the independent schema-driven golden decoder. *)

open! Core
open Schema_fixture

let%expect_test "two entries and end-of-event" =
  let module G = Cme_schema.Golden_decoder in
  let events =
    G.decode_payload
      (G.create ~schema_file)
      (packet
         42L
         [ message
             ~transact_time:777L
             ~match_event_indicator:0x80
             [ default_entry
             ; { default_entry with action = 2; entry_type = '1'; rpt_seq = 8L }
             ]
         ])
  in
  List.iter events ~f:(function
    | G.Mbp_update update ->
      printf
        "update seq=%Ld tx=%Ld index=%d/%d rpt=%Ld action=%d type=%c last=%b valid=%b\n"
        update.packet.packet_seq
        update.message.transaction_time
        update.entry_index
        update.entry_count
        update.rpt_seq
        update.update_action
        (Char.of_int_exn update.entry_type)
        update.message_last
        update.packet.channel_valid
    | G.End_of_event event ->
      printf
        "end mei=0x%02x tx=%Ld\n"
        event.match_event_indicator
        event.message.transaction_time
    | G.Diagnostic diagnostic ->
      printf
        !"diagnostic %{sexp:G.Diagnostic_code.t} at %d\n"
        diagnostic.code
        diagnostic.byte_offset);
  [%expect
    {|
    update seq=42 tx=777 index=0/2 rpt=7 action=1 type=0 last=false valid=true
    update seq=42 tx=777 index=1/2 rpt=8 action=2 type=1 last=true valid=true
    end mei=0x80 tx=777 |}]
;;
