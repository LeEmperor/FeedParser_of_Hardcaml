# University of Florida
# Author: Bohdan Purtell
# Module: "build.tcl"
# Build the CME feed-parser validation bitstream for the Arty A7-100T.
# Does not program connected hardware.
#
# All sources and constraints belong to this repository. hardcaml_networking contributes
# one generated Verilog file, staged into validation/vendor by validation/phase7/check.sh,
# which must be run first.
if {$argc != 1} {
    error "usage: vivado -mode batch -source validation/phase7/build.tcl -tclargs OUTPUT_DIR"
}
set cme_root [file normalize [file join [file dirname [info script]] ../..]]
set output_dir [file normalize [lindex $argv 0]]
set network_rtl [file join $cme_root validation/vendor/hardcaml_udp_rx_64_with_mac.v]
if {![file exists $network_rtl]} {
    error "missing $network_rtl -- run validation/phase7/check.sh first"
}
file mkdir $output_dir
create_project -in_memory -part xc7a100tcsg324-1
read_verilog [file join $cme_root cme_board_top.v]
read_verilog $network_rtl
read_xdc [file join $cme_root validation/constraints/cme_arty.xdc]
synth_design -top cme_board_top -part xc7a100tcsg324-1
opt_design
place_design
route_design
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $output_dir timing_summary.rpt]
report_utilization -hierarchical -file [file join $output_dir utilization.rpt]
report_clock_interaction -file [file join $output_dir clock_interaction.rpt]
report_cdc -file [file join $output_dir cdc.rpt]
report_drc -file [file join $output_dir drc.rpt]
write_checkpoint -force [file join $output_dir routed.dcp]
foreach delay_type {max min} {
    set worst [get_timing_paths -delay_type $delay_type -max_paths 1]
    if {[llength $worst] == 0 || [get_property SLACK $worst] < 0} {
        error "Board timing incomplete or failing ($delay_type); inspect saved reports"
    }
}
write_bitstream -force [file join $output_dir cme_board_top.bit]
puts "Arty xc7a100tcsg324-1, parser clock eth_tx_clk 25 MHz. Board capture still required."
puts "NOTE: validation/constraints/cme_arty.xdc still carries placeholder MII input delays."
