(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "uart_frame_parser.ml" *)
(* Prototype parser for framing UART bytes as Ethernet-like transfers when Ethernet ingress
   is unavailable. Its input is expected to come from a FIFO containing UART beats. *)

open! Core
open! Hardcaml
open! Signal
open! Hardcaml_circuits

module I = struct
  type 'a t =
    { 
      clock   : 'a;
      reset   : 'a;

      uart_byte : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    {
      bruh : 'a;
    }
  [@@deriving hardcaml]
end

module I_Wires = struct
  type 'a t =
    {
      bruh1 : 'a;
    }
  [@@deriving hardcaml]
end

module I_Regs = struct
  type 'a t =
    {
      bruh2 : 'a;
    }
  [@@deriving hardcaml]
end

module States = struct
  type t = 
    | Wait_frame
    | Length_hi
    | Length_lo
    | Payload
  [@@deriving sexp_of, compare ~localize, enumerate]

  let width = Int.ceil_log2 (List.length all)

  let to_signal t =
    List.findi_exn all ~f:(fun _ v -> compare v t = 0)
    |> fst
    |> Signal.of_int_trunc ~width
  ;;
end

let create scope i : _ O.t =
  (* let _scope = Scope.subscope  *)

  let reset = i.I.reset in
  let clock = i.I.clock in
  let rising_edge = Reg_spec.create ~clock ~clear:reset ()  in


  (* roughly follows a state machine of 
  1. Wait_frame
    wait until data is available in the fifo

   *)




  { O.
    bruh = zero 1;
  }
