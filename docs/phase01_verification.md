# Phase 0–1 verification and reporting migration

Implemented and verified on 2026-09-05. The Phase 0 contracts and Phase 1
transport behavior now use the [networking test architecture](test_architecture.md)
and [OCaml reporting workflow](hardcaml_reports.md). The parser top remains the
inactive skeleton; this migration does not implement packet parsing or sequencing.

## Active coverage

All five behavioral suites have a `*_testbench.ml`,
`*_unit_quickcheck_tests.ml`, and `*_expect_tests.ml`. The top suite also has
native structural/ABI inline tests. `dune runtest` discovers the suites, shared
monitor tests, and report-validation tests without invoking external EDA tools.

| Previous assertion category | Active location under `test/cme/` |
| --- | --- |
| Top ports/directions/widths, literal event bit positions, encodings, configuration defaults/rejection, parser child emission | `cme_feed_parser/cme_feed_parser_contract_tests.ml` |
| Inactive top across reset/enable, all legal final keeps, held offers, ready/stalled consumer, independent/simultaneous controls | `cme_feed_parser/` Step scenarios, unit/Quickcheck checks, and golden |
| Nonzero contiguous keep, full non-final beat, first/last framing, held payload/qualifiers/timestamp, valid withdrawal, reset cancellation of monitor state | `verif/stream_monitor_tests.ml`, using the retained `stream_fixture.ml` monitor |
| Ingress depths 1, 2, 3, 64: exact capacity, empty/full, replacement, wrap, ordering, timestamp ownership, stalls, enable pause, reset cancellation | `ingress_fifo/`, using `verif/stream_scenarios.ml` |
| Event depths 1, 2, 3, 16: complete packed words, capacity, replacement, ordering, pending stability, enable pause and reset | `event_fifo/` |
| Aligner offsets 0–7, consume counts 0–8, excessive requests, literal partial-final lanes, two-slot retirement, following-packet isolation, byte offsets/context, pauses/reset | `byte_aligner/` |
| Pass-through transport, long stalls, reset/restart, byte and packet equality, timestamp retention, continuous acceptance/delivery at depths 1, 3, 64, Arty gaps/zero timestamps | `stream_foundation/`, using `verif/stream_scenarios.ml` |
| Transport fixture children resolve and their full RTL definitions are emitted | `cme_feed_parser/cme_feed_parser_contract_tests.ml` |

The original two harnesses are retained as `*_legacy_assertion_test.ml` bare
executables in `cme_feed_parser/` and `stream_foundation/`. They compile under
`dune build @all` and have no `runtest` rule. Their monitor and scoreboard assertion
categories remain in the active path; they are not the functional test runners.

`test/common/verif/` contains `Bits_conv` and `Sim_fixture`, preserving the
networking source attribution and the OxCaml local-handler signature. The
shared fixture constructs a flattened simulation scope and fails on timeout.
Sources retain pending offers and advance only on accepted transfers. Handshake
and peek observations use `before_edge`; hold/register checks use `after_edge`.
Queue monitors preserve the original byte, ordering, context, and occupancy
invariants. Unit/expect consumers receive plain typed observations, including
`int64` transport words and timestamps, so high bits are preserved.

Stress scenarios own their random state (default `[0x434d45; 1]`), removing the
original dependence on suite execution order. Quickcheck uses explicit seeds
and trial counts: 20 generated packet-list trials for each transport suite, six
schedule/event-pattern trials each for the event FIFO and aligner, and eight
64-bit input trials for the inactive top. Shrinkers are supplied; packet-list
shrinking filters empty payloads because those have no wire representation.
Literal asymmetric word/partial-lane assertions supplement pack/unpack and
queue checks. Five small expect traces were inspected against these assertions
before targeted promotion.

## Commands and results

From the repository root, all of these passed:

```sh
./scripts/with-switch.sh dune build @all @runtest @fmt
./scripts/with-switch.sh dune build @rtl-check
```

Run one suite with, for example:

```sh
./scripts/with-switch.sh dune runtest test/cme/byte_aligner
```

