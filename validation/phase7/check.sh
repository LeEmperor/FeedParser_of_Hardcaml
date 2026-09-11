#!/usr/bin/env bash
# University of Florida
# Author: Bohdan Purtell
# Module: "check.sh"
# Regenerate every RTL input and run the complete MII-to-UART board simulation.
#
# hardcaml_networking is used as an RTL supplier only: this runs its own committed
# `udp-rx-64` target and copies the result in. No CME code lives in that repository and
# nothing here patches it, so a clean checkout at any revision that provides udp-rx-64
# works unmodified.
set -euo pipefail
cme_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
networking_root="$(realpath "${1:-$cme_root/../hardcaml_networking}")"
output="$cme_root/_build/phase7"
vendor="$cme_root/validation/vendor"
mkdir -p "$output" "$vendor"

if [[ ! -f "$networking_root/lib/common/generate.ml" ]]; then
    echo "error: no hardcaml_networking checkout at $networking_root" >&2
    exit 1
fi

cd "$cme_root"
./scripts/with-switch.sh dune exec lib/common/generate.exe -- cme
./scripts/with-switch.sh dune exec lib/common/generate.exe -- board
./scripts/with-switch.sh dune exec lib/common/generate.exe -- core-sim
./scripts/with-switch.sh dune runtest validation/phase7
./scripts/with-switch.sh dune runtest test/cme/validation_sink test/cme/validation_core

(
    cd "$networking_root"
    ./scripts/with-switch.sh dune exec lib/common/generate.exe -- udp-rx-64
)
cp "$networking_root/hardcaml_udp_rx_64_with_mac.v" "$vendor/"

python3 validation/phase7/board_cases.py vectors "$output"

network_rtl="$vendor/hardcaml_udp_rx_64_with_mac.v"
# The board top is elaborated to prove the bitstream's hierarchy resolves; the simulation
# drives the accelerated-UART twin of the same datapath.
iverilog -g2012 -tnull -s cme_board_top "$cme_root/cme_board_top.v" "$network_rtl"
iverilog -g2012 -s mii_testbench -o "$output/mii.vvp" \
    "$cme_root/validation/phase7/mii_testbench.sv" \
    "$cme_root/cme_validation_core_sim.v" "$network_rtl"
(
    cd "$output"
    vvp mii.vvp | tee simulation.txt
)
sha256sum "$cme_root/cme_board_top.v" "$cme_root/cme_validation_core_sim.v" \
    "$cme_root/cme_mdp3_feed_parser.v" "$network_rtl" > "$output/rtl.sha256"
git -C "$networking_root" rev-parse HEAD > "$output/networking_revision.txt"
