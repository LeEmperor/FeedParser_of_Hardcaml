(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "elastic_fifo.ml" *)
(* Packed ready/valid storage with exact positive capacity. Admission is a configuration:
   non-greedy by default, greedy under [~greedy_admission:true]. The showahead register
   counts toward capacity. Reset overrides the shared enable.
*)

open! Hardcaml
open! Signal

type t =
  { data : Signal.t
  ; valid : Signal.t
  ; ready : Signal.t
  }

[@@@ocamlformat "disable"]
let create
(* might add a "fast" flag to trigger fast_fifo usage; fanout against the BRAM back'd ones might be a problem *)
  ?(fallthrough = false)
  ?(greedy_admission = false)
  ?ram_attributes
  ~depth
  scope
  ~clock (* common ip block so most of these things get passed in as dependencies *)
  ~reset
  ~en
  ~data
  ~valid
  ~ready
  =

  (* ocaml-elaboration time depth check *)
  if depth < 1 then invalid_arg "FIFO depth must be positive";

  (* spec *)
  let spec = Reg_spec.create ~clock ~clear:reset () in

  (* handshake - en might get axed later *)
  let active = en &: ~:reset in

  let pop =   Signal.wire 1 -- "elastic_fifo_pop" in
  let push =  Signal.wire 1 -- "elastic_fifo_push" in

  let output, empty, full =
    if depth = 1
    then (
      let occupied = Signal.reg_fb spec ~width:1 ~f:(
          fun q ->
            mux2
              push
              vdd (mux2 pop gnd q)
        ) in
      Signal.reg spec ~enable:push data, ~:occupied, occupied)
    else (
      let fifo =
        Fifo.create
          ~scope
          ~showahead:true
          ~overflow_check:false
          ~underflow_check:false
          ?ram_attributes
          ()
          ~capacity:(depth - 1)
          ~clock
          ~clear:reset
          ~wr:push
          ~d:data
          ~rd:pop
      in
      fifo.q, fifo.empty, fifo.full)
  in

  let output = output -- "elastic_fifo_output" in
  let empty = empty -- "elastic_fifo_empty" in
  let full = full -- "elastic_fifo_full" in

  let bypass = if fallthrough then empty else gnd in
  let output_valid = active &: (~:empty |: (bypass &: valid)) in
  pop <-- (active &: ~:empty &: ready);
  (* Admission is a configuration, not a property of the primitive.

     Non-greedy (the default): input_ready reads the full flag alone, never this cycle's
     pop, so it carries no dependency on the downstream ready and cannot extend a chain of
     combinationally transparent readies. Capacity is still exactly `depth`; what is given
     up is same-cycle replacement while full, so a depth-1 instance has no full-rate
     pass-through and each user pays for that with one extra slot of depth. Every instance
     in the parser wants this. See docs/phase6_notes.md.

     Greedy: input_ready also accepts while full whenever this cycle pops, restoring
     full-rate replacement at every depth including 1. The cost is that input_ready is
     then combinationally transparent to the downstream ready. Offered so that reusers
     with a short ready chain are not forced to buy a slot they do not need. *)
  let input_ready = active &: if greedy_admission then ~:full |: pop else ~:full in
  push <-- (valid &: input_ready &: ~:(bypass &: ready));
  { data = mux2 bypass data output; valid = output_valid; ready = input_ready }
[@@@ocamlformat "enable"]
