// University of Florida
// Author: Bohdan Purtell
// Module: "synth_harness.sv"
//
// Pin-reduction harness for standalone Vivado synth/impl runs on a single
// module. Wraps a DUT whose port count exceeds anything placeable, presenting
// only four ports to the tools, so that place_design and route_design can run
// and post-route timing is obtainable.
//
// DUT of record is cme_byte_aligner (146 input bits + 218 output bits, which
// is unplaceable on any real package). Regenerate it with:
//     ./scripts/with-switch.sh dune exec lib/common/generate.exe -- byte-aligner
//
// Structure:
//
//   stim_i --> [scramble regs] --> DUT --> [capture regs] --> XOR fold --> result_o
//                    ^                                                        |
//                    +--------------------- feedback ------------------------ +
//
// Two rules make this harness give honest numbers, and breaking either one
// silently invalidates every report you take from it:
//
//   1. THE SCRAMBLE AND CAPTURE STAGES MUST BE REGISTERS, NOT WIRES.
//      Fanning stim_i combinationally to every DUT input makes all DUT inputs
//      the same net. opt_design then propagates that equivalence inward and
//      collapses the DUT: the popcount over keep_i degenerates, the comparators
//      against a self-equal bus fold to constants, and you get a report for a
//      circuit that no longer resembles the module. Vivado cannot prove two
//      distinct flop outputs are equal, so a register per DUT input bit blocks
//      that entirely. The same argument applies to the output fold: register
//      before reducing.
//
//   2. THE DUT INSTANCE MUST BE DONT_TOUCH.
//      Otherwise cross-boundary optimization can still reach in from the fold
//      side and prune outputs that the reduction happens not to observe.
//
// The scramble register is a shift register with XOR feedback taps. It is
// deliberately NOT a maximal-length LFSR - sequence quality is irrelevant here,
// because static timing analysis does not care about values. Its only jobs are
// to hold every DUT input in a distinct flop and to stay reachable from stim_i
// so nothing constant-folds.

`default_nettype none

module synth_harness #(
    // Total DUT input bits excluding clock and excluding the harness reset.
    parameter int STIM_W = 146,
    // Total DUT output bits.
    parameter int FOLD_W = 218
) (
    input  wire clk_i,
    input  wire rst_i,
    input  wire stim_i,
    output wire result_o
);

  // ---------------------------------------------------------------------------
  // Stimulus: one flop per DUT input bit.
  // ---------------------------------------------------------------------------
  // No DONT_TOUCH here, deliberately. The scramble bits already have distinct D
  // inputs from the shift, so nothing can merge them and the equivalence-blocking
  // property we need is free. Marking them DONT_TOUCH additionally prevents
  // opt_design/phys_opt_design from REPLICATING them to relieve fanout, which
  // matters because scramble[0] drives the synchronous clear of every DUT flop.
  reg [STIM_W-1:0] scramble;

  wire feedback = stim_i ^ scramble[STIM_W-1] ^ scramble[97] ^ scramble[61] ^ scramble[7];

  always_ff @(posedge clk_i) begin
    if (rst_i) scramble <= {{(STIM_W - 1) {1'b0}}, 1'b1};  // non-zero seed
    else scramble <= {scramble[STIM_W-2:0], feedback};
  end

  // ---------------------------------------------------------------------------
  // DUT input slicing. Widths must sum to STIM_W. Edit this block, the capture
  // block, and the instance together when retargeting to another module.
  // ---------------------------------------------------------------------------
  wire        dut_reset_i            = scramble[0];
  wire        dut_en_i               = scramble[1];
  wire [63:0] dut_data_i             = scramble[65:2];
  wire [ 7:0] dut_keep_i             = scramble[73:66];
  wire        dut_first_i            = scramble[74];
  wire        dut_last_i             = scramble[75];
  wire [63:0] dut_ingress_timestamp_i = scramble[139:76];
  wire        dut_valid_i            = scramble[140];
  wire        dut_consume_valid_i    = scramble[141];
  wire [ 3:0] dut_consume_count_i    = scramble[145:142];

  wire         dut_ready_o;
  wire         dut_valid_o;
  wire [127:0] dut_data_o;
  wire [  4:0] dut_available_o;
  wire         dut_boundary_o;
  wire         dut_first_o;
  wire [ 63:0] dut_ingress_timestamp_o;
  wire [ 15:0] dut_packet_byte_offset_o;
  wire         dut_consume_ready_o;

  (* DONT_TOUCH = "true" *)
  cme_byte_aligner u_dut (
      .clock_i            (clk_i),
      .reset_i            (dut_reset_i),
      .en_i               (dut_en_i),
      .data_i             (dut_data_i),
      .keep_i             (dut_keep_i),
      .first_i            (dut_first_i),
      .last_i             (dut_last_i),
      .ingress_timestamp_i(dut_ingress_timestamp_i),
      .valid_i            (dut_valid_i),
      .consume_valid_i    (dut_consume_valid_i),
      .consume_count_i    (dut_consume_count_i),

      .ready_o             (dut_ready_o),
      .valid_o             (dut_valid_o),
      .data_o              (dut_data_o),
      .available_o         (dut_available_o),
      .boundary_o          (dut_boundary_o),
      .first_o             (dut_first_o),
      .ingress_timestamp_o (dut_ingress_timestamp_o),
      .packet_byte_offset_o(dut_packet_byte_offset_o),
      .consume_ready_o     (dut_consume_ready_o)
  );

  // ---------------------------------------------------------------------------
  // Capture: one flop per DUT output bit, before any reduction.
  // ---------------------------------------------------------------------------
  wire [FOLD_W-1:0] dut_flat = {
    dut_consume_ready_o,
    dut_packet_byte_offset_o,
    dut_ingress_timestamp_o,
    dut_first_o,
    dut_boundary_o,
    dut_available_o,
    dut_data_o,
    dut_valid_o,
    dut_ready_o
  };

  (* DONT_TOUCH = "true" *) reg [FOLD_W-1:0] capture;

  always_ff @(posedge clk_i) begin
    if (rst_i) capture <= '0;
    else capture <= dut_flat;
  end

  // ---------------------------------------------------------------------------
  // Fold. Sits between capture and result registers, so it is a path of its own
  // and does not extend any DUT path. A 218-input XOR maps to roughly four LUT6
  // levels, well under the DUT depth; if it ever shows up as the critical path,
  // split it into two registered halves rather than constraining it away.
  // ---------------------------------------------------------------------------
  reg result_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) result_q <= 1'b0;
    else result_q <= ^capture;
  end

  assign result_o = result_q;

  // Width check: catches a mis-sliced retarget at elaboration instead of
  // silently leaving DUT inputs tied to zero.
  if (STIM_W != 146) $error("STIM_W must match the DUT input slicing above");
  if (FOLD_W != 218) $error("FOLD_W must match dut_flat above");

endmodule

`default_nettype wire
