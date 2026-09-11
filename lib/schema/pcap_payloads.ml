(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "pcap_payloads.ml" *)
(* Minimal classic-PCAP Ethernet/IPv4/UDP payload extraction for golden fixtures. *)

open! Core

exception Pcap_error of string

type endian =
  | Little
  | Big

type timestamp_resolution =
  | Microseconds
  | Nanoseconds

type payload =
  { ingress_timestamp : int64
  ; bytes : string
  }
[@@deriving equal, sexp]

let byte bytes offset = Char.to_int bytes.[offset]

let u16 endian bytes offset =
  match endian with
  | Little -> byte bytes offset lor (byte bytes (offset + 1) lsl 8)
  | Big -> (byte bytes offset lsl 8) lor byte bytes (offset + 1)
;;

let u32 endian bytes offset =
  let b index = Int64.of_int (byte bytes (offset + index)) in
  match endian with
  | Little ->
    Int64.bit_or
      (b 0)
      (Int64.bit_or
         (Int64.shift_left (b 1) 8)
         (Int64.bit_or (Int64.shift_left (b 2) 16) (Int64.shift_left (b 3) 24)))
  | Big ->
    Int64.bit_or
      (Int64.shift_left (b 0) 24)
      (Int64.bit_or
         (Int64.shift_left (b 1) 16)
         (Int64.bit_or (Int64.shift_left (b 2) 8) (b 3)))
;;

let require bytes offset count description =
  if offset < 0 || count < 0 || offset + count > String.length bytes
  then raise (Pcap_error (sprintf "truncated %s at byte %d" description offset))
;;

let udp_payload frame =
  require frame 0 14 "Ethernet header";
  let ether_type = ref (u16 Big frame 12) in
  let ip_start = ref 14 in
  if !ether_type = 0x8100 || !ether_type = 0x88a8
  then (
    require frame 14 4 "VLAN header";
    ether_type := u16 Big frame 16;
    ip_start := 18);
  if !ether_type <> 0x0800
  then None
  else (
    require frame !ip_start 20 "IPv4 header";
    let version_ihl = byte frame !ip_start in
    if version_ihl lsr 4 <> 4
    then raise (Pcap_error "EtherType IPv4 frame has a non-IPv4 header");
    let ihl = version_ihl land 0x0f * 4 in
    require frame !ip_start ihl "IPv4 options";
    let total_length = u16 Big frame (!ip_start + 2) in
    if total_length < ihl + 8 then raise (Pcap_error "invalid IPv4 total length for UDP");
    require frame !ip_start total_length "IPv4 packet";
    let fragmented = u16 Big frame (!ip_start + 6) land 0x3fff <> 0 in
    if fragmented || byte frame (!ip_start + 9) <> 17
    then None
    else (
      let udp_start = !ip_start + ihl in
      let udp_length = u16 Big frame (udp_start + 4) in
      if udp_length < 8 || udp_length > total_length - ihl
      then raise (Pcap_error "invalid UDP length");
      Some (String.sub frame ~pos:(udp_start + 8) ~len:(udp_length - 8))))
;;

let of_string bytes =
  require bytes 0 24 "PCAP global header";
  let magic = String.sub bytes ~pos:0 ~len:4 in
  let endian, resolution =
    match String.to_list magic |> List.map ~f:Char.to_int with
    | [ 0xd4; 0xc3; 0xb2; 0xa1 ] -> Little, Microseconds
    | [ 0xa1; 0xb2; 0xc3; 0xd4 ] -> Big, Microseconds
    | [ 0x4d; 0x3c; 0xb2; 0xa1 ] -> Little, Nanoseconds
    | [ 0xa1; 0xb2; 0x3c; 0x4d ] -> Big, Nanoseconds
    | _ -> raise (Pcap_error "unsupported PCAP magic (pcapng is not classic PCAP)")
  in
  if u16 endian bytes 4 <> 2 then raise (Pcap_error "unsupported PCAP major version");
  if Int64.to_int_exn (u32 endian bytes 20) <> 1
  then raise (Pcap_error "only Ethernet classic-PCAP captures are supported");
  let scale =
    match resolution with
    | Microseconds -> 1_000L
    | Nanoseconds -> 1L
  in
  let rec records offset result =
    if offset = String.length bytes
    then List.rev result
    else (
      require bytes offset 16 "PCAP record header";
      let seconds = u32 endian bytes offset in
      let fraction = u32 endian bytes (offset + 4) in
      let captured_length = u32 endian bytes (offset + 8) |> Int64.to_int_exn in
      let frame_start = offset + 16 in
      require bytes frame_start captured_length "PCAP frame";
      let frame = String.sub bytes ~pos:frame_start ~len:captured_length in
      let result =
        match udp_payload frame with
        | None -> result
        | Some payload ->
          { ingress_timestamp = Int64.((seconds * 1_000_000_000L) + (fraction * scale))
          ; bytes = payload
          }
          :: result
      in
      records (frame_start + captured_length) result)
  in
  records 24 []
;;

let load filename = In_channel.read_all filename |> of_string

let decode decoder payloads =
  List.concat_map payloads ~f:(fun payload ->
    Golden_decoder.decode_payload
      ~ingress_timestamp:payload.ingress_timestamp
      decoder
      payload.bytes)
;;
