(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "packet_header.ml" *)
(* Collect the twelve-byte technical header using the two-beat aligner. Output is the
   ordered pre-sequence packet stream; idle includes buffered bytes. *)

open! Hardcaml
open Signal

module I = struct
  type 'a t =
    { (* Application domain; synchronous reset overrides the shared enable pause. *)
      clock_i : 'a
    ; reset_i : 'a
    ; en_i : 'a
    ; (* Framed low-byte-first UDP payload; timestamp is sampled on first only. *)
      data_i : 'a [@bits 64]
    ; keep_i : 'a [@bits 8]
    ; first_i : 'a
    ; last_i : 'a
    ; ingress_timestamp_i : 'a [@bits 64]
    ; valid_i : 'a
    ; (* Consumer of the packed pre-sequence packet stream. *)
      ready_i : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { ready_o : 'a
    ; valid_o : 'a
    ; (* Cme_types.Packet_item packed in declaration order. *)
      item_o : 'a [@bits Cme_types.packet_item_width]
    ; idle_o : 'a
    }
  [@@deriving hardcaml]
end

module State = struct
  type t =
    | Collecting (* accumulating the twelve-byte technical header *)
    | Body (* streaming header-stripped payload beats -> offset probably 4 *)
    | Header_only (* the packet was exactly twelve bytes; emit the empty marker *)
    | Short_header (* the packet ended before twelve bytes; emit the diagnostic *)
  [@@deriving sexp_of, compare ~localize, enumerate]
end

[@@@ocamlformat "disable"]
let create scope (i : _ I.t) =

  (* spec *)
  let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in

  (* local scoping *)
  let module T = Cme_types in

  (* readily assignmable here *)
  let active = i.en_i &: ~:(i.reset_i) -- "packet_header_active" in

  (* the state register [sm.current] is its q and [sm.is] hands back plain
     combinational signals, so the state is readable here even though the transitions are
     only compiled once the aligner outputs exist
  *)
  let sm = Always.State_machine.create (module State) spec ~enable:active in
  let _ : Signal.t = sm.current -- "packet_header_state" in

  (* forward references: these are inputs to the aligner instance below but their values
     are derived from that same instance's outputs, so they must be placeholders
  *)
  let consume_count = Signal.wire 4 -- "packet_header_consume_count" in
  let consume_valid = Signal.wire 1 -- "packet_header_consume_valid" in

  (* aligner instance *)
  let a =
    Byte_aligner.hierarchical
      ~max_consume:15
      scope
      { clock_i             = i.clock_i
      ; reset_i             = i.reset_i
      ; en_i                = i.en_i
      ; data_i              = i.data_i
      ; keep_i              = i.keep_i
      ; first_i             = i.first_i
      ; last_i              = i.last_i
      ; ingress_timestamp_i = i.ingress_timestamp_i
      ; valid_i             = i.valid_i
      ; consume_count_i     = consume_count
      ; consume_valid_i     = consume_valid
      }
  in

  (* are we collecting? *)
  let collecting = sm.is State.Collecting in

  (* const *)
  let required = of_int_trunc ~width:5 12 in

  (* above threshhold on the available bytes from the aligner upstream *)
  let enough = a.available_o >=: required in

  (* decision to grab the thing, composed together*)
  let collect = collecting &:
                a.valid_o &:
                (enough |: a.boundary_o)
  in

  (*  eight bytes ending the packet are still a short twelve-byte header;
      do not enter the second collector after consuming that boundary
      needs an error emission on the diagnotsic port
  *)
  let short = collect &: ~:enough in
  let header_only = a.boundary_o &: (a.available_o ==:. 12) in

(*
consider example: 32B payload = 12B header + 20B payload


  first (3) cycles are the 64b data beats saving up inside of the byte aligner itself
  cyc | in: vld rdy_o lst | out: vld kind fst lst keep data             seq      ts    idle
    1 |      1    1    0  |       0                                                      1
    2 |      1    1    0  |       0                                                      0
    3 |      1    1    0  |       0                                                      0

  here we get the sideband context items for seq number and a timestamp
  cyc | in: vld rdy_o lst | out: vld kind fst lst keep data             seq      ts    idle
    4 |      1    1    1  |       1    0   1   0   ff  f7f6f5f4f3f2f1f0 11223344 beef    0
    5 |      0    1    0  |       1    1   0   0   ff  fffefdfcfbfaf9f8                  0
    6 |      0    1    0  |       1    1   0   1   0f  00000000f3f2f1f0                  0
    7 |      0    1    0  |       0                                                      1


  in beat order once we get to beat 3, we have 16 Bytes available (the window is 2 beats wide)
  we latch in 12B into first_half and second_half, and timestamp grabs the ts

  we assert consume_count = 12 on the cycle 3 because we're consuming 12B of the window
  importantly this moves the offset to 4 of the byte aligner -> 8B is the amount we can eat at a time
    therefore, 8B are shifted out, and 4B remain in beat 1 (beat 0 is the poofed one)

    think of this in a "retirement" based scheme: we can only retire a whole 8B chunk at a time
    but we can "consume" any amount 0-15 at a time -> the offset cursor

    we "consume 12B" at the very beginning, which does incur a cycle to wait for stuff to accumulate even more - interesting point of optimization maybe
    this retires (1) whole beat - beat 0, and moves the offset cursor into beat 1 by 4
    one may notice that the payload now moves with this offset of 4 for the rest of it's time until the end where it can be anything (the last beat)

    the aligner exists to make this seem "normal" if that makes sense
*)

  (* min(8, available_o) *)
  let body_count =
    mux2
      (* if the available amount is geq 8? *)
      (a.available_o >=:. 8)

      (* pass 8 -> only masses of 8 are going to be passed *)
      (of_int_trunc ~width:5 8)

      (* grab the available downstream pass *)
      a.available_o
  in

  (* the available_o might not be necessary to grab here for a full comparator *)
  let body_last = a.boundary_o &: (a.available_o <=:. 8) in

  let body_valid = sm.is State.Body &:
                   a.valid_o &:
                   (a.available_o >=:. 8 |: a.boundary_o)
  in

  let valid = active &:
              (body_valid |: sm.is State.Header_only |: sm.is State.Short_header)
  in

  (* handshake! *)
  let transfer = valid &: i.ready_i in

  consume_valid <-- (collect |: (body_valid &: i.ready_i));

  consume_count
  <-- uresize (
    mux2
      (* if we're collecting header *)
      collecting

      (* then feed consume count with... *)
      (mux2
        (* do we have enough to consume? *)
         enough

         (* yes -> emit required amount correspondent with header consume = 12 *)
         required

         (* no -> emit the available we we're fed; this shouldn't go high = short_header pulse *)
         a.available_o

      (* else we consume the amount of body presented to us *)
      body_count
  ) ~width:4;

  (* state transition assignment *)
  Always.(compile
    [ sm.switch
        [ State.Collecting,
          [ when_ collect
              [ if_ short
                  [ sm.set_next State.Short_header ]
                  [ if_ header_only
                      [ sm.set_next State.Header_only ]
                      [ sm.set_next State.Body ] ] ] ]
        ; State.Body,         [ when_ (transfer &: body_last) [ sm.set_next State.Collecting ] ]
        ; State.Header_only,  [ when_ transfer [ sm.set_next State.Collecting ] ]
        ; State.Short_header, [ when_ transfer [ sm.set_next State.Collecting ] ]
        ] ]);

  let first_half =
    (* slice beat 0 out of the packet *)
    Signal.reg spec ~enable:(collect &: collecting) (select a.data_o ~high:63 ~low:0) -- "packet_header_first_half"
  in

  let second_half =
    (* slice the upper 32b from the window *)
    Signal.reg spec ~enable:collect (select a.data_o ~high:95 ~low:64) -- "packet_header_second_half"
  in

  (* snags the timestamp out of the aligner's timestamp port *)
  let timestamp = Signal.reg spec ~enable:(collect &: collecting) a.ingress_timestamp_o in

  (* error register *)
  let missing_offset =
    Signal.reg spec ~enable:short (a.packet_byte_offset_o +: uresize a.available_o ~width:16)
  in

  let started =
    reg_fb spec ~enable:active ~width:1 ~f:(fun q ->
        mux2
          collecting
          gnd (mux2
                 (transfer &: body_valid)
                 vdd
                 q
              )
      )
  in

  let context : _ T.Packet_context.t =
    { ingress_timestamp = timestamp
    ; source_id = gnd
    ; packet_seq = select first_half ~high:31 ~low:0
    ; sending_time = concat_msb [ second_half; select first_half ~high:63 ~low:32 ]
    ; packet_header_present = vdd
    ; channel_valid = gnd
    }
  in

  let empty = T.Packet_item.Of_signal.zero () in

  let keep =
    mux
      (uresize body_count ~width:4)
      (List.init 9 (fun n ->
           of_int_trunc ~width:8 ((1 lsl n) - 1)
         )
      )
  in

  let body =
    { empty with
      kind = mux2 started (of_int_trunc ~width:2 T.Packet_item_kind.body) (zero 2)
    ; context =
        T.Packet_context.Of_signal.mux2
          started
          (T.Packet_context.Of_signal.zero ())
          context
    ; beat =
        { data = Byte_aligner.mask_data (select a.data_o ~high:63 ~low:0) keep
        ; keep
        ; first = ~:started
        ; last = body_last
        }
    }
  in

  let marker = { empty with context; body_empty = vdd } in
  let diagnostic =
    { (T.Event.Of_signal.zero ()) with
      kind = of_int_trunc ~width:2 T.Event_kind.diagnostic
    ; packet = { (T.Packet_context.Of_signal.zero ()) with ingress_timestamp = timestamp }
    ; diagnostic_code = of_int_trunc ~width:8 T.Diagnostic_code.truncated_packet_header
    ; diagnostic_byte_offset = missing_offset
    }
  in

  let error =
    { empty with kind = of_int_trunc ~width:2 T.Packet_item_kind.diagnostic; diagnostic }
  in
  { O.ready_o = a.ready_o
  ; valid_o = valid
  ; item_o =
      T.Packet_item.Of_signal.pack
        (T.Packet_item.Of_signal.mux2
           (sm.is State.Short_header)
           error
           (T.Packet_item.Of_signal.mux2 (sm.is State.Header_only) marker body))
  ; idle_o = collecting &: (a.available_o ==:. 0)
  }
[@@@ocamlformat "enable"]

let hierarchical ?instance scope i =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical ?instance ~name:"cme_packet_header" ~scope create i
;;
