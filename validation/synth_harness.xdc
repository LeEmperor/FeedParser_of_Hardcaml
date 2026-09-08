# University of Florida
# Author: Bohdan Purtell
# Module: "synth_harness.xdc"
#
# Constraints for validation/synth_harness.sv. Target assumed to be an Alveo
# U50 (xcu50-fsvh2104-2-e), a Virtex UltraScale+ part.
#
# Scope note: everything here constrains the HARNESS boundary only. Nothing in
# this file touches paths inside u_dut, deliberately. The DUT's internal
# register-to-register paths, and its input and output boundary paths, are the
# numbers being measured; false-pathing any of them would delete the result.

# -----------------------------------------------------------------------------
# Clock. 156.25 MHz / 6.400 ns matches docs/phase01_verification.md.
# -----------------------------------------------------------------------------
create_clock -name clk_i -period 6.400 [get_ports clk_i]

# The harness clock is a plain input; on a shell-based card the real design
# would take a clock from the platform instead. For a standalone timing run this
# is sufficient, and the placer will pick a clock-capable pin on its own.
#
# Do NOT add CLOCK_DEDICATED_ROUTE here. It is unnecessary when the placer is
# free to choose the pin, and 'ANY' is a 7-series value that UltraScale+ rejects
# outright (legal values there are TRUE, FALSE, BACKBONE, SAME_CMT_COLUMN,
# ANY_CMT_COLUMN, SAME_CMT_ROW, ANY_CMT_REGION). Only reach for it if you later
# pin clk_i to a non-clock-capable pad and placement objects.

# -----------------------------------------------------------------------------
# I/O timing is meaningless in this harness: the three non-clock ports exist
# only to keep the logic reachable and unprunable. False-path them so pad delay
# does not contaminate the report. This is the ONLY false pathing that belongs
# in this flow.
# -----------------------------------------------------------------------------
set_false_path -from [get_ports stim_i]
set_false_path -from [get_ports rst_i]
set_false_path -to   [get_ports result_o]

# -----------------------------------------------------------------------------
# Pin placement.
#
# For a naive timing/impl run you do NOT need real pins. With only four ports,
# giving an IOSTANDARD and letting place_design assign the pins itself is
# sufficient and keeps the flow completely standard. This bitstream is never
# going onto the card, so which physical pins get used is irrelevant - only the
# fact that I/O buffers exist and placement succeeds matters.
set_property IOSTANDARD LVCMOS18 [get_ports {clk_i rst_i stim_i result_o}]

# If you later want specific pins, fill these in from the platform XDC. The U50
# is shell-based: the XDMA platform owns nearly all package I/O and what is
# exposed to user logic depends on which xilinx_u50_gen3x16_xdma_* build you
# target, so these are deliberately left unset rather than guessed.
#
# set_property PACKAGE_PIN <PIN> [get_ports clk_i]
# set_property PACKAGE_PIN <PIN> [get_ports rst_i]
# set_property PACKAGE_PIN <PIN> [get_ports stim_i]
# set_property PACKAGE_PIN <PIN> [get_ports result_o]
#
# To list legal candidates for this package:
#   get_package_pins -filter {IS_GENERAL_PURPOSE && BANK != ""}
#
# -----------------------------------------------------------------------------
# Full implementation flow. This is a NORMAL in-context run - not OOC - which is
# what makes the post-route report trustworthy.
#
#   read_verilog -sv validation/synth_harness.sv
#   read_verilog cme_byte_aligner.v
#   read_xdc     validation/synth_harness.xdc
#   synth_design -top synth_harness -part xcu50-fsvh2104-2-e
#   opt_design
#   place_design
#   phys_opt_design
#   route_design
#   report_timing_summary -file post_route_timing.rpt
#   report_utilization    -file post_route_util.rpt
#   report_timing -of_objects [get_timing_paths -max_paths 20 -sort_by slack] \
#                 -file post_route_paths.rpt
#
# Read WNS from post_route_timing.rpt. Ignore any post-synth timing summary
# except as a smoke test - nothing is placed at that point, so the interconnect
# delays are estimates.
#
# The paths that matter are inside u_dut. Filter to them with:
#   get_timing_paths -max_paths 20 -sort_by slack -through [get_cells u_dut/*]
# -----------------------------------------------------------------------------
