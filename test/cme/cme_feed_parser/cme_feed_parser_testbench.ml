(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "cme_feed_parser_testbench.ml" *)
(* Inactive Phase 0 top only. Transfers use before_edge, state observations after_edge. *)

open! Core
open! Hardcaml
open! Cme_of_hardcaml

module Dut = struct
  include Cme_feed_parser

  let create scope i = create ~config:Cme_config.default scope i
  let name = "cme_feed_parser"
end

module Fixture = Hardcaml_verif.Sim_fixture.Make (Dut)
module Step = Fixture.Step

module Output_snapshot = struct
  type t =
    { ready : bool
    ; control_ready : bool
    ; event_valid : bool
    ; event_is_zero : bool
    }
  [@@deriving sexp, equal, compare]
end

module Observation = struct
  type t =
    { before : Output_snapshot.t
    ; after : Output_snapshot.t
    }
  [@@deriving sexp, equal, compare]
end

let snapshot (o : Bits.t Dut.O.t) : Output_snapshot.t =
  { ready = Bits.to_bool o.ready_o
  ; control_ready = Bits.to_bool o.control_ready_o
  ; event_valid = Bits.to_bool o.event_valid_o
  ; event_is_zero = Bits.equal o.event_o (Bits.zero 677)
  }
;;

let run ?(data = Int64.of_string "0xfedcba9876543210") () =
  let testbench (handler : Step.Handler.t @ local) _ =
    let observations = ref [] in
    for case = 0 to 255 do
      let inputs : Bits.t Dut.I.t =
        { clock_i = Bits.gnd
        ; reset_i = Bits.vdd
        ; en_i = Bits.of_bool (case land 1 <> 0)
        ; data_i = Bits.of_int64_trunc ~width:64 data
        ; keep_i = Bits.of_int_trunc ~width:8 ((1 lsl (1 + (case lsr 5))) - 1)
        ; valid_i = Bits.of_bool (case land 2 <> 0)
        ; first_i = Bits.vdd
        ; last_i = Bits.vdd
        ; ingress_timestamp_i = Bits.of_string "64'h123456789abcdef0"
        ; session_reset_i = Bits.of_bool (case land 4 <> 0)
        ; resync_valid_i = Bits.of_bool (case land 8 <> 0)
        ; resync_next_seq_i = Bits.ones 32
        ; event_ready_i = Bits.of_bool (case land 16 <> 0)
        }
      in
      let record edge =
        observations
        := { Observation.before = snapshot (Step.O_data.before_edge edge)
           ; after = snapshot (Step.O_data.after_edge edge)
           }
           :: !observations
      in
      let reset_edge = Step.cycle handler inputs in
      record reset_edge;
      let held = { inputs with reset_i = Bits.gnd } in
      let first_edge = Step.cycle handler held in
      record first_edge;
      let second_edge = Step.cycle handler held in
      record second_edge
    done;
    List.rev !observations
  in
  Fixture.run_with_timeout ~timeout:780 ~testbench
;;
