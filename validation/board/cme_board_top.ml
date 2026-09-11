(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "cme_board_top.ml" *)
(* Arty A7-100T receive harness for the CME MDP 3.0 feed parser: MII PHY -> Ethernet MAC
   -> IPv4 -> UDP -> destination-port selection -> parser -> counters -> USB UART.

   The networking stack enters as ONE external instantiation of [udp_rx_64_mac_top],
   elaborated from Verilog that hardcaml_networking emits from its own committed
   `udp-rx-64` generator. Nothing CME-specific lives in that repository and this file
   takes no OCaml dependency on it, so the two projects are coupled only by a generated
   RTL file whose revision and hash the board report records.

   Controls: btn[0] resets, sw[0] enables reception, sw[3:1] selects which counter's low
   nibble reaches led[3:0]. The PHY reference clock and the UART keep running while sw[0]
   is low, so pausing ingress freezes the counters without truncating a status record.

   Clocking: the parser runs in the PHY's 25 MHz tx-clock domain, shared with the UDP
   application stream, so the design contains NO parser clock-domain crossing -- the only
   crossing is the async receive FIFO already inside the networking stack. That is
   deliberate. MII at 100 Mb/s occupies roughly 6% of the parser's capacity at 25 MHz, so
   a faster parser clock would buy no functional coverage while adding a crossing whose
   failures would present as parser bugs. *)

open! Core
open! Hardcaml
open! Signal
module I = Board_top.I
module O = Board_top.O

(* Emitted by hardcaml_networking: dune exec lib/common/generate.exe -- udp-rx-64 *)
let network_module = "udp_rx_64_mac_top"

let create ?dest_port ?uart_divisor ?snapshot_cycles (scope : Scope.t) (i : _ I.t) : _ O.t
  =
  let rst = bit i.btn ~pos:0 in
  let sys_rst = Board_scaffolding.reset_sync ~clock:i.clk100mhz ~async_rst:rst in
  let rx_rst = Board_scaffolding.reset_sync ~clock:i.eth_rx_clk ~async_rst:rst in
  let tx_rst = Board_scaffolding.reset_sync ~clock:i.eth_tx_clk ~async_rst:rst in
  let spec100 = Reg_spec.create ~clock:i.clk100mhz ~clear:sys_rst () in
  let spec_tx = Reg_spec.create ~clock:i.eth_tx_clk ~clear:tx_rst () in
  let en = Board_scaffolding.sync2 ~spec:spec_tx (bit i.sw ~pos:0) in
  let display = Board_scaffolding.sync2 ~spec:spec_tx (select i.sw ~high:3 ~low:1) in
  (* The PHY reference clock is driven unconditionally: gating it on [en] would drop the
     link every time reception is paused. *)
  let ref_clk =
    Board_scaffolding.eth_ref_clk ~scope ~clk100mhz:i.clk100mhz ~sys_rst ~en:vdd
  in
  let phy = Board_scaffolding.phy_hard_reset ~spec100 ~sys_rst in
  let heartbeat =
    Board_scaffolding.heartbeat ~scope ~clk100mhz:i.clk100mhz ~sys_rst ~spec100
  in
  let ready = wire 1 in
  (* Only the outputs this harness consumes are bound; the stack's remaining status ports
     (src/dst IP, lengths, the rx-domain MAC status) are left unconnected on purpose. *)
  let network =
    Instantiation.create
      ()
      ~name:network_module
      ~instance:"network"
      ~inputs:
        [ "rx_clock_i", i.eth_rx_clk
        ; "rx_reset_i", rx_rst
        ; "rx_dv_i", i.eth_rx_dv
        ; "rx_er_i", i.eth_rxerr
        ; "rx_data_i", i.eth_rxd
        ; "tx_clock_i", i.eth_tx_clk
        ; "tx_reset_i", tx_rst
        ; "en_i", en
        ; "app_tready_i", ready
        ]
      ~outputs:
        [ "app_tdata_o", 64
        ; "app_tkeep_o", 8
        ; "app_tvalid_o", 1
        ; "app_tfirst_o", 1
        ; "app_tlast_o", 1
        ; "dst_port_o", 16
        ; "rx_frame_done_o", 1
        ; "crc_error_o", 1
        ; "checksum_ok_o", 1
        ; "udp_busy_o", 1
        ]
  in
  let net = Instantiation.output network in
  let core =
    Cme_validation_core.hierarchical
      ?dest_port
      ?uart_divisor
      ?snapshot_cycles
      scope
      { clock_i = i.eth_tx_clk
      ; reset_i = tx_rst
      ; en_i = en
      ; data_i = net "app_tdata_o"
      ; keep_i = net "app_tkeep_o"
      ; valid_i = net "app_tvalid_o"
      ; first_i = net "app_tfirst_o"
      ; last_i = net "app_tlast_o"
      ; dst_port_i = net "dst_port_o"
      ; rx_frame_done_i = net "rx_frame_done_o"
      ; crc_error_i = net "crc_error_o"
      ; checksum_ok_i = net "checksum_ok_o"
      ; display_i = display
      }
  in
  ready <-- core.ready_o;
  { O.led = core.led_o
  ; led0_r = heartbeat.toggle
  ; led0_g = core.update_seen_o
  ; led0_b = gnd
  ; led1_r = gnd
  ; led1_g = phy.ready
  ; led1_b = net "udp_busy_o"
  ; led2_r = core.network_error_seen_o
  ; led2_g = net "checksum_ok_o"
  ; led2_b = gnd
  ; led3_r = core.diagnostic_seen_o
  ; led3_g = gnd
  ; led3_b = gnd
  ; uart_rxd_out = core.uart_o
  ; eth_mdc = gnd
  ; eth_rstn = msb phy.cnt
  ; (* Receive-only harness: the MII transmit pins are parked. *)
    eth_ref_clk = ref_clk.dst_clk
  ; eth_tx_en = gnd
  ; eth_txd = zero 4
  }
;;
