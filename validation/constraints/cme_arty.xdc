# Constraints File: "cme_arty.xdc"
# University of Florida
# Author: Bohdan Purtell
#
# Arty A7-100T constraints for cme_board_top, the CME feed-parser validation harness.
# Port names align with Board_top.I/O exactly.
#
# DP83848x PHY, MII interface, 100 Mbps (eth_rx_clk = eth_tx_clk = 25 MHz).
# This harness is RECEIVE ONLY: eth_txd/eth_tx_en are parked at zero but still need pin
# assignments because they remain ports of the board contract.

## -- Clocks ----------------------------------------------------------------

set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports clk100mhz]
create_clock -period 10.000 -name clk100mhz -waveform {0.000 5.000} [get_ports clk100mhz]

set_property -dict {PACKAGE_PIN F15 IOSTANDARD LVCMOS33} [get_ports eth_rx_clk]
create_clock -period 40.000 -name eth_rx_clk -waveform {0.000 20.000} [get_ports eth_rx_clk]

# The feed parser runs in this domain. At 25 MHz it has roughly 23 ns of slack on the
# Arty (see docs/retargeting.md); the production profile constrains the same RTL to
# 156.25 MHz on the deployment part.
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports eth_tx_clk]
create_clock -period 40.000 -name eth_tx_clk -waveform {0.000 20.000} [get_ports eth_tx_clk]

## -- Slide switches --------------------------------------------------------
## sw[0] = enable reception   sw[3:1] = which counter reaches led[3:0]

set_property -dict {PACKAGE_PIN A8  IOSTANDARD LVCMOS33} [get_ports {sw[0]}]
set_property -dict {PACKAGE_PIN C11 IOSTANDARD LVCMOS33} [get_ports {sw[1]}]
set_property -dict {PACKAGE_PIN C10 IOSTANDARD LVCMOS33} [get_ports {sw[2]}]
set_property -dict {PACKAGE_PIN A10 IOSTANDARD LVCMOS33} [get_ports {sw[3]}]

## -- Push buttons ----------------------------------------------------------
## btn[0] = active-high asynchronous reset, synchronized per clock domain

set_property -dict {PACKAGE_PIN D9 IOSTANDARD LVCMOS33} [get_ports {btn[0]}]
set_property -dict {PACKAGE_PIN C9 IOSTANDARD LVCMOS33} [get_ports {btn[1]}]
set_property -dict {PACKAGE_PIN B9 IOSTANDARD LVCMOS33} [get_ports {btn[2]}]
set_property -dict {PACKAGE_PIN B8 IOSTANDARD LVCMOS33} [get_ports {btn[3]}]

## -- Plain LEDs ------------------------------------------------------------
## Low nibble of the counter selected by sw[3:1]

set_property -dict {PACKAGE_PIN H5  IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN J5  IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN T9  IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports {led[3]}]

## -- RGB LEDs --------------------------------------------------------------

set_property -dict {PACKAGE_PIN G6 IOSTANDARD LVCMOS33} [get_ports led0_r]
set_property -dict {PACKAGE_PIN F6 IOSTANDARD LVCMOS33} [get_ports led0_g]
set_property -dict {PACKAGE_PIN E1 IOSTANDARD LVCMOS33} [get_ports led0_b]

set_property -dict {PACKAGE_PIN G3 IOSTANDARD LVCMOS33} [get_ports led1_r]
set_property -dict {PACKAGE_PIN J4 IOSTANDARD LVCMOS33} [get_ports led1_g]
set_property -dict {PACKAGE_PIN G4 IOSTANDARD LVCMOS33} [get_ports led1_b]

set_property -dict {PACKAGE_PIN J3 IOSTANDARD LVCMOS33} [get_ports led2_r]
set_property -dict {PACKAGE_PIN J2 IOSTANDARD LVCMOS33} [get_ports led2_g]
set_property -dict {PACKAGE_PIN H4 IOSTANDARD LVCMOS33} [get_ports led2_b]

set_property -dict {PACKAGE_PIN K1 IOSTANDARD LVCMOS33} [get_ports led3_r]
set_property -dict {PACKAGE_PIN H6 IOSTANDARD LVCMOS33} [get_ports led3_g]
set_property -dict {PACKAGE_PIN K2 IOSTANDARD LVCMOS33} [get_ports led3_b]

