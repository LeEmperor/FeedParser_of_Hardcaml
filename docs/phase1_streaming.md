# Phase 1: streaming foundation

Completed 2026-09-05. The standalone transport components and pass-through
fixture implement Phase 1 of the [parser plan](cme_mdp3_10g_parser_plan.md).
`Cme_feed_parser` remains the inactive Phase 0 top: no payload or control is
acknowledged and no normalized events are produced. Packet-header parsing and
sequencing begin in Phase 2.

## Components and storage

Hardware lives in `lib/cme/` and exposes `create ?depth scope i` for the FIFOs,
or `create scope i` for the aligner. All components follow the synchronous reset
and enable rules from [Phase 0](phase0_contracts.md): reset overrides enable,
inactive handshakes are suppressed, disable holds pending work, and reset
cancels it on the clock edge.

| Component | Contract |
| --- | --- |
| `Elastic_fifo` | Packed internal helper; exact positive capacity, with no empty combinational bypass. Uses Hardcaml's showahead FIFO with its output register included in the requested depth; depth 1 uses a single register. |
| `Ingress_fifo` | Default 64 beats. Stores data, keep, first, last, and timestamp atomically. Timestamp is sampled on an accepted first beat and stored as zero on other entries. |
| `Event_fifo` | Default 16 events. Stores complete packed `Cme_types.Event` values. `event_valid_i` / `event_ready_o` face the producer; `event_valid_o` / `event_ready_i` face the consumer. |
| `Byte_aligner` | Two stored ingress beats plus a byte offset, packet offset, and current packet timestamp. Maximum 128-bit byte window. |

FIFO depths include every entry and are not rounded to powers of two. A full
FIFO can dequeue and enqueue on the same edge, permitting one transfer per
cycle. An empty FIFO publishes an accepted item on the next cycle. Output
payloads remain stable while stalled or disabled. Invalid output values are
ignored, including stale memory contents after reset.

The aligner input flattens `Ingress_beat` as `data_i`, `keep_i`, `first_i`,
`last_i`, and `ingress_timestamp_i`, alongside `valid_i` / `ready_o`. Generated
RTL leaves therefore retain explicit direction suffixes.

## Byte window and consumption

The aligner has a **peek-and-consume interface**, with separate input-beat and
consume-command acceptance. It has no ordinary output `ready_i`.

| Output | Meaning |
| --- | --- |
| `valid_o` | Active and at least one current-packet byte is stored. |
| `data_o[127:0]` | Current packet's next available bytes, earliest in lane 0. Lanes above `available_o` are zero. |
| `available_o[4:0]` | 0–16 stored bytes from the current packet. |
| `boundary_o` | The last byte in the available window is the packet's final byte. |
| `first_o` | Lane 0 is byte 0 of the packet; remains set until a positive consume. |
| `ingress_timestamp_o[63:0]` | Current packet's timestamp, retained through its final consume. |
| `packet_byte_offset_o[15:0]` | Number of bytes already consumed in the current UDP payload. |
| `consume_ready_o` | Active, bytes are present, and the requested count is at most 8 and no greater than available. |

A command transfers on `consume_valid_i && consume_ready_o`. Its
`consume_count_i[3:0]` retires 0–8 bytes. Zero is an accepted no-op: it does not
advance either offset, capture context, or retire a packet. Requests larger than
8 or the available window are not acknowledged. The consumer chooses its count
from the advertised window and packet boundary.

The offset within the oldest beat advances modulo 8 as beats retire. The packet
offset advances only on positive accepted consumes and returns to zero on
consuming the final packet byte. Its 16-bit container covers the UDP payload
size. Input acceptance can independently fill a free slot; consume and refill
can occur on the same edge, including retirement of both slots.

The second slot may hold the next packet while the current packet ends in the
first slot. Next-packet bytes are excluded from the current window and available
count. Consuming the final current-packet byte exposes the next packet on the
following cycle without a mandatory idle cycle.

A refill may extend the available window and assert `boundary_o` during a
consume stall. Bytes already available, their offset, and their packet context
remain stable. A consumer assembling an ordinary output beat waits for at least
eight bytes or the packet boundary, then exposes the low eight bytes (or partial
final beat). The pass-through fixture demonstrates this conversion with stable
output data, keep, first, and last under backpressure. During disable, window
and context remain stored; raw peek values are ignored during reset until its
clearing edge has occurred.

## Fixture and checks

`test/cme/stream_fixture.ml` supplies byte-string sources, a reusable executable
stream contract monitor, and `Pass_through`, which composes the ingress FIFO and
aligner. Its ports carry payload beats, separate from the public event bus.

