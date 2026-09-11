# Phase 7 — Arty integration

The board harness, observability, sender, and automated MII/UART simulation are
implemented, and the CME datapath is covered cycle-accurately by `dune runtest`.
**Physical acceptance is pending.** No Arty UART device or Vivado executable was
available in these sessions, so no bitstream was built or programmed and no board
results are claimed.

## Composition and provenance

Every source and constraint in this harness belongs to **this** repository.
`hardcaml_networking` is used as an RTL supplier only: `validation/phase7/check.sh`
runs that repository's own committed `udp-rx-64` generator and stages the result into
`validation/vendor/`. No CME code lives in the networking repository, this repository
takes no OCaml dependency on it, and there is no patch to apply.

```text
cme_board_top                       validation/board/cme_board_top.ml
  |- udp_rx_64_mac_top   (external) hardcaml_networking, `udp-rx-64`
  |- cme_validation_core            validation/board/cme_validation_core.ml
  |    |- cme_mdp3_feed_parser      lib/cme/cme_feed_parser.ml
  |    `- cme_validation_sink       validation/board/cme_validation_sink.ml
  `- board scaffolding              validation/board/board_scaffolding.ml
```

`Board_top` (lib/common), `Clk_div` and `Second_pulse` are the Arty primitives this
repository already carried; `board_scaffolding.ml` is the matching plumbing layer
(per-domain reset synchronizers, the 25 MHz PHY reference divider, PHY hard-reset
sequencing, the heartbeat).

The target is **Arty A7-100T, `xc7a100tcsg324-1`, parser clock 25 MHz**. This is
functional integration. Phase 6's continuous-wide-stream tests and the U50 production
profile establish separate throughput and timing evidence.

### Why 25 MHz

The parser shares `eth_tx_clk` with the UDP application stream, so the design contains
**no parser clock-domain crossing** — the only crossing is the async receive FIFO already
inside the networking stack. A faster parser clock would require an MMCM and a new
crossing whose failures would present as parser bugs, and would buy no functional
coverage: MII at 100 Mb/s occupies roughly 6% of the parser's capacity at 25 MHz, so the
link is the limit. `docs/retargeting.md` records ~23 ns of routed slack for the
parser out-of-context at this clock, which is headroom, not a reason to spend it.

## Selection and observability

Only destination UDP port **31337** reaches the parser. Other ports drain at full rate
without changing parser sequence state; selection is latched on the accepted first wide
beat and retained through the packet. The sender crafts unicast Ethernet frames for MAC
`02:00:00:00:00:01`, IPv4 `192.168.1.1`, directly on the selected host interface, so ARP
replies from this receive-only harness are unnecessary. Use a direct host-to-Arty cable
and quiet unrelated traffic on that interface during capture. The wrapper selects a port;
it does not authenticate source IP/MAC and does not validate UDP checksums.

`btn[0]` resets. `sw[0]` enables reception; the PHY reference clock and the UART remain
active when it is low, so pausing ingress freezes the counters without truncating a
status record. `sw[3:1]` selects one of eight counters, whose low nibble is shown on
`led[3:0]`. RGB indicators show heartbeat (`led0_r`), updates seen (`led0_g`), PHY reset
released (`led1_g`), UDP busy (`led1_b`), network errors seen (`led2_r`), IPv4 checksum
status (`led2_g`), and parser diagnostics seen (`led3_r`).

The USB UART uses **115200 baud, 8 data bits, no parity, one stop bit**. A snapshot starts
after 25,000,000 idle cycles, approximately once per second plus record transmission time.
Every 36-byte record contains ASCII `CME7` followed by these little-endian 32-bit unsigned
counters:

| Index / switch value | Counter | Increment condition |
| --- | --- | --- |
| 0 | packets | Selected first wide beat accepted by the parser, including duplicates |
| 1 | updates | Accepted MBP-update event |
| 2 | end_of_event | Accepted end-of-event marker |
| 3 | diagnostics | Accepted parser diagnostic event |
| 4 | crc_errors | Late network bad-FCS verdict |
| 5 | ip_errors | Network frame completion with false IPv4 checksum status |
| 6 | sequence_gaps | Parser sequence-gap diagnostic |
| 7 | duplicates | Parser duplicate-or-late diagnostic |