The optional `@rtl-check` alias generates complete RTL for the ingress FIFO,
event FIFO, byte aligner, pass-through fixture, and inactive parser. It runs
Yosys `read_verilog; hierarchy -check -top ...` and Icarus Verilog
`-g2012 -tnull -s ...`. No behavioral Verilog testbench, `vvp`, Yosys synthesis,
resource counting, or timing flow is part of that alias. Generated Verilog is a declared Dune output under
`_build/default/test/cme/rtl_checks/`. The check action prints per-target success
and prints the Yosys log on failure; its intermediate logs are sandbox-local.
The tools are required only when this explicit alias is requested. Normal builds
may generate RTL through OCaml but do not invoke Yosys or Icarus.

The fixture uses the ingress FIFO and aligner's `hierarchical` entry points.
Simulation flattens these calls; report/RTL generation retains their scope
circuit database and emits both child implementations. These additions change
construction boundaries without changing FIFO/aligner data-path behavior.

## Xilinx report evidence

Source: working tree based on `2043bebfde4108c4cdcb243ca84fbfaf0cca7e30`, including
the existing Phase 1 work and this migration; these results are not attributed
to the unmodified base commit. Toolchain: OCaml `5.2.0+ox`, Dune `3.22.2`,
Hardcaml, Step testbench, Xilinx reports, ppx_expect, and base_quickcheck all
`v0.18~preview.130.106+341`. Vivado is `2025.2.1`, build `6403652`.

Generation-only transport command:

```sh
./scripts/with-switch.sh dune exec synthesis/xilinx_reports.exe -- stream-foundation \
  -dir _build/xilinx-reports/phase01-dry -part xc7a100tcsg324-1 \
  -clock clock_i:156.25 -hierarchy -full-design-hierarchy true -jobs 1
```

This emitted projects for `cme_stream_fixture`, `cme_ingress_fifo`, and
`cme_byte_aligner`, with Verilog, Tcl, and a `clock_i` period of 6.400 ns in
each XDC. No Vivado run or resource/timing claim follows from that command.
The inactive top's `cme-feed-parser` generation command also passed, using
`_build/xilinx-reports/phase01-top-dry` with the same part/clock/inclusive profile.

The implemented leaf smoke command was:

```sh
./scripts/with-switch.sh dune exec synthesis/xilinx_reports.exe -- event-fifo \
  -dir _build/xilinx-reports/phase01-smoke -part xc7a100tcsg324-1 \
  -clock clock_i:156.25 -full-design-hierarchy true -jobs 1 -run \
  -path-to-vivado /home/wayne/tools/xilinx/vivado25_install/2025.2.1/Vivado/bin/vivado
```

| Setting/result | Value |
| --- | --- |
| Circuit | `cme_event_fifo`, depth 16, packed event width 677 |
| Part / constraint | `xc7a100tcsg324-1`, `clock_i` 156.25 MHz / 6.400 ns |
| Profile / stage | Inclusive implementation; Vivado hierarchy flattening allowed; `post_synth`, no placement/routing |
| LUTs | 722, all reported as logic |
| Flip-flops | 1,381 |
| BRAM tiles / DSPs | 9.5 / 0 |
| Worst setup / hold / pulse-width slack | +2.816 ns / +0.272 ns / +2.700 ns |
| Standard reports | `post_synth_report.txt`, `post_synth_cme_event_fifo.utilization`, `post_synth_cme_event_fifo.timing` in `_build/xilinx-reports/phase01-smoke/cme_event_fifo/` |

The wrapper required nonempty fresh artifacts and printed curated standard
report rows. An initial sandboxed run failed because Vivado could not update
its user cache at `~/.Xilinx/Vivado/tclapp/manifest.tcl`. The wrapper correctly
returned failure on missing reports even though the upstream runner printed
“Completed project.” Retrying with normal user-cache access produced the fresh
reports above. Inline report tests independently cover missing, empty, and stale
artifacts, accepted freshness, stage selection, and resource-row deduplication.

This is an out-of-context leaf synthesis smoke result. It does not establish
whole-parser timing, physical 10G closure, or the eventual event-latency bound.
The command validates the selected target's reports; it does not claim fresh
results for every child of a hierarchical Vivado run. Phase 6 still owns full
functional conformance, integrated throughput/latency, combinational-loop and
mux review, and device timing evidence. Phase 7 still owns board acceptance.
