(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "stream_foundation_testbench.ml" *)
(* Shared Step scenarios and typed transfer observations. *)

open! Core
module Scenarios = Cme_verif.Stream_scenarios
module Observation = Scenarios.Observation
module Beat = Scenarios.Beat

let run ?seed ?payloads ?(continuous = false) ?(shim_gaps = false) ?(resets = true) depth =
  Scenarios.run ?seed ?payloads ~depth ~pass:true ~continuous ~shim_gaps ~resets ()
;;

let run_literal () =
  run
    ~payloads:[ "\x10\x32\x54\x76\x98\xba\xdc\xfe"; "abc" ]
    ~continuous:true
    ~resets:false
    3
;;