Counters wrap modulo 2^32 and reset together. Snapshot values remain fixed during
serialization, including when new events arrive. The host requires two consecutive
matching snapshots for each case and preserves raw UART bytes and a JSON report.

An end-of-event marker requires bit 7 (`LastMsgOfEvent`) of MatchEventIndicator. Both the
board sender and the simulation stimulus set it; a payload without it produces the update
and no marker, which is correct parser behaviour rather than a counting fault.

**Late CRC alignment:** `Udp_ipv4_rx` registers `crc_error_o` on `frame_done_o`, so the
sink delays its CRC sampling by one enabled cycle; sampling both together would charge the
previous frame's verdict to this one. IPv4 checksum status is already aligned to frame
completion. Network error counters cover the network status channel, including
filtered-port traffic, and never become parser diagnostics. All parsed events remain
**provisional** on this permissive receive path, including events from a frame later found
to have bad FCS or a bad IP checksum.

## Verification

Three layers, all currently green.

**1. `dune runtest` — the CME datapath, cycle-accurate.** Everything from the recovered
UDP payload to the UART pin is ordinary Hardcaml, so it is reachable from Cyclesim:

- `test/cme/validation_sink/` drives synthetic events past a software counter model
  checked every cycle, and decodes the UART pin with an independent receiver that never
  looks inside the DUT. Record atomicity is checked by requiring every decoded counter
  tuple to be one the counters held simultaneously, with a non-vacuity count of the
  records transmitted while the live counters were still moving.
- `test/cme/validation_core/` covers destination-port selection, parser composition and
  counter wiring, including the central claim that filtered traffic can neither be counted
  nor perturb sequence state — checked by running an identical selected stream with and
  without filtered packets interleaved and requiring identical counters.

The former hand-written `cme_validation_sink.sv` had none of this: it was outside every
OCaml suite, and its event ABI was the literal slice `event_data[627:620]`. The Hardcaml
sink reads the same field through `Event.Of_signal.unpack`, so a field added to
`Cme_types.Event` can no longer silently shift the diagnostic code out from under the
counters.

**2. `validation/phase7/check.sh` — the board path, in Icarus.** MII nibbles through the
real generated async receive FIFO, width adapter, parser, counters and UART pin, with
independent RX and application clocks at 25 MHz and a phase offset. Only UART timing is
accelerated, via the separate `core-sim` generator target. This is the layer `dune
runtest` cannot reach, because the networking stack is an external instantiation.

**3. `phase7_contracts.ml`** — the event ABI and the nine sender fixtures against the XML
oracle, run as part of `dune runtest`.

```sh
./validation/phase7/check.sh
# Optional explicit networking checkout:
./validation/phase7/check.sh /path/to/hardcaml_networking
```

Requirements are the existing OCaml switch, Python 3, Icarus Verilog, and a sibling
networking checkout providing `udp-rx-64`. Artifacts are `_build/phase7/simulation.txt`,
`rtl.sha256`, `networking_revision.txt`, `cases.json`, and the generated payload fixtures.
The recorded run passed all nine cases and decoded eight complete atomic UART records,
with identical counters to the pre-rewrite SystemVerilog sink. It also checked enable
freeze and reset overriding disabled enable.

