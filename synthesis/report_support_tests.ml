(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "report_support_tests.ml" *)
(* Failure-path regression tests run without Vivado or a license. *)

open! Core
open Report_support

let rejects f =
  match Or_error.try_with f with
  | Error _ -> ()
  | Ok _ -> failwith "report validation unexpectedly succeeded"
;;

let%test_unit "report stage requires place before route" =
  List.iter
    [ false, false, "post_synth"
    ; false, true, "post_synth"
    ; true, false, "post_place"
    ; true, true, "post_route"
    ]
    ~f:(fun (place, route, stage) ->
      let flags =
        { Reports.Command.Command_flags.default_flags with
          output_path = "/tmp/reports"
        ; place
        ; route
        }
      in
      let artifacts = report_artifacts ~flags ~name:"leaf" in
      [%test_result: string]
        artifacts.timing
        ~expect:("/tmp/reports/leaf/" ^ stage ^ "_leaf.timing"))
;;

let%test_unit "missing, empty and stale artifacts fail; fresh artifacts pass" =
  let directory = Filename_unix.temp_dir "cme-report-test" "" in
  let path name = Filename.concat directory name in
  let artifacts =
    { compact = path "compact"; utilization = path "util"; timing = path "timing" }
  in
  Exn.protect
    ~f:(fun () ->
      rejects (fun () -> read_required_report artifacts.compact);
      Out_channel.write_all artifacts.compact ~data:"";
      rejects (fun () -> read_required_report artifacts.compact);
      List.iter (artifact_paths artifacts) ~f:(fun path ->
        Out_channel.write_all path ~data:"fresh report");
      List.iter (artifact_paths artifacts) ~f:(fun path ->
        ignore (read_required_report path : string));
      require_refreshed_artifacts artifacts [ None; None; None ];
      let previous = List.map (artifact_paths artifacts) ~f:modification_time in
      rejects (fun () -> require_refreshed_artifacts artifacts previous);
      let older = List.map previous ~f:(Option.map ~f:(fun t -> t -. 1.)) in
      require_refreshed_artifacts artifacts older)
    ~finally:(fun () ->
      List.iter (artifact_paths artifacts) ~f:(fun path ->
        if Sys_unix.file_exists_exn path then Core_unix.unlink path);
      Core_unix.rmdir directory)
;;

let%test_unit "resource summary uses standard report rows and removes duplicates" =
  let row = "| Slice LUTs* | 12 | 0 | 0 | 63400 | 0.02 |" in
  [%test_result: (string * string * string * string) list]
    (utilization_rows (row ^ "\n" ^ row))
    ~expect:[ "Slice LUTs", "12", "63400", "0.02" ]
;;
