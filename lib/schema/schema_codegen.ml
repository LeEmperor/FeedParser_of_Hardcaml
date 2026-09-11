(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "schema_codegen.ml" *)
(* Deterministic OCaml emitter for the selected MBP hardware descriptor. *)

open! Core
open Mbp_descriptor

let emit_scalar buffer name scalar =
  bprintf buffer "module %s = struct\n" name;
  bprintf buffer "  let offset = %d\n" scalar.offset;
  bprintf buffer "  let byte_width = %d\n" scalar.width;
  bprintf buffer "  let bit_width = %d\n" (scalar.width * 8);
  bprintf buffer "  let signed = %b\n" scalar.signed;
  bprintf buffer "  let nullable = %b\n" scalar.nullable;
  (match scalar.null_value with
   | None -> bprintf buffer "  let null_value = None\n"
   | Some value -> bprintf buffer "  let null_value = Some %S\n" value);
  bprintf buffer "  let since_version = %d\n" scalar.since_version;
  bprintf
    buffer
    "  let valid_values = [ %s ]\n"
    (String.concat ~sep:"; " (List.map scalar.valid_values ~f:Int.to_string));
  bprintf buffer "end\n\n"
;;

let emit_dimension buffer name dimension =
  bprintf buffer "module %s = struct\n" name;
  bprintf buffer "  let encoded_size = %d\n" dimension.encoded_size;
  bprintf buffer "  let block_length_offset = %d\n" dimension.block_length_offset;
  bprintf buffer "  let block_length_byte_width = %d\n" dimension.block_length_width;
  bprintf buffer "  let count_offset = %d\n" dimension.count_offset;
  bprintf buffer "  let count_byte_width = %d\n" dimension.count_width;
  bprintf buffer "end\n\n"
;;

let to_string descriptor =
  let buffer = Buffer.create 4096 in
  bprintf
    buffer
    "(* Generated from the pinned CME Production SBE schema.  Do not edit. *)\n\n";
  bprintf buffer "let schema_id = %d\n" descriptor.schema_id;
  bprintf buffer "let schema_version = %d\n" descriptor.schema_version;
  bprintf buffer "let template_name = %S\n" descriptor.template_name;
  bprintf buffer "let template_id = %d\n" descriptor.template_id;
  bprintf buffer "let template_since_version = %d\n" descriptor.template_since_version;
  bprintf buffer "let root_block_length = %d\n" descriptor.root_block_length;
  bprintf buffer "let mbp_group_block_length = %d\n" descriptor.mbp_group_block_length;
  bprintf
    buffer
    "let order_group_block_length = %d\n\n"
    descriptor.order_group_block_length;
  emit_scalar buffer "Transact_time" descriptor.transact_time;
  emit_scalar buffer "Match_event_indicator" descriptor.match_event_indicator;
  emit_dimension buffer "Mbp_dimension" descriptor.mbp_dimension;
  emit_scalar buffer "Price_mantissa" descriptor.price_mantissa;
  bprintf buffer "let price_exponent = %d\n\n" descriptor.price_exponent;
  emit_scalar buffer "Entry_size" descriptor.entry_size;
  emit_scalar buffer "Security_id" descriptor.security_id;
  emit_scalar buffer "Rpt_seq" descriptor.rpt_seq;
  emit_scalar buffer "Number_of_orders" descriptor.number_of_orders;
  emit_scalar buffer "Price_level" descriptor.price_level;
  emit_scalar buffer "Update_action" descriptor.update_action;
  emit_scalar buffer "Entry_type" descriptor.entry_type;
  emit_scalar buffer "Tradeable_size" descriptor.tradeable_size;
  emit_dimension buffer "Order_dimension" descriptor.order_dimension;
  Buffer.contents buffer
;;

let write descriptor filename =
  Out_channel.write_all filename ~data:(to_string descriptor)
;;