| Case | Sequence | Packets | Updates | End markers | Diagnostics | CRC / IP errors | Gaps / duplicates |
| --- | ---: | ---: | ---: | ---: | ---: | --- | --- |
| Single message, partial tail | 100 | 1 | 1 | 1 | 0 | 0 / 0 | 0 / 0 |
| Two messages, 1 + 2 entries | 101 | 2 | 4 | 3 | 0 | 0 / 0 | 0 / 0 |
| Sequence gap | 103 | 3 | 5 | 4 | 1 | 0 / 0 | 1 / 0 |
| Duplicate | 103 | 4 | 5 | 4 | 2 | 0 / 0 | 1 / 1 |
| After duplicate | 104 | 5 | 6 | 5 | 2 | 0 / 0 | 1 / 1 |
| Other destination port | 900 | 5 | 6 | 5 | 2 | 0 / 0 | 1 / 1 |
| After filtered packet | 105 | 6 | 7 | 6 | 2 | 0 / 0 | 1 / 1 |
| Late bad FCS, simulation | 106 | 7 | 8 | 7 | 2 | 1 / 0 | 1 / 1 |
| Bad IPv4 checksum, simulation | 107 | 8 | 9 | 8 | 2 | 1 / 1 | 1 / 1 |

All entries use security ID 1234 and price mantissa -123. The independent XML-driven
oracle verifies the sender's payloads and expected parser counts. All payloads end on
partial wide beats. Counter matching establishes the selected functional cases; it is not
full field-by-field UART event capture.

## Build and run on the board

Generate every RTL input with `check.sh` above, then, with Vivado installed and licensed:

```sh
vivado -mode batch -source validation/phase7/build.tcl -tclargs _build/phase7/vivado
```

The Tcl builds `cme_board_top` on `xc7a100tcsg324-1` against this repository's own
`validation/constraints/cme_arty.xdc`, saves routed timing, utilization, CDC,
clock-interaction and DRC reports, and writes a bitstream only when the reported worst
setup and hold paths pass.

**That XDC still carries placeholder MII input delays**, inherited from the networking
harness and marked `TODO` in the file. They are not values from the DP83848 datasheet, so
a timing report taken against them says nothing about real PHY interface margin. Replace
them before claiming board timing closure on the MII pins. The parser-only Arty timing
reports in `retargeting.md` do not cover this composed board harness either.

Program `_build/phase7/vivado/cme_board_top.bit` using Vivado Hardware Manager. Connect
the board's Ethernet jack directly to the intended host interface and its USB UART to the
host. Set `sw[0]` high, press/release `btn[0]`, and wait for PHY release and link. Then
run, substituting the actual interface and serial device:

```sh
sudo python3 validation/phase7/board_cases.py run \
  --iface enxYOUR_INTERFACE --serial /dev/ttyUSB1 \
  --output _build/phase7/board-capture.json
```

Raw Ethernet sending requires `CAP_NET_RAW` (the example uses `sudo`). The UART baseline
must be all zeros; a nonzero baseline fails with a request to reset the board. The sender
waits for two expected snapshots after each datagram. A healthy run prints seven `PASS`
lines and finishes with counters `6, 7, 6, 2, 0, 0, 1, 1`. JSON output includes per-case
observations, pass/fail, UTC time, interface, serial path, the networking revision, and
hashes of the board RTL, the parser RTL, the vendored network RTL, the constraints and the
schema. A `.uart.bin` file retains the captured bytes.

The ordinary NIC adds FCS itself, so the host acceptance sequence excludes the
simulation-only bad-FCS and bad-IP cases. Do not append the simulation FCS to
NIC-transmitted Ethernet frames. To regenerate fixtures without sending anything:

```sh
python3 validation/phase7/board_cases.py vectors _build/phase7
```

## Acceptance status

- **7.1 complete:** harness composed entirely within this repository; RTL generated and
  the board hierarchy elaborated; networking revision and generation commands recorded.
- **7.2 complete:** port selection, eight counters, LEDs, atomic UART snapshots, separate
  late-network status, and automated host comparison implemented — now in Hardcaml and
  covered by `dune runtest`.
- **7.3 pending on hardware:** all selected cases pass full MII RTL simulation; the seven
  physical board cases have not been run.
- **7.4 pending on hardware:** setup, sender commands, expected observations, and
  simulation evidence are recorded. Actual bitstream reports and board capture remain
  required before marking Phase 7 accepted. The placeholder MII input delays above are a
  prerequisite for any board timing claim.
