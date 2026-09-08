(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "byte_aligner.ml" *)
(* Three stored beats; the leading two expose a low-byte-first peek window

   An accepted consume retires up to eight bytes by default, or up to fifteen with
   create_with_limit; filling a free slot may extend the window without consuming anything

   A following packet can occupy slot 1 or slot 2 but is never visible in the current
   window

   ready_o reads occupied_slot_count directly and never this cycle's consume decision, so
   admission is a purely registered decision. The third slot is what buys that at full
   rate; see docs/phase6_notes.md
*)

open! Hardcaml
open! Signal

module I = struct
  type 'a t =
    { (* Application clock; synchronous reset overrides enable. *)
      clock_i : 'a
    ; reset_i : 'a
    ; en_i : 'a
    ; (* Ingress_beat fields; timestamp is meaningful on first only. *)
      data_i : 'a [@bits 64]
    ; keep_i : 'a [@bits 8]
    ; first_i : 'a
    ; last_i : 'a
    ; ingress_timestamp_i : 'a [@bits 64]
    ; valid_i : 'a
    ; (* A command transfers on consume_valid_i && consume_ready_o. *)
      consume_valid_i : 'a
    ; consume_count_i : 'a [@bits 4]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { ready_o : 'a
    ; (* Peek interface, not a ready/valid output beat. Available bytes can grow during a
         stall; already available bytes and their context remain stable. *)
      valid_o : 'a
    ; data_o : 'a [@bits 128]
    ; available_o : 'a [@bits 5]
    ; boundary_o : 'a
    ; first_o : 'a
    ; ingress_timestamp_o : 'a [@bits 64]
    ; packet_byte_offset_o : 'a [@bits 16]
    ; consume_ready_o : 'a
    }
  [@@deriving hardcaml]
end

[@@@ocamlformat "disable"]
(*
   0000_0001 -> 1
   0001_0101 -> 5

  prio encoder pattern; timing pending
*)
let byte_count keep =
  (* Legal masks are nonzero contiguous low lanes; the testbench checks this contract *)
  List.init 8 (fun n ->
      mux2
        (bit keep ~pos:n) (* is the bit in the keep mask true? *)

        (* yes - add to n *)
        (of_int_trunc ~width:4 (n + 1)) (* forms [1; 2; 3; 4; 5; 6; 7; 8] *)
        (zero 4)
    )

  |> List.fold_left (fun count next -> mux2 (next <>:. 0) next count) (zero 4)
;;

let mask_data data keep =
  List.init 8 (fun n -> (* 8 items of the byte slicer out of the data, smashed back together via concat_lsb *)
    mux2 (bit keep ~pos:n) (select data ~high:((n * 8) + 7) ~low:(n * 8)) (zero 8))
  |> concat_lsb
;;