## -- USB-UART --------------------------------------------------------------
## uart_rxd_out carries the 36-byte CME7 status records at 115200 baud.

set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS33} [get_ports uart_rxd_out]
set_property -dict {PACKAGE_PIN A9  IOSTANDARD LVCMOS33} [get_ports uart_txd_in]

## -- Ethernet PHY (DP83848x) -----------------------------------------------

set_property -dict {PACKAGE_PIN D17 IOSTANDARD LVCMOS33} [get_ports eth_col]
set_property -dict {PACKAGE_PIN G14 IOSTANDARD LVCMOS33} [get_ports eth_crs]
set_property -dict {PACKAGE_PIN G16 IOSTANDARD LVCMOS33} [get_ports eth_rx_dv]
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVCMOS33} [get_ports {eth_rxd[0]}]
set_property -dict {PACKAGE_PIN E17 IOSTANDARD LVCMOS33} [get_ports {eth_rxd[1]}]
set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS33} [get_ports {eth_rxd[2]}]
set_property -dict {PACKAGE_PIN G17 IOSTANDARD LVCMOS33} [get_ports {eth_rxd[3]}]
set_property -dict {PACKAGE_PIN C17 IOSTANDARD LVCMOS33} [get_ports eth_rxerr]

set_property -dict {PACKAGE_PIN F16 IOSTANDARD LVCMOS33} [get_ports eth_mdc]
set_property -dict {PACKAGE_PIN C16 IOSTANDARD LVCMOS33} [get_ports eth_rstn]
set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS33} [get_ports eth_ref_clk]
set_property -dict {PACKAGE_PIN H15 IOSTANDARD LVCMOS33} [get_ports eth_tx_en]
set_property -dict {PACKAGE_PIN H14 IOSTANDARD LVCMOS33} [get_ports {eth_txd[0]}]
set_property -dict {PACKAGE_PIN J14 IOSTANDARD LVCMOS33} [get_ports {eth_txd[1]}]
set_property -dict {PACKAGE_PIN J13 IOSTANDARD LVCMOS33} [get_ports {eth_txd[2]}]
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports {eth_txd[3]}]

## -- Source-synchronous input timing (DP83848 MII receive) -----------------
## The PHY launches RXD/RX_DV/RX_ER off eth_rx_clk and the MAC captures them with
## eth_rx_clk registers, so these paths stay within one clock group and the async
## clock_groups below do not cut them.
##
## TODO: these are PLACEHOLDER numbers inherited from the networking harness, not values
## read out of the DP83848 datasheet's "MII Receive Timing" section (25 MHz / 40 ns). A
## timing report taken against them is not evidence about real PHY interface margin.
## Replace before claiming board timing closure on the MII pins.
set_input_delay -clock eth_rx_clk -max 20.0 [get_ports {eth_rxd[*] eth_rx_dv eth_rxerr}]
set_input_delay -clock eth_rx_clk -min 10.0 [get_ports {eth_rxd[*] eth_rx_dv eth_rxerr}]

## -- Timing exceptions -----------------------------------------------------

# Slow switch/button inputs, synchronized in fabric.
set_false_path -from [get_ports {sw[*] btn[*]}]

# eth_ref_clk is a generated clock output; eth_mdc and eth_rstn are static here.
set_false_path -to [get_ports {eth_ref_clk eth_mdc eth_rstn}]

# Receive-only harness: the MII transmit pins are tied off and never toggle.
set_false_path -to [get_ports {eth_txd[*] eth_tx_en}]

# 115200 baud serial out; a 40 ns clock period gives it no meaningful timing requirement.
set_false_path -to [get_ports uart_rxd_out]

# LEDs are human-observable only.
set_false_path -to [get_ports {led[*] led0_r led0_g led0_b led1_r led1_g led1_b \
                               led2_r led2_g led2_b led3_r led3_g led3_b}]

# clk100mhz drives the heartbeat, PHY reset sequencing and the PHY reference divider;
# eth_rx_clk and eth_tx_clk drive the network stack and the parser. All are asynchronous
# to each other and every crossing between them is explicitly synchronized.
set_clock_groups -asynchronous \
    -group [get_clocks clk100mhz] \
    -group [get_clocks eth_rx_clk] \
    -group [get_clocks eth_tx_clk]

## -- Bitstream config ------------------------------------------------------

set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
