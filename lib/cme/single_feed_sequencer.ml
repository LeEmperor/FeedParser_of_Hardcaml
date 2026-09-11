(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "single_feed_sequencer.ml" *)
(* Single-feed admission with ordered diagnostics. Controls must be fenced by the
   composition boundary; quiescent_i includes downstream pending work.
*)

open! Hardcaml
open Signal

[@@@ocamlformat "disable"]
(* general dataflow:

  takes in a formed item out of the packet header


  looks at if the item is a start item, and checks the seq num only then on the packet;

  as long as the seq num was obeyed in order, the body of the packet is then passed downstream

  this module acts as an entire gate between the packet_header and the rest of the packet_pipeline itself
  in terms of passing body information
*)

module I = struct
  type 'a t =
    { (* Application domain; synchronous reset overrides the shared enable pause. *)
      clock_i : 'a
    ; reset_i : 'a
    ; en_i : 'a

    ; (* Ordered pre-sequence Packet_item stream from header extraction. *)
      item_i : 'a [@bits Cme_types.packet_item_width]

    ; valid_i : 'a
    ; (* Consumer of the packed canonical packet stream. *)
      ready_i : 'a

    ; (* No buffered upstream or downstream work; requests are not latched while busy. *)
      quiescent_i : 'a
    ; session_reset_i : 'a
    ; resync_valid_i : 'a
    ; resync_next_seq_i : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { ready_o : 'a
    ; valid_o : 'a
    ; (* Cme_types.Packet_item packed in declaration order. *)
      item_o : 'a [@bits Cme_types.packet_item_width]
    ; control_ready_o : 'a
    ; idle_o : 'a
    }
  [@@deriving hardcaml]
end
[@@@ocamlformat "enable"]

[@@@ocamlformat "disable"]
let create (_scope : Scope.t) (i : _ I.t) =

  (* spec *)
  let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in

  (* local aliases *)
  let module T = Cme_types in

  (* readily available *)
  let active = (i.en_i &: ~:(i.reset_i)) -- "active" in

  let item = T.Packet_item.Of_signal.unpack i.item_i in

  (* State hangers: each is the Q net of a register driven in the register file at the
     bottom of this function

     The feedback is structural, not stylistic - every one of
     these is read by the handshake logic that computes its own next value, so the cycle
     is real and closes through the flop.

     Named so timing reports and waveforms read as
     [expected -> channel_valid] rather than [signal_reg_3_reg[6]]; see the naming rule
     in docs/timing_notes.md. Declaration order matches the register file below
  *)
  let initialized   = Signal.wire 1  -- "initialized"   in
  let expected      = Signal.wire 32 -- "expected"      in
  let channel_valid = Signal.wire 1  -- "channel_valid" in
  let dropping      = Signal.wire 1  -- "dropping"      in
  let gap_sent      = Signal.wire 1  -- "gap_sent"      in
  let open_packet   = Signal.wire 1  -- "open_packet"   in

  (* ------------------------------------------------------------------ *)
  (* combinational                                                      *)
  (* ------------------------------------------------------------------ *)

  let idle = ~:(dropping |:
                gap_sent |:
                open_packet)
             -- "idle"
  in

  let control_ready = (active &: idle &: i.quiescent_i) -- "control_ready" in
  let session_reset = (control_ready &: i.session_reset_i) -- "session_reset" in

  (* are we ready and not resetting the session and doing a resync *)
  let resync = (control_ready &:
                ~:(i.session_reset_i) &:
                i.resync_valid_i)
               -- "resync"
  in

  let control = (session_reset |: resync) -- "control" in

  (* are we beginning a packet? where do the sideband items come from? *)
  let start = (item.kind ==:. T.Packet_item_kind.start) -- "start" in
  let diagnostic = (item.kind ==:. T.Packet_item_kind.diagnostic) -- "diagnostic" in

  (* last indicator; interesting derive for the start/body_empty pair *)
  let last = (item.beat.last |: (start &: item.body_empty)) -- "last" in

  (* actual sequencing wire *)
  let delta = (item.context.packet_seq -: expected) -- "delta" in
  let late = msb delta -- "late" in

  let fault =
    (start &: (* have we started? *)
     initialized &: (* are we stream reading? *)
     (delta <>:. 0) &: (* if the delta is greater than 0 then cook *)
     ~:gap_sent (* if a gap is sent then a fault has happened obviously *)
    )
    -- "fault"
  in

  let emit_fault = (fault &: ~:dropping) -- "emit_fault" in

  (* handshake  *)
  let valid = (active &: i.valid_i &: ~:dropping &: ~:control) -- "valid" in
  let ready = (active &:
               ~:control &:
               (dropping |:
                (i.ready_i &:
                 ~:emit_fault)
               ))
              -- "ready"
  in

  let input_transfer = (i.valid_i &: ready) -- "input_transfer" in
  let fault_transfer = (valid &: i.ready_i &: emit_fault) -- "fault_transfer" in
  let admit = (input_transfer &: start &: ~:dropping) -- "admit" in

  (* ------------------------------------------------------------------ *)
  (* next state                                                         *)
  (* ------------------------------------------------------------------ *)

  let initialized_next =
    mux2
      (* did the session reset? *)
      session_reset

      (* yes : zero it *)
      gnd

      (* no - *)
      (mux2
         (resync |: admit)
         vdd
         initialized
      )
    -- "initialized_next"
  in

  let expected_next =
    mux2
      (* is the session being reset? *)
      session_reset

      (* zero out *)
      (zero 32)

      (mux2
         (* are we re-syncing? *)
         resync

         (* yes - *)
         i.resync_next_seq_i

         (* no - *)
         (mux2
            admit
            (item.context.packet_seq +:. 1)
            expected
         )
      )
    -- "expected_next"
  in

  let channel_valid_next =
    mux2
      session_reset
      gnd
      (mux2
         resync
         vdd
         (mux2
            (fault_transfer &: ~:late)
            gnd
            (mux2
               (admit &: ~:initialized)
               vdd
               channel_valid)))
    -- "channel_valid_next"
  in

  let dropping_next =
    mux2
      (fault_transfer &: late)
      vdd
      (mux2 (input_transfer &: last) gnd dropping)
    -- "dropping_next"
  in

  let gap_sent_next =
    mux2
      (fault_transfer &: ~:late)
      vdd
      (mux2 admit gnd gap_sent)
    -- "gap_sent_next"
  in

  let open_packet_next =
    mux2 (input_transfer &: ~:diagnostic) ~:last open_packet
    -- "open_packet_next"
  in

  (* ------------------------------------------------------------------ *)
  (* register file                                                      *)
  (* ------------------------------------------------------------------ *)

  (* [reg] shadows [Signal.reg] with [spec] and [active] already applied, so every state
     flop below shares one clock, clear and pause, and a register added later cannot pick
     up different behaviour by accident. Note the arity: this [reg] takes only the next
     value. A flop needing a different spec is written out in full with [Signal.reg] and
     a comment saying why.
  *)
  let reg d = Signal.reg spec ~enable:active d in

  initialized   <-- reg initialized_next;
  expected      <-- reg expected_next;
  channel_valid <-- reg channel_valid_next;
  dropping      <-- reg dropping_next;
  gap_sent      <-- reg gap_sent_next;
  open_packet   <-- reg open_packet_next;

  let admitted_context =
    { item.context with channel_valid =
        mux2
        initialized
        channel_valid
        vdd
    }
  in

  (* correctly draw through packet item *)
  let passed =
    { item with
      context = T.Packet_context.Of_signal.mux2 start admitted_context item.context
    ; diagnostic =
        T.Event.Of_signal.mux2
          diagnostic
          { item.diagnostic with packet = { item.diagnostic.packet with channel_valid } }
          item.diagnostic
    }
  in

  (* event candidate *)
  let event =
    { (T.Event.Of_signal.zero ()) with
      kind = of_int_trunc ~width:2 T.Event_kind.diagnostic
    ; packet = { item.context with channel_valid = mux2 late channel_valid gnd }
    ; diagnostic_code =
        mux2
          late
          (of_int_trunc ~width:8 T.Diagnostic_code.duplicate_or_late)
          (of_int_trunc ~width:8 T.Diagnostic_code.sequence_gap)
    ; expected_seq = expected
    ; expected_seq_present = vdd
    }
  in

  (* form the fault item candidate *)
  let fault_item =
    { (T.Packet_item.Of_signal.zero ()) with
      kind = of_int_trunc ~width:2 T.Packet_item_kind.diagnostic (* from the diagnostic item declare *)
    ; diagnostic = event
    }
  in

  { O.
    ready_o = ready
  ; valid_o = valid
  ; item_o  =
      T.Packet_item.Of_signal.pack (* compose the Signal packed-scalar into a vector *)
        (T.Packet_item.Of_signal.mux2
           (* are we emitting a fault? *)
           emit_fault
           (* yes - here it is *)
           fault_item
           (* no - use the passed item *)
           passed
        )

  ; control_ready_o = control_ready
  ; idle_o = idle
  }
[@@@ocamlformat "enable"]

let hierarchical ?instance scope i =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical ?instance ~name:"cme_single_feed_sequencer" ~scope create i
;;
