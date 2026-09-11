(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "schema_descriptor_generator.ml" *)
(* Dune build-time entry point for deterministic schema descriptor generation. *)

open! Core

let command =
  Command.basic
    ~summary:"Generate a hardware extraction descriptor from a pinned CME SBE schema"
    (let%map_open.Command schema =
       flag "schema" (required string) ~doc:"FILE pinned templates.xml"
     and template = flag "template" (required string) ~doc:"NAME selected template name"
     and output = flag "output" (required string) ~doc:"FILE generated OCaml output" in
     fun () ->
       let descriptor = Cme_schema.Mbp_descriptor.load schema ~template_name:template in
       Cme_schema.Schema_codegen.write descriptor output)
;;

let () = Command_unix.run command
