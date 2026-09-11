(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "phase7_contracts.ml" *)
(* Verify the external Verilog event ABI and Python sender fixtures with the XML oracle. *)

open! Core
open! Hardcaml
module T = Cme_of_hardcaml.Cme_types
module G = Cme_schema.Golden_decoder

let () =
  let directory, schema_file =
    match Array.to_list (Sys.get_argv ()) with
    | [ _; directory; schema_file ] -> directory, schema_file
    | _ -> failwith "usage: phase7_contracts.exe VECTOR_DIR SCHEMA_XML"
  in
  assert (T.Event.width = 677);
  assert (T.Event_kind.mbp_update = 0);
  assert (T.Event_kind.end_of_event = 1);
  assert (T.Event_kind.diagnostic = 2);
  assert (T.Diagnostic_code.sequence_gap = 1);
  assert (T.Diagnostic_code.duplicate_or_late = 2);
  let empty = T.Event.map T.Event.port_widths ~f:Bits.zero in
  let encoded =
    T.Event.Of_bits.pack { empty with kind = Bits.ones 2; diagnostic_code = Bits.ones 8 }
  in
  assert (Bits.to_int_trunc (Bits.select encoded ~high:1 ~low:0) = 3);
  assert (Bits.to_int_trunc (Bits.select encoded ~high:627 ~low:620) = 255);
  let golden = G.create ~schema_file in
  let updates, ends, diagnostics, gaps, duplicates = ref 0, ref 0, ref 0, ref 0, ref 0 in
  let cases =
    [ "single_partial_tail", true, (1, 1, 0, 0, 0)
    ; "multiple_messages", true, (4, 3, 0, 0, 0)
    ; "sequence_gap", true, (5, 4, 1, 1, 0)
    ; "duplicate", true, (5, 4, 2, 1, 1)
    ; "after_duplicate", true, (6, 5, 2, 1, 1)
    ; "filtered_port", false, (6, 5, 2, 1, 1)
    ; "after_filtered", true, (7, 6, 2, 1, 1)
    ; "late_bad_fcs", true, (8, 7, 2, 1, 1)
    ; "bad_ip_checksum", true, (9, 8, 2, 1, 1)
    ]
  in
  List.iter cases ~f:(fun (name, selected, expected) ->
    let payload = In_channel.read_all (Filename.concat directory (name ^ ".bin")) in
    assert (String.length payload % 8 <> 0);
    if selected
    then
      List.iter (G.decode_payload golden payload) ~f:(function
        | G.Mbp_update update ->
          incr updates;
          assert (Int64.equal update.security_id 1234L);
          assert (Option.equal Int64.equal update.price_mantissa (Some (-123L)));
          assert (Int64.equal update.packet.ingress_timestamp 0L)
        | G.End_of_event _ -> incr ends
        | G.Diagnostic diagnostic ->
          incr diagnostics;
          (match diagnostic.code with
           | G.Diagnostic_code.Sequence_gap -> incr gaps
           | G.Diagnostic_code.Duplicate_or_late -> incr duplicates
           | _ -> failwith "unexpected fixture diagnostic"));
    let actual = !updates, !ends, !diagnostics, !gaps, !duplicates in
    [%test_eq: int * int * int * int * int] actual expected);
  print_endline "PASS Phase 7 event ABI and nine sender fixtures against XML oracle"
;;
