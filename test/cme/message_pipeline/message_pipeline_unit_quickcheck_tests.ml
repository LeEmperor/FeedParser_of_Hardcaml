(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "message_pipeline_unit_quickcheck_tests.ml" *)
(* Prefix alignment, bounded body recovery, context ordering, and seeded stream stress. *)

open! Core
open Message_pipeline_testbench

let diagnostics o =
  List.filter_map o.Observation.items ~f:(function
    | Diagnostic (_, h, code, _, offset) -> Some (h.offset, code, offset)
    | _ -> None)
;;

let%test_unit "literal asymmetric prefix and high-bit fields" =
  let o = run ~stalls:false [ packet 1L "\x0d\x00\x03\x00\x76\x98\x34\x12\xcd\xabxyz" ] in
  match o.items with
  | [ Message (_, h, "xyz") ] ->
    [%test_result: Header.t]
      h
      ~expect:
        { size = 13
        ; block = 3
        ; template = 0x9876
        ; schema = 0x1234
        ; version = 0xabcd
        ; present = true
        ; offset = 12
        }
  | _ -> assert false
;;

let%test_unit "zero, one, multiple messages and every prefix alignment and body tail" =
  let packets =
    packet 0L ""
    :: List.init 80 ~f:(fun n ->
      packet
        (Int64.of_int (n + 1))
        (message (String.make n 'p') ^ message ~block:3 "abc" ^ message ""))
  in
  List.iter [ run; Small.run; Tiny.run ] ~f:(fun run ->
    let o = run ~sink_block_until:60 packets in
    [%test_result: int] (List.length o.items) ~expect:240)
;;

let%test_unit "all partial prefixes drain only their packet" =
  let packets =
    List.concat_map
      (List.init 9 ~f:(( + ) 1))
      ~f:(fun n ->
        [ packet (Int64.of_int (n * 2)) (message "ok" ^ String.prefix (message "") n)
        ; packet (Int64.of_int ((n * 2) + 1)) (message "next")
        ])
  in
  let o = Tiny.run ~sink_block_until:80 packets in
  [%test_result: int]
    (List.count (diagnostics o) ~f:(fun (_, code, _) -> code = 5))
    ~expect:9
;;

let%test_unit "sizes below ten are untrustworthy, including a complete following prefix" =
  let packets =
    List.init 10 ~f:(fun size ->
      packet (Int64.of_int size) (message ~size "bad" ^ message "must be drained"))
  in
  let o = run packets in
  [%test_result: (int * int * int) list]
    (diagnostics o)
    ~expect:(List.init 10 ~f:(fun _ -> 12, 4, 12))
;;

let%test_unit "unsupported skip resumes on the next message at every offset" =
  let packets =
    List.init 33 ~f:(fun n ->
      packet
        (Int64.of_int n)
        (message ~template:123 (String.make n 'u') ^ message "supported"))
  in
  let o = run packets in
  [%test_result: int] (List.length o.items) ~expect:66;
  [%test_result: int]
    (List.count (diagnostics o) ~f:(fun (_, code, _) -> code = 6))
    ~expect:33
;;

let%test_unit "supported and unsupported truncation including prefix-only packet" =
  List.iter [ 42; 123 ] ~f:(fun template ->
    let packets =
      List.init 100 ~f:(fun n ->
        packet (Int64.of_int n) (message ~template ~size:65535 (String.make n 't')))
    in
    let o = Tiny.run packets in
    [%test_result: int]
      (List.count (diagnostics o) ~f:(fun (_, code, _) -> code = 5))
      ~expect:100;
    [%test_result: int]
      (List.count (diagnostics o) ~f:(fun (_, code, _) -> code = 6))
      ~expect:(if template = 123 then 100 else 0))
;;

let%test_unit "sequencer diagnostics retain position and invalid context" =
  let o =
    run
      ~sink_block_until:90
      [ short 8
      ; packet 10L (message "first")
      ; packet 13L (message ~template:99 "skip" ^ message "gap")
      ; packet 13L (message "duplicate")
      ; packet 14L (message "last")
      ]
  in
  [%test_result: int list]
    (List.map (diagnostics o) ~f:(fun (_, c, _) -> c))
    ~expect:[ 3; 1; 6; 2 ];
  [%test_result: bool list]
    (List.filter_map o.items ~f:(function
      | Message (c, _, _) -> Some c.channel_valid
      | _ -> None))
    ~expect:[ true; false; false ]
;;

let%test_unit "reset while disabled cancels held prefix, message and diagnostic" =
  List.iter [ 4; 10; 20; 45 ] ~f:(fun reset_at ->
    ignore
      (Tiny.run
         ~reset_at
         ~sink_block_until:80
         [ packet 1L (message (String.make 300 'a'))
         ; packet 3L (message ~template:99 "skip")
         ; packet 4L (message "ok")
         ]
       : Observation.t))
;;