The source maps `app_tdata_o`, `app_tkeep_o`, `app_tvalid_o`, `app_tfirst_o`, and
`app_tlast_o` to parser inputs; parser `ready_o` maps back to `app_tready_i`.
It does not use `app_start_o`. The Arty case ties timestamps to zero and leaves
at least eight cycles between accepted wide beats, representing an 8-bit source.
Other cases drive continuously or add stalls/bubbles. Invalid final lanes contain
poison bytes to check keep handling.

The active suites under `test/cme/{ingress_fifo,event_fifo,byte_aligner,stream_foundation}/`
use Step/Cyclesim, shared queue/contract monitors, named inline unit tests,
deterministic Quickcheck properties, and reviewed expect traces. Each scenario
owns its schedule seed (default `[0x434d45; 1]`), independent of suite execution
order. They preserve the original harness's checks:

- Ingress depths 1, 2, 3, 64 and event depths 1, 2, 3, 16: exact capacity,
  empty/full transitions, simultaneous enqueue/dequeue, wrap, ordering, pending
  payload stability, disable/resume, and reset cancellation.
- Aligner offsets 0–7 and consume counts 0–8, rejected excessive counts,
  partial final beats, single-beat packets, consumption spanning both slots,
  two-slot retirement, and buffered next-packet isolation.
- Accepted-byte offsets and timestamp ownership against a byte queue model,
  including external timestamp changes on later beats.
- Deterministic long stalls, randomized bubbles/backpressure, and resets with
  buffered data, including reset while disabled. The source restarts at a new
  first beat after reset.
- Nonzero contiguous keep, full keep on non-final beats, first/last framing,
  and stable offers. Negative monitor tests reject illegal masks, framing,
  changed stalled fields/context, and withdrawn valid.
- Pass-through byte/boundary equality and uninterrupted input acceptance and
  output delivery after startup with a continuously ready sink.

The original pre-migration run delivered over 49,000 scored transport beats, over 12,000
packed events, and 35,589 bytes in the direct consume-count aligner test.
Continuous pass-through tests delivered 4,406, 4,475, and 4,457 beats at depths
1, 3, and 64 respectively, with no internally generated input stalls or output
bubbles after startup.

## Original verification evidence

Before migration, the default `5.2.0+ox` switch passed:

```sh
./scripts/with-switch.sh dune build @all @runtest @fmt
mkdir -p /tmp/cme-phase1
./scripts/with-switch.sh dune exec test/cme/generate_stream_fixture.exe -- /tmp/cme-phase1
```

The generator emits the default ingress FIFO plus aligner, default event FIFO,
and standalone aligner. Each passed Icarus Verilog 12.0 compilation and Yosys
0.33 (`2584903a060`) hierarchy, process lowering, optimization, and structural
checks:

```sh
for top in cme_stream_fixture cme_event_fifo cme_byte_aligner; do
  iverilog -g2012 -s "$top" -o "/tmp/cme-phase1/$top.vvp" "/tmp/cme-phase1/$top.v"
  yosys -Q -T -p "read_verilog /tmp/cme-phase1/$top.v; hierarchy -check -top $top; proc; opt; check -assert; stat"
done
```

Yosys reported no structural problems. Optimized generic cell counts were 195
for the pass-through fixture, 58 for the event FIFO, and 132 for the standalone
aligner. The aligner has no memories and uses an eight-way selection over a
maximum 128-bit byte window. These generic counts are not FPGA utilization or
timing results; no device target or clock constraint was applied. This evidence
establishes transport correctness and cycle throughput. CME decode correctness
and physical 156.25 MHz timing remain later-phase work.

## Current verification and reports

[Phase 0–1 verification](phase01_verification.md) records the migrated coverage
and commands. The former combined harness remains a bare compile-only executable
in `test/cme/stream_foundation/`; it is excluded from `runtest`.

The pass-through fixture now calls the ingress FIFO and aligner's `hierarchical`
entry points. Step simulation flattens them, while RTL/report generation retains
the circuit database and emits both child definitions. FIFO and aligner data-path
behavior is unchanged by these construction entry points.

Use `dune build @rtl-check` through the switch wrapper for the preserved thin
Yosys hierarchy and Icarus elaboration checks. The older `proc; opt; check; stat`
command above records historical evidence, not the current test/report flow.
Use `synthesis/xilinx_reports.exe` for explicit device synthesis and timing,
with generation-only and real device results distinguished as described in
[hardcaml_reports.md](hardcaml_reports.md).
