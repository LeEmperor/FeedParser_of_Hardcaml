(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "sbe_message_iterator.ml" *)
(* Generic ten-byte SBE prefix collection and size-bounded body delivery. The two-beat
   window never joins packets. Template admission is an elaboration-time list; no schema
   offsets or production template choices belong here. *)

open! Hardcaml
open Signal

module I = struct
  type 'a t =
    { (* Application domain; synchronous reset overrides enable. *)
      clock_i : 'a
    ; reset_i : 'a
    ; en_i : 'a
    ; (* Canonical post-sequence packet items. *)
      item_i : 'a [@bits Cme_types.packet_item_width]
    ; valid_i : 'a
    ; (* Ordered message consumer, including terminal truncation diagnostics. *)
      ready_i : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { ready_o : 'a
    ; valid_o : 'a
    ; item_o : 'a [@bits Cme_types.message_item_width]
    ; idle_o : 'a
    }
  [@@deriving hardcaml]
end

let create ~supported_templates scope (i : _ I.t) =
  List.iter
    (fun id -> if id < 0 || id > 65535 then invalid_arg "template ID must fit uint16")
    supported_templates;
  let module T = Cme_types in
  let active = i.en_i &: ~:(i.reset_i) in
  let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in
  let output_ready = wire 1 in
  let input = T.Packet_item.Of_signal.unpack i.item_i in
  (* Idle, prefix first eight, prefix final two, body, empty body, skip, drain, error. *)
  let state = wire 3 in
  let code n = of_int_trunc ~width:3 n in
  let idle = state ==:. 0 in
  let input_done = wire 1 in
  let consume_count, consume_valid = wire 4, wire 1 in
  let is_start = input.kind ==:. T.Packet_item_kind.start in
  let is_diagnostic = input.kind ==:. T.Packet_item_kind.diagnostic in
  let empty_packet = is_start &: input.body_empty in
  let accept_bytes =
    idle &: is_start &: ~:(input.body_empty) |: (~:idle &: ~:input_done)
  in
  let a =
    Byte_aligner.hierarchical
      scope
      { clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; en_i = i.en_i
      ; data_i = input.beat.data
      ; keep_i = input.beat.keep
      ; first_i = input.beat.first
      ; last_i = input.beat.last
      ; ingress_timestamp_i = zero 64
      ; valid_i = i.valid_i &: accept_bytes
      ; consume_count_i = consume_count
      ; consume_valid_i = consume_valid
      }
  in
  let ready =
    active
    &: mux2
         idle
         (mux2 is_diagnostic output_ready (empty_packet |: a.ready_o))
         (~:input_done &: a.ready_o)
  in
  let input_transfer = i.valid_i &: ready in
  let start = input_transfer &: idle &: is_start &: ~:(input.body_empty) in
  input_done
  <-- reg
        spec
        ~enable:active
        (mux2
           idle
           (start &: input.beat.last)
           (input_done |: (input_transfer &: input.beat.last)));
  let packet =
    T.Packet_context.Of_signal.unpack
      (reg spec ~enable:start (T.Packet_context.Of_signal.pack input.context))
  in
  let prefix_first = state ==:. 1 in
  let prefix_tail = state ==:. 2 in
  let collecting = prefix_first |: prefix_tail in
  let required = mux2 prefix_first (of_int_trunc ~width:5 8) (of_int_trunc ~width:5 2) in
  let collect = collecting &: a.valid_o &: (a.available_o >=: required |: a.boundary_o) in
  let short_prefix =
    collect
    &: (a.available_o
        <: required
        |: (prefix_first &: a.boundary_o &: (a.available_o ==:. 8)))
  in
  let prefix_head =
    reg spec ~enable:(collect &: prefix_first) (select a.data_o ~high:63 ~low:0)
  in
  let offset =
    reg spec ~enable:(collect &: prefix_first) (a.packet_byte_offset_o +:. 12)
  in
  let message_offset = mux2 prefix_first (a.packet_byte_offset_o +:. 12) offset in
  let parsed : _ T.Message_context.t =
    { msg_size = select prefix_head ~high:15 ~low:0
    ; block_length = select prefix_head ~high:31 ~low:16
    ; template_id = select prefix_head ~high:47 ~low:32
    ; schema_id = select prefix_head ~high:63 ~low:48
    ; schema_version = select a.data_o ~high:15 ~low:0
    ; message_header_present = vdd
    ; transaction_time = zero 64
    ; transaction_time_present = gnd
    ; packet_byte_offset = offset
    }
  in
  let prefix_complete = collect &: prefix_tail &: ~:short_prefix in
  let message =
    T.Message_context.Of_signal.unpack
      (reg spec ~enable:prefix_complete (T.Message_context.Of_signal.pack parsed))
  in
  let supported =
    List.fold_left
      ( |: )
      gnd
      (List.map (fun id -> parsed.template_id ==:. id) supported_templates)
  in
  let invalid_size = prefix_complete &: (parsed.msg_size <:. 10) in
  let unsupported = prefix_complete &: ~:invalid_size &: ~:supported in
  let prefix_ends_packet = a.boundary_o &: (a.available_o ==: required) in
  let remaining = wire 16 in
  let started = wire 1 in
  let body_state = state ==:. 3 in
  let skip_state = state ==:. 5 in
  let draining = state ==:. 6 in
  let count =
    mux2 (remaining <:. 8) (uresize remaining ~width:5) (of_int_trunc ~width:5 8)
  in
  let available_count =
    mux2 (a.available_o <:. 8) a.available_o (of_int_trunc ~width:5 8)
  in
  (* A known short body is diagnosed before exposing its first beat. Once started, already
     completed chunks remain provisional; the diagnostic aborts the collector. *)
  let short_body =
    body_state
    |: skip_state
    &: a.valid_o
    &: a.boundary_o
    &: (uresize a.available_o ~width:16 <: remaining)
  in
  let body_valid = body_state &: a.valid_o &: ~:short_body &: (a.available_o >=: count) in
  let skip = skip_state &: a.valid_o &: ~:short_body &: (a.available_o >=: count) in
  let body_transfer = body_valid &: output_ready in
  let advance = body_transfer |: skip in
  let end_message = remaining <=:. 8 in
  let end_packet = a.boundary_o &: (a.available_o ==: count) in
  let drain = draining &: a.valid_o in
  let drain_end = a.boundary_o &: (a.available_o <=:. 8) in
  let missing_offset = a.packet_byte_offset_o +: uresize a.available_o ~width:16 +:. 12 in
  let prefix_missing_body =
    prefix_complete &: ~:invalid_size &: prefix_ends_packet &: (parsed.msg_size >:. 10)
  in
  let failure =
    short_prefix |: invalid_size |: unsupported |: short_body |: prefix_missing_body
  in
  let diagnostic_code =
    mux2
      short_prefix
      (of_int_trunc ~width:8 T.Diagnostic_code.message_beyond_packet)
      (mux2
         invalid_size
         (of_int_trunc ~width:8 T.Diagnostic_code.invalid_message_size)
         (mux2
            unsupported
            (of_int_trunc ~width:8 T.Diagnostic_code.unsupported_template)
            (of_int_trunc ~width:8 T.Diagnostic_code.message_beyond_packet)))
  in
  let diagnostic_message =
    T.Message_context.Of_signal.mux2
      short_prefix
      { (T.Message_context.Of_signal.zero ()) with packet_byte_offset = message_offset }
      (T.Message_context.Of_signal.mux2 prefix_complete parsed message)
  in
  let diagnostic_offset =
    mux2 invalid_size offset (mux2 unsupported (offset +:. 4) missing_offset)
  in
  let diagnostic =
    T.Event.Of_signal.pack
      { (T.Event.Of_signal.zero ()) with
        kind = of_int_trunc ~width:2 T.Event_kind.diagnostic
      ; packet
      ; message = diagnostic_message
      ; diagnostic_code
      ; diagnostic_byte_offset = diagnostic_offset
      }
  in
  let error = reg spec ~enable:failure diagnostic in
  (* Unsupported at the exact prefix boundary needs a second truncation diagnostic. *)
  let pending_truncation =
    reg spec ~enable:failure (unsupported &: prefix_missing_body)
  in
  let resume =
    reg
      spec
      ~enable:failure
      (mux2
         short_body
         (code 6)
         (mux2
            (short_prefix |: invalid_size)
            (mux2 (a.boundary_o &: (a.available_o <=: required)) (code 0) (code 6))
            (mux2
               prefix_ends_packet
               (code 0)
               (mux2 (parsed.msg_size ==:. 10) (code 1) (code 5)))))
  in
  let error_transfer = active &: (state ==:. 7) &: output_ready in
  let second_error = wire 1 in
  second_error
  <-- reg
        spec
        ~enable:active
        (mux2
           failure
           gnd
           (mux2 error_transfer (pending_truncation &: ~:second_error) second_error));
  let continuation = mux2 end_packet (code 0) (code 1) in
  let after_prefix = mux2 (parsed.msg_size ==:. 10) (code 4) (code 3) in
  state
  <-- reg
        spec
        ~enable:active
        (mux2
           failure
           (code 7)
           (mux2
              start
              (code 1)
              (mux2
                 collect
                 (mux2 prefix_first (code 2) after_prefix)
                 (mux2
                    (advance &: end_message)
                    continuation
                    (mux2
                       (state ==:. 4 &: output_ready)
                       (mux2
                          input_done
                          (mux2 (a.available_o ==:. 0) (code 0) (code 1))
                          (code 1))
                       (mux2
                          error_transfer
                          (mux2 (pending_truncation &: ~:second_error) (code 7) resume)
                          (mux2 (drain &: drain_end) (code 0) state)))))));
  remaining
  <-- reg
        spec
        ~enable:active
        (mux2
           prefix_complete
           (parsed.msg_size -:. 10)
           (mux2 advance (remaining -: uresize count ~width:16) remaining));
  started
  <-- reg spec ~enable:active (mux2 collecting gnd (mux2 body_transfer vdd started));
  consume_valid <-- (collect |: advance |: drain);
  consume_count
  <-- uresize
        (mux2
           collecting
           (mux2 (a.available_o <: required) a.available_o required)
           (mux2 draining available_count count))
        ~width:4;
  let blank = T.Message_item.Of_signal.zero () in
  let keep =
    mux
      (uresize count ~width:4)
      (List.init 9 (fun n -> of_int_trunc ~width:8 ((1 lsl n) - 1)))
  in
  let body =
    { blank with
      kind = mux2 started (of_int_trunc ~width:2 T.Message_item_kind.body) (zero 2)
    ; packet =
        T.Packet_context.Of_signal.mux2
          started
          (T.Packet_context.Of_signal.zero ())
          packet
    ; message =
        T.Message_context.Of_signal.mux2
          started
          (T.Message_context.Of_signal.zero ())
          message
    ; beat =
        { data = Byte_aligner.mask_data (select a.data_o ~high:63 ~low:0) keep
        ; keep
        ; first = ~:started
        ; last = end_message
        }
    }
  in
  let empty = { blank with packet; message; body_empty = vdd } in
  let saved_error = T.Event.Of_signal.unpack error in
  let saved_error =
    { saved_error with
      diagnostic_code =
        mux2
          second_error
          (of_int_trunc ~width:8 T.Diagnostic_code.message_beyond_packet)
          saved_error.diagnostic_code
    ; diagnostic_byte_offset =
        mux2
          second_error
          (saved_error.message.packet_byte_offset +:. 10)
          saved_error.diagnostic_byte_offset
    }
  in
  let diagnostic_item =
    { blank with
      kind = of_int_trunc ~width:2 T.Message_item_kind.diagnostic
    ; diagnostic = T.Event.Of_signal.mux2 idle input.diagnostic saved_error
    }
  in
  let output_valid =
    active
    &: (idle
        &: i.valid_i
        &: is_diagnostic
        |: body_valid
        |: (state ==:. 4)
        |: (state ==:. 7))
  in
  let output_item =
    T.Message_item.Of_signal.pack
      (T.Message_item.Of_signal.mux2
         (idle |: (state ==:. 7))
         diagnostic_item
         (T.Message_item.Of_signal.mux2 (state ==:. 4) empty body))
  in
  let output =
    Elastic_fifo.create
      ~depth:1
      scope
      ~clock:i.clock_i
      ~reset:i.reset_i
      ~en:i.en_i
      ~data:output_item
      ~valid:output_valid
      ~ready:i.ready_i
  in
  output_ready <-- output.ready;
  { O.ready_o = ready
  ; valid_o = output.valid
  ; item_o = output.data
  ; idle_o = idle &: (a.available_o ==:. 0) &: ~:(output.valid)
  }
;;

let hierarchical ~supported_templates ?instance scope i =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical
    ?instance
    ~name:"cme_sbe_message_iterator"
    ~scope
    (create ~supported_templates)
    i
;;
