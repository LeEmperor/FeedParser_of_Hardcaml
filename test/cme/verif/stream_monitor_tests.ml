(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "stream_monitor_tests.ml" *)
(* Active negative tests for the shared stream contract monitor. *)

open! Core
open! Hardcaml
module F = Stream_test_support.Stream_fixture
open F

let idle = List.hd_exn (packet "x")

let test_monitor () =
  let reject f =
    check
      (try
         f ();
         false
       with
       | Failure _ -> true)
      "contract monitor failed to reject a violation"
  in
  let observe monitor ?(valid = true) ?(ready = true) beat =
    F.Monitor.observe monitor ~reset:false ~active:true ~valid ~ready beat
  in
  List.iter [ 0; 5; 0xfe ] ~f:(fun keep ->
    reject (fun () -> observe (F.Monitor.create ()) { idle with keep }));
  reject (fun () -> observe (F.Monitor.create ()) { idle with last = false });
  reject (fun () -> observe (F.Monitor.create ()) { idle with first = false });
  List.iter
    [ { idle with data = Bits.ones 64 }
    ; { idle with keep = 3 }
    ; { idle with first = false }
    ; { idle with last = false }
    ; { idle with timestamp = Bits.ones 64 }
    ]
    ~f:(fun changed ->
      let monitor = F.Monitor.create () in
      observe monitor ~ready:false idle;
      reject (fun () -> observe monitor changed));
  let monitor = F.Monitor.create () in
  observe monitor ~ready:false idle;
  reject (fun () -> observe monitor ~valid:false idle);
  F.Monitor.observe monitor ~reset:true ~active:false ~valid:false ~ready:false idle;
  observe monitor idle;
  check
    (String.equal (bytes (List.hd_exn (packet "abcdefgh"))) "abcdefgh")
    "byte source order"
;;

let%test_unit "reject illegal masks, framing and stalled offer changes" = test_monitor ()