let%test_unit "control fence waits for iterator and downstream owned work" =
  let first = packet 1L (message (String.make 100 'a')) in
  let o =
    Tiny.run
      ~stalls:false
      ~sink_block_until:100
      ~downstream_busy_until:250
      ~controls:[ control ~resync:90L 1 ]
      [ first; packet 90L (message "next") ]
  in
  [%test_result: int list] (List.map o.controls ~f:snd) ~expect:[ 16 ];
  assert (List.for_all o.controls ~f:(fun (cycle, _) -> cycle >= 250))
;;

let%test_unit "cut-through body and byte-source-like gaps" =
  let o = Tiny.run ~stalls:false [ packet 0L (message (String.make 4096 'a')) ] in
  assert o.cut_through;
  ignore
    (Tiny.run
       ~stalls:false
       ~beat_gap:7
       [ packet 1L (message "" ^ message "123456789")
       ; packet 2L (message ~size:50 "short")
       ]
     : Observation.t)
;;

let%test_unit "deterministic randomized messages, malformed tails, bubbles and pauses" =
  Quickcheck.test
    ~trials:25
    ~seed:(`Deterministic "phase3-message-walker")
    ~sexp_of:[%sexp_of: int]
    ~shrinker:Int.quickcheck_shrinker
    (Int.gen_incl 1 100000)
    ~f:(fun seed ->
      let random = Random.State.make [| seed |] in
      let packets =
        List.init 40 ~f:(fun seq ->
          let messages =
            List.init (Random.State.int random 9) ~f:(fun _ ->
              message
                ~template:(if Random.State.bool random then 42 else 123)
                ~block:(Random.State.int random 65536)
                ~version:(Random.State.int random 65536)
                (String.init (Random.State.int random 100) ~f:(fun _ ->
                   Char.of_int_exn (Random.State.int random 256))))
          in
          let tail =
            match Random.State.int random 4 with
            | 0 -> String.prefix (message "") (1 + Random.State.int random 9)
            | 1 -> message ~size:(Random.State.int random 10) "drain"
            | 2 -> message ~size:65535 "truncated"
            | _ -> ""
          in
          packet (Int64.of_int seq) (String.concat messages ^ tail))
      in
      ignore (Small.run ~seed packets : Observation.t))
;;

let%test_unit "partial prefixes at all eight starting alignments" =
  List.iter (List.init 8 ~f:Fn.id) ~f:(fun alignment ->
    let packets =
      List.init 9 ~f:(fun n ->
        packet
          (Int64.of_int n)
          (message (String.make alignment 'a') ^ String.prefix (message "") (n + 1)))
    in
    ignore (Tiny.run packets : Observation.t))
;;

let%test_unit "late truncation terminates a cut-through message without a false last" =
  let o =
    Tiny.run
      ~stalls:false
      ~beat_gap:2
      [ packet 1L (message ~size:6000 (String.make 4096 'a'))
      ; packet 2L (message "next")
      ]
  in
  assert o.cut_through;
  [%test_result: (int * int * int) list] (diagnostics o) ~expect:[ 12, 5, 4118 ]
;;

let%test_unit "large legal IPv4 UDP payload preserves high offset bits" =
  let o =
    Tiny.run
      ~stalls:false
      [ packet
          1L
          (message (String.make 65450 'a') ^ message ~template:99 "skip" ^ message "last")
      ]
  in
  [%test_result: (int * int * int) list] (diagnostics o) ~expect:[ 65472, 6, 65476 ]
;;

let%test_unit "message ABI, template range validation, and portable hierarchy" =
  let open Hardcaml in
  let open Cme_of_hardcaml in
  [%test_result: int] Cme_types.message_item_width ~expect:1079;
  let module P = Message_pipeline in
  let module C = Circuit.With_interface (P.I) (P.O) in
  let scope = Scope.create ~flatten_design:false () in
  let circuit =
    C.create_exn ~name:"message_wrapper" (P.create ~supported_templates:[ 42 ] scope)
  in
  let rtl =
    Rtl.create ~database:(Scope.circuit_database scope) Verilog [ circuit ]
    |> Rtl.full_hierarchy
    |> Rope.to_string
  in
  List.iter [ "cme_packet_pipeline"; "cme_sbe_message_iterator" ] ~f:(fun name ->
    assert (String.is_substring rtl ~substring:("module " ^ name ^ " (")));
  List.iter (P.I.to_list P.I.port_names) ~f:(fun name ->
    assert (String.is_suffix name ~suffix:"_i"));
  List.iter (P.O.to_list P.O.port_names) ~f:(fun name ->
    assert (String.is_suffix name ~suffix:"_o"));
  List.iter [ -1; 65536 ] ~f:(fun id ->
    assert (
      Exn.does_raise (fun () ->
        C.create_exn
          ~name:"invalid"
          (P.create ~supported_templates:[ id ] (Scope.create ())))))
;;