let create_with_limit ~max_consume (_scope : Scope.t) (i : _ I.t) =
  if max_consume < 1 || max_consume > 15 then invalid_arg "aligner consume limit must be 1..15";
  (* spec *)
  let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in

  (* en really ought to be removed; will see if there are timing implications *)
  let active = (i.en_i &: ~:(i.reset_i)) -- "active" in

  (* local aliases *)
  let module B = Cme_types.Ingress_beat in

  (* compose the input *)
  (* this is basically just composing many structs together in SV *)
  let input =
    (* pack the entire record into a flat vector *)
    B.Of_signal.pack

      (* structured record of Signal.t fields *)
      { beat =
          { data    = mask_data i.data_i i.keep_i
          ; keep    = i.keep_i
          ; first   = i.first_i
          ; last    = i.last_i
          }
      ; ingress_timestamp = (* later on more formatted timestamping may be used; Timestamp.t may be necessary *)
          mux2
            (* are we the first? *)
            i.first_i

            (* timestamp *)
            i.ingress_timestamp_i

            (* zilch *)
            (zero 64)
      }
  in

  (* a single pulse contains the Beat.t item, as well as a timestamp;
     we need storage for (3) of these at a time: (2) to shift in a new one and hold
     un-consumed residue from n-1, plus a spare behind them so that admission can be
     decided from the registered count alone. Only slot0 and slot1 are ever peeked
  *)
  let slot_width      = Signal.width input in
  let slot0, slot1, slot2 =
    Signal.wire slot_width, Signal.wire slot_width, Signal.wire slot_width
  in

  (* Byte counts held alongside their slots; see the register assignments below. *)
  let slot0_bytes, slot1_bytes, slot2_bytes =
    Signal.wire 4, Signal.wire 4, Signal.wire 4
  in

  (* number of occupied slots in the "accumulator" *)
  (* this is the main stateful item;
      00 - no occupied slots
      01 - head occupied (slot0)
      10 - head and tail occupied (slot0 and slot1 respectiveuly)
      11 - head, tail and the spare occupied; slot2 is storage only and is never
           visible in the peek window
*)
  let occupied_slot_count           = Signal.wire 2 in

  (* number of bytes already consumed from the header beat *)
  let offset          = Signal.wire 3 in

  (* in terse, this "re-names" the fields present in the Signal construction;
     enables us to do things like head.beat.data, and having field-named struct
  *)
  let head, tail =
    B.Of_signal.unpack slot0,
    B.Of_signal.unpack slot1
  in

  (* are any of the slots used?  *)
  (* foramlly provable that occupied_slot_count cannot be 11? *)
  let occupied  = (occupied_slot_count <>:. 0) -- "occupied" in

  (* only when the head is NOT the last, and both window slots are occupied can we expand
     the window; slot2 sits behind the window, so two and three occupied both qualify *)
  let join_tail = (occupied_slot_count >=:. 2 &:
                  ~:(head.beat.last)) -- "join_tail" in

  (* figures out the valid bytes from head that weren't consumed in a given cycle *)
  let remaining =
    (uresize slot0_bytes ~width:5 -:
    (uresize offset ~width:5)) -- "remaining"
  in

  (*
      consider example:
        head.keep = 00001_1111 -> byte_count = 5
        offset = 2
        remaining = 3 (composed from byte_count - offset)



    if (~occupied) then
      0
    else if (join_tail) then
      remaining_head_bytes + valid_tail_bytes
    else
      remaining_head_bytes
*)

  (* how much of the tail is avilable (as a count), but only if we need the tail
      this adds an extra layer of checking on join_tail, which may have timing implications
  *)
  let tail_available =
    mux2
        (* tail to be used? *)
        join_tail

        (* yes - add valid_tail_bytes *)
        (uresize slot1_bytes ~width:5)

        (* no - add nothing *)
        (zero 5)
    -- "tail_available"
  in

  let stored_available = (remaining +: tail_available) -- "stored_available" in

  (* 5b combinational count of how many consecutive unread bytes, starting at
      data_o byte lane 0, currently belong to this packet and are valid to consume?


    describes the aligner's currently registered state



    example:

      beat 1 - head has 8 valid bytes = head.keep = 0b1111_1111, offset happens to be 3

        byte_count(head.keep) = 8
        remaining = 8 - 3 = 5


        (5) lowest bytes in data_o are "valid"


    example - residue of same packet, different beat
        head remaining = 5 (head.keep = 0b0001_0000)
        byte_count(head.keep) = 5
        byte_count(tail.keep) = 6
          now join_tail = 1

      and thus available = 5 + 6


    in the case of both slots occupied, and the head being marked last, then we reasonably know
        (count ==. 2) &: (head.beat.last) => boundary area somewhat (notably join_tail is based on ~head.beat.last)
    the tail to be the first beat of the next packet
      purposely discludes the tail from processing across this boundary

  *)
  let (available : t) = (* a count of *)
    mux2

      (* is there a head beat stored? *)
      occupied

      (* yes - use the stored = unread bytes in head + valid bytes in tail, IF the tail can be joined *)
      stored_available

      (* no - zero on it *)
      (zero 5)
    -- "available"
  in

  let boundary =
    (* join_Tail, head and tail last might be needed for another compsition; will figure later *)
    (occupied &:
    (head.beat.last |: (join_tail &: tail.beat.last))) (* last head and tail and join_tail and occupied *)
    -- "boundary"
  in

  (* valid and things present *)
  let valid       = (active &: (occupied : t)) -- "valid" in
  let requested   = (uresize i.consume_count_i ~width:5) -- "requested" in

  let consume_ready =
    (valid &:
    (requested <=:. max_consume) &:
    (requested <=: available)) -- "consume_ready"
  in

  let consume = (consume_ready &:
                i.consume_valid_i &:
                (requested <>:. 0)) -- "consume"
  in

  (* pop the head only if we're to consume, and the requested amount if geq than the remainging *)
  let pop_head = (consume &: (requested >=: remaining)) -- "pop_head" in

  (* requires perfect alignment on requested and available amounts *)
  let pop_tail = (pop_head &: join_tail &: (requested ==: available)) -- "pop_tail" in

  (* number of things we're grabbing out *)
  let pops =
    mux2
      pop_tail
      (of_int_trunc ~width:2 2)
      (uresize pop_head ~width:2)
    -- "pops"
  in

  (* how much we have - how much we're taking out leaves retinaed *)
  let retained = (occupied_slot_count -: pops) -- "retained" in

  (* Non-greedy admission. This reads the count REGISTER, not retained, so ready_o carries
     no dependency on this cycle's consume_count_i and becomes a fresh launch point rather
     than a hop in a chain of combinationally transparent readies.

     The third slot is a correctness requirement of that rule, not headroom. With two slots
     the occupancy would oscillate 1 -> 2 -> 1, and in every count == 1 cycle the window
     holds only the head, so available <= 8 - too little for packet_header's twelve-byte
     collect or for either max_consume:15 consumer, and the stage would accept a beat only
     every other cycle. At three slots the steady state parks at two occupied and the
     head-plus-tail window stays full. See docs/phase6_notes.md. *)
  let ready = (active &: (occupied_slot_count <:. 3)) -- "ready" in

  (* handshake *)
  let push = (ready &: i.valid_i) -- "push" in

  occupied_slot_count <-- reg spec ~enable:active (retained +: uresize push ~width:2) -- "occupied_slot_count";

  (* Retiring shifts every slot down by pops, so slot n takes slot (n + pops). pop_tail
     implies pop_head, so pops is 2 exactly when pop_tail and 1 exactly when pop_head
     without it. Positions past retained are don't-care and simply hold the spare. *)
  let next_head =
    mux2
      (* both window slots retire - the spare becomes the head *)
      pop_tail
      slot2
      (mux2
         (* if the head is being removed *)
         pop_head
         (* move slot 1 into next slot 0 *)
         slot1
         (* else - doesnt matter *)
         slot0)
    -- "next_head"
  in

  (* slot (1 + pops): the spare for one or two pops, and two pops leaves it don't-care *)
  let next_mid = mux2 pop_head slot2 slot1 -- "next_mid" in

  let next_slot0 =
    mux2
      (* are we actually moving teh aligner along? *)
      (push &: (retained ==:. 0))

      (* yes - move the next beat being presented off the input vector in *)
      input

      (* *)
      next_head
    -- "next_slot0"
  in

  let next_slot1 =
    mux2
      (push &: (retained ==:. 1))
      input
      next_mid
    -- "next_slot1"
  in

  (* ready holds occupied_slot_count <= 2 whenever push is set, so retained <= 2 and this
     is the last position an accepted beat can land in. slot (2 + pops) is only meaningful
     with no pops, so the spare otherwise just holds. *)
  let next_slot2 =
    mux2
      (push &: (retained ==:. 2))
      input
      slot2
    -- "next_slot2"
  in

  slot0 <-- Signal.reg spec ~enable:active next_slot0 -- "slot0";
  slot1 <-- Signal.reg spec ~enable:active next_slot1 -- "slot1";
  slot2 <-- Signal.reg spec ~enable:active next_slot2 -- "slot2";

  (* byte_count is a priority encoder over the keep mask. Evaluating it from the
     REGISTERED slot puts it at the head of the critical path, ahead of the whole
     available -> consume_ready -> consume -> pop_head -> pop_tail -> retained
     chain; Vivado showed every one of the ten worst paths launching from a single
     keep bit because of it. These registers evaluate it in the cycle the beat is
     WRITTEN instead, where there is slack.

     This adds no latency and changes no behaviour: <slot>_bytes becomes valid on
     exactly the same edge as <slot>, so every consumer sees the count at the same
     time it sees the data. On reset both clear to zero, and byte_count of a zero
     keep mask is zero, so the invariant holds from cycle one.

     The muxes below MIRROR next_slot0 / next_slot1 / next_slot2 exactly - same
     conditions, same sources, same enable. If they ever diverge the aligner silently
     mis-sizes its window, which is invisible at the port boundary until a specific beat
     pattern hits, so byte_aligner_invariant_tests.ml asserts
     <slot>_bytes = byte_count <slot>.keep on every cycle. Any change to
     next_slot0 / next_slot1 / next_slot2 must be made here too. *)
  let input_bytes = byte_count i.keep_i -- "input_bytes" in

  (* mirrors next_head = mux2 pop_tail slot2 (mux2 pop_head slot1 slot0) *)
  let next_head_bytes =
    mux2 pop_tail slot2_bytes (mux2 pop_head slot1_bytes slot0_bytes)
    -- "next_head_bytes"
  in

  (* mirrors next_mid = mux2 pop_head slot2 slot1 *)
  let next_mid_bytes = mux2 pop_head slot2_bytes slot1_bytes -- "next_mid_bytes" in

  (* mirrors next_slot0 = mux2 (push &: (retained ==:. 0)) input next_head *)
  let next_slot0_bytes =
    mux2 (push &: (retained ==:. 0)) input_bytes next_head_bytes -- "next_slot0_bytes"
  in

  (* mirrors next_slot1 = mux2 (push &: (retained ==:. 1)) input next_mid *)
  let next_slot1_bytes =
    mux2 (push &: (retained ==:. 1)) input_bytes next_mid_bytes -- "next_slot1_bytes"
  in

  (* mirrors next_slot2 = mux2 (push &: (retained ==:. 2)) input slot2 *)
  let next_slot2_bytes =
    mux2 (push &: (retained ==:. 2)) input_bytes slot2_bytes -- "next_slot2_bytes"
  in

  slot0_bytes <-- Signal.reg spec ~enable:active next_slot0_bytes -- "slot0_bytes";
  slot1_bytes <-- Signal.reg spec ~enable:active next_slot1_bytes -- "slot1_bytes";
  slot2_bytes <-- Signal.reg spec ~enable:active next_slot2_bytes -- "slot2_bytes";

  let next_offset =
    mux2
      pop_tail
      (zero 3)
      (mux2
         pop_head
         (uresize (requested -: remaining) ~width:3)
         (offset +: uresize requested ~width:3))
    -- "next_offset"
  in

  offset <-- reg spec ~enable:consume next_offset -- "offset";

  (* consumer of boundary *)
  let packet_end = (consume &: boundary &: (requested ==: available)) -- "packet_end" in

  (* assignment group for next offset of the packet *)
  let packet_offset =
    reg_fb spec
      ~enable:consume
      ~width:16
      ~f:(fun q ->
        mux2
          (* if packet_end *)
          packet_end
          (* then perfect zero *)
          (zero 16)

          (* else requested offset for next *)
          (q +: uresize requested ~width:16)
      )
    -- "packet_offset"
  in

  let first = (occupied &: head.beat.first &: (offset ==:. 0)) -- "first" in

  (* timestamp reg accepts on consume AND first; possible gated enable might not be the best *)
  let timestamp = Signal.reg spec ~enable:(consume &: first) head.ingress_timestamp -- "timestamp" in

  (* large combo vector of the head and tail -> only grabs the tail if the tail is necessary *)
  let window =
    let tail_data = mux2
            (* if join_tail -> residue has useful data in it *)
            join_tail

            (* tail data *)
            tail.beat.data

            (* no - concat zero *)
            (zero 64) in
    concat_msb [ tail_data; head.beat.data ] -- "window"
  in

  let aligned =
    (* 8-lane candidate creation, indexed into by the offset calculated previously *)
    mux
      offset
      (List.init 8 (fun n ->
           srl window ~by:(n * 8)
                   )
      )
    -- "aligned"
  in

  { O.ready_o = ready
  ; valid_o = valid
  ; data_o = mux2 occupied aligned (zero 128)
  ; available_o = available
  ; boundary_o = boundary
  ; first_o = first
  ; ingress_timestamp_o = mux2 first head.ingress_timestamp timestamp
  ; packet_byte_offset_o = packet_offset
  ; consume_ready_o = consume_ready
  }
[@@@ocamlformat "enable"]

let create = create_with_limit ~max_consume:8

let hierarchical ?(max_consume = 8) ?instance scope i =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical
    ?instance
    ~name:"cme_byte_aligner"
    ~scope
    (create_with_limit ~max_consume)
    i
;;
