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
    | Body (* streaming header-stripped payload beats *)
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

  (* The state register. [sm.current] is its q and [sm.is] hands back plain
     combinational signals, so the state is readable here even though the transitions are
     only compiled once the aligner outputs exist. *)
  let sm = Always.State_machine.create (module State) spec ~enable:active in
  let _ : Signal.t = sm.current -- "packet_header_state" in

  (* Forward references: these are inputs to the aligner instance below but their values
     are derived from that same instance's outputs, so they must be placeholders. *)
  let consume_count = Signal.wire 4 -- "packet_header_consume_count" in
  let consume_valid = Signal.wire 1 -- "packet_header_consume_valid" in

  let a =
    Byte_aligner.hierarchical
      ~max_consume:15
      scope
      { clock_i = i.clock_i
      ; reset_i = i.reset_i
      ; en_i = i.en_i
      ; data_i = i.data_i
      ; keep_i = i.keep_i
      ; first_i = i.first_i
      ; last_i = i.last_i
      ; ingress_timestamp_i = i.ingress_timestamp_i
      ; valid_i = i.valid_i
      ; consume_count_i = consume_count
      ; consume_valid_i = consume_valid
      }
  in
  let collecting = sm.is State.Collecting in
  let required = of_int_trunc ~width:5 12 in
  let enough = a.available_o >=: required in
  let collect = collecting &: a.valid_o &: (enough |: a.boundary_o) in
  (* Eight bytes ending the packet are still a short twelve-byte header. Do not enter the
     second collector after consuming that boundary. *)
  let short = collect &: ~:enough in
  let header_only = a.boundary_o &: (a.available_o ==:. 12) in
  let body_count = mux2 (a.available_o >=:. 8) (of_int_trunc ~width:5 8) a.available_o in
  let body_last = a.boundary_o &: (a.available_o <=:. 8) in
  let body_valid = sm.is State.Body &: a.valid_o &: (a.available_o >=:. 8 |: a.boundary_o) in
  let valid = active &: (body_valid |: sm.is State.Header_only |: sm.is State.Short_header) in
  let transfer = valid &: i.ready_i in
  consume_valid <-- (collect |: (body_valid &: i.ready_i));
  consume_count
  <-- uresize (mux2 collecting (mux2 enough required a.available_o) body_count) ~width:4;
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
    reg spec ~enable:(collect &: collecting) (select a.data_o ~high:63 ~low:0)
  in
  let second_half = reg spec ~enable:collect (select a.data_o ~high:95 ~low:64) in
  let timestamp = reg spec ~enable:(collect &: collecting) a.ingress_timestamp_o in
  let missing_offset =
    reg spec ~enable:short (a.packet_byte_offset_o +: uresize a.available_o ~width:16)
  in
  let started =
    reg_fb spec ~enable:active ~width:1 ~f:(fun q ->
      mux2 collecting gnd (mux2 (transfer &: body_valid) vdd q))
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
      (List.init 9 (fun n -> of_int_trunc ~width:8 ((1 lsl n) - 1)))
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
