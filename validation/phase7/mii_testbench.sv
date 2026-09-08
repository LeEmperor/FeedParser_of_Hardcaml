// University of Florida
// Author: Bohdan Purtell
// Module: "mii_testbench.sv"
// Real generated async receive FIFO, independent MII clocks, parser and UART checks.
//
// This is the board-level gate: everything from MII nibbles to the UART pin, elaborated
// from the same generated RTL the bitstream is built from. It complements rather than
// duplicates dune runtest, which covers the CME datapath cycle-accurately but cannot
// reach the networking stack (an external Verilog instantiation) or the MII clocking.
//
// The DUT is cme_validation_core_sim: the board datapath with the UART divisors collapsed
// so complete status records appear within the simulation. Counter behaviour is identical
// to the board build.
`timescale 1ns/1ps
module mii_testbench;
    reg rx_clock = 0, clock = 0;
    always #20 rx_clock = !rx_clock;
    initial begin #7; forever #20 clock = !clock; end
    reg reset = 1, en = 1, rx_dv = 0;
    reg [3:0] rx_data = 0;
    wire [63:0] data;
    wire [7:0] keep;
    wire valid, first, last, ready, frame_done, crc_error, checksum_ok;
    wire [15:0] dst_port;
    wire [255:0] counters;
    wire uart;
    udp_rx_64_mac_top network (
        .rx_clock_i(rx_clock), .rx_reset_i(reset), .rx_dv_i(rx_dv),
        .rx_er_i(1'b0), .rx_data_i(rx_data), .tx_clock_i(clock),
        .tx_reset_i(reset), .en_i(en), .app_tready_i(ready),
        .app_tdata_o(data), .app_tkeep_o(keep), .app_tvalid_o(valid),
        .app_tfirst_o(first), .app_tlast_o(last), .dst_port_o(dst_port),
        .rx_frame_done_o(frame_done), .crc_error_o(crc_error), .checksum_ok_o(checksum_ok)
    );
    cme_validation_core_sim core (
        .clock_i(clock), .reset_i(reset), .en_i(en), .data_i(data), .keep_i(keep),
        .valid_i(valid), .first_i(first), .last_i(last), .dst_port_i(dst_port),
        .rx_frame_done_i(frame_done), .crc_error_i(crc_error), .checksum_ok_i(checksum_ok),
        .display_i(3'b0), .ready_o(ready), .uart_o(uart), .counters_o(counters)
    );
    // Capture the independent byte protocol at bit centres, including start/stop bits.
    // Nothing here reaches inside the DUT: the record is recovered from the pin exactly
    // as board_cases.py recovers it from the serial device.
    reg [287:0] uart_record;
    reg [7:0] uart_byte;
    integer byte_no, bit_no, uart_records = 0;
    reg [255:0] record_counters;
    reg [255:0] previous_record;
    initial begin
        previous_record = 0;
        forever begin
            for (byte_no = 0; byte_no < 36; byte_no = byte_no + 1) begin
                @(negedge uart);
                #80;
                if (uart !== 0) $fatal(1, "UART start bit");
                for (bit_no = 0; bit_no < 8; bit_no = bit_no + 1) begin
                    #160;
                    uart_byte[bit_no] = uart;
                end
                #160;
                if (uart !== 1) $fatal(1, "UART stop bit");
                uart_record[byte_no*8 +: 8] = uart_byte;
            end
            if (uart_record[31:0] !== 32'h37454d43) $fatal(1, "UART magic");
            record_counters = uart_record[287:32];
            // Counters only ever rise, so a record that reports less than an earlier one
            // was assembled from more than one sample point. Per-counter atomicity is
            // proven exhaustively by the OCaml sink suite; this is the board-path echo.
            for (bit_no = 0; bit_no < 8; bit_no = bit_no + 1)
                if (record_counters[bit_no*32 +: 32] < previous_record[bit_no*32 +: 32])
                    $fatal(1, "UART record went backwards on counter %0d", bit_no);
            previous_record = record_counters;
            uart_records = uart_records + 1;
        end
    end

    integer fd, rc, frame_len, value, j, k, case_no = 0;
    reg [31:0] expected [0:7];
    reg [255:0] frozen;
    initial begin
        repeat (10) @(negedge rx_clock);
        reset = 0;
        repeat (20) @(negedge rx_clock);
        fd = $fopen("mii_vectors.txt", "r");
        if (!fd) $fatal(1, "missing vectors");
        rc = $fscanf(fd, "%h", frame_len);
        while (rc == 1) begin
            for (j = 0; j < frame_len; j = j + 1) begin
                rc = $fscanf(fd, "%h", value);
                if (rc != 1) $fatal(1, "truncated frame");
                @(negedge rx_clock); rx_dv = 1; rx_data = value[3:0];
                @(negedge rx_clock); rx_data = value[7:4];
            end
            @(negedge rx_clock); rx_dv = 0; rx_data = 0;
            for (k = 0; k < 8; k = k + 1) begin
                rc = $fscanf(fd, "%h", expected[k]);
                if (rc != 1) $fatal(1, "truncated expectation");
            end
            repeat (1000) @(negedge clock);
            for (k = 0; k < 8; k = k + 1)
                if (counters[k*32 +: 32] !== expected[k])
                    $fatal(1, "case %0d counter %0d got %0d expected %0d", case_no,
                           k, counters[k*32 +: 32], expected[k]);
            $display("PASS MII case %0d packets=%0d updates=%0d ends=%0d diagnostics=%0d crc=%0d ip=%0d gaps=%0d duplicates=%0d",
                case_no, expected[0], expected[1], expected[2], expected[3],
                expected[4], expected[5], expected[6], expected[7]);
            case_no = case_no + 1;
            rc = $fscanf(fd, "%h", frame_len);
        end
        $fclose(fd);
        if (case_no != 9) $fatal(1, "wrong vector count");
        frozen = counters;
        en = 0;
        repeat (3000) @(negedge clock);
        if (counters !== frozen || ready !== 0) $fatal(1, "disabled sink changed");
        if (uart_records < 2) $fatal(1, "no complete UART observations");
        reset = 1;
        repeat (5) @(negedge clock);
        if (counters !== 0 || uart !== 1) $fatal(1, "reset must override enable");
        $display("PASS atomic UART records=%0d; disabled/reset checks", uart_records);
        $finish;
    end
    initial begin #2000000; $fatal(1, "simulation timeout"); end
endmodule
