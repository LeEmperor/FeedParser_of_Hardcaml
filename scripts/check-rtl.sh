#!/usr/bin/env bash
# University of Florida
# Author: Bohdan Purtell
# Module: "check-rtl.sh"
# Thin optional backend checks. Functional verification is dune runtest.

set -euo pipefail
if [[ $# -ne 1 ]]; then
  echo "usage: check-rtl.sh GENERATED_RTL_DIRECTORY" >&2
  exit 2
fi
rtl_dir="$1"
for tool in yosys iverilog; do
  if ! command -v "$tool" >/dev/null; then
    echo "error: optional RTL checks require $tool" >&2
    exit 1
  fi
done
for top in cme_ingress_fifo cme_event_fifo cme_byte_aligner cme_stream_fixture cme_packet_pipeline cme_sbe_message_iterator cme_message_pipeline cme_event_orderer cme_mdp3_feed_parser; do
  iverilog -g2012 -tnull -s "$top" "$rtl_dir/$top.v"
  if ! yosys -Q -T -p "read_verilog \"$rtl_dir/$top.v\"; hierarchy -check -top $top" > "$rtl_dir/$top.yosys.log"; then
    cat "$rtl_dir/$top.yosys.log" >&2
    exit 1
  fi
  echo "PASS: $top hierarchy and Verilog elaboration"
done
