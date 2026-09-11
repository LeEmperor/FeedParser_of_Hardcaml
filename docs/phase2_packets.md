# Phase 2: packet extraction and sequencing

Implemented 2026-09-05 against the [Phase 0 contracts](phase0_contracts.md) and
[Phase 2 delivery milestones](cme_mdp3_10g_parser_plan.md#phase-2--cme-packet-extraction-and-sequencing).
The independently usable `Packet_pipeline` delivers the canonical packet stream
for Phase 3. The public `Cme_feed_parser` remains inactive until message/event
processing is integrated; canonical body bytes are not exposed as market events.

## Components and integration

| Component | Responsibility |
| --- | --- |
| `lib/cme/packet_header.ml` | Instantiates the Phase 1 two-beat aligner, collects the 12-byte header, emits aligned body items or the header-only marker, and diagnoses short payloads. |
| `lib/cme/single_feed_sequencer.ml` | Baseline/expected-sequence state, signed modulo comparison, channel validity, gap-before-start serialization, duplicate/late draining, and fenced recovery controls. |
| `lib/cme/packet_pipeline.ml` | Composes the ingress FIFO, header extractor, and sequencer; implements input packet ownership and the control drain fence. |

Each exposes `create` and `hierarchical`. `Packet_pipeline.create ?config scope i`
uses `Cme_config.default` (64 ingress beats); the active tests also instantiate
one-beat and non-power-of-two three-beat ingress FIFOs. No networking or board
library is required.

`Packet_pipeline.I` accepts the same data, keep, first, last, valid, timestamp,
clock/reset/enable and sequence controls as the planned public boundary. Its
consumer uses `ready_i`, `valid_o`, and `item_o`, with `ready_o` for input
backpressure and `control_ready_o` for control acceptance. `item_o` is the
917-bit `Cme_types.Packet_item` packed in declaration order, exposed by the
new `Cme_types.packet_item_width` constant. These internal ports do not change
the public event ABI.

The integration-specific `downstream_idle_i` is true only when the future
iterator, decoder, diagnostic ordering, and output event storage have no pending
work. A test sink that completely consumes each canonical item can tie it high.
Later integration must account for contexts/events retained after a canonical
transfer; asserting it merely because `ready_i` is high is incorrect.

The canonical stream is unchanged from Phase 0:

- Start (`kind = 0`) carries context and the first body beat atomically. The first
  byte after the technical header occupies lane 0. A header-only start sets
  `body_empty` and zeros every beat field.
- Body (`kind = 1`) carries subsequent bytes with zero context and no first flag.
  Last and contiguous low-lane keep preserve the accepted UDP boundary.
- Diagnostic (`kind = 2`) carries a complete diagnostic event. Other item fields
  and all unused event fields are zero.

A downstream stage must retain start context until the last body item is consumed
or copied into owned storage. Diagnostic items share this stream and cannot be
bypassed by a separately ready body sink.

## Extraction, sequence decisions, and ownership

The header collector consumes the first eight bytes and then the remaining four.
It assembles little-endian sequence and sending time without a packet-wide
shifter. Timestamp is retained from the first accepted input beat through FIFO
and aligner storage. Body production waits for eight bytes or the observed final
boundary, so lookahead/refill cannot change a valid stalled beat's qualifiers.
Long bodies begin delivery before the UDP final beat is accepted.

Payload lengths 1–11 produce exactly one truncated-header diagnostic, with
sequence/sending time zero, header presence false, the original timestamp, and
an offset equal to the accepted payload length. In particular, an exactly
eight-byte packet terminates the collector immediately; it must never borrow
bytes from a buffered following packet. Short headers do not initialize or
advance sequence state.

A complete admitted start establishes or advances expected sequence modulo
2^32. The sign bit of the 32-bit difference distinguishes forward gaps from
late/duplicate packets; exactly `0x80000000` is late. A gap first transfers a
diagnostic containing the old expected sequence and invalid channel context,
then transfers its start. The start is held upstream during that diagnostic.
Validity remains false until session reset or resync. A duplicate/late decision
transfers one diagnostic and drains the held start and every body item through
last without publishing them. Header-only duplicates terminate on their empty
start. The next packet cannot overtake a diagnostic or drain.

Controls are accepted only when the ingress FIFO, aligner, header context,
sequencer context/drain, and downstream work are all empty. An asserted request
blocks new first beats immediately, while an already open input packet can
finish and all buffered packets can drain. At quiescence, a control wins over an
offered first beat and session reset wins over resync. Busy pulses are ignored;
held requests eventually apply after the fence drains. Reset clears all state
even when disabled. Disable suppresses handshakes and preserves pending payloads.

## Verification

`test/cme/packet_pipeline/` is one Step/Cyclesim integration suite covering the
canonical seam. Its software model reads byte strings independently of RTL
extraction, tracks sequence decisions, and predicts every item before comparing
actual transfers. It checks full-width timestamps/sending times, output stability,
framing/keep, zero unused fields, and bounded completion. Input timestamps are
deliberately changed on non-first beats and invalid lanes contain poison bytes.

The named tests cover:

- An asymmetric literal little-endian header with high bits set in time fields.
- Every short length, header-only packets, body lengths 0–80 and all final lane
  counts, back-to-back traffic, and FIFO depths 1, 3, and 64.
- Split header delivery with seven idle cycles between input beats, randomized
  bubbles, enable pauses, and prolonged metadata/body/diagnostic backpressure.
- Initialization, normal progression, forward gaps, repeated/late packets,
  32-bit wraparound, and the exact half-range comparison.
- Short-header validity snapshots, session reset, resync both initially and after
  a gap, control priority, busy pulses, and controls held inside an open packet.
- A downstream busy interval that delays control even after packet output drains,
  and a long duplicate whose accepted last beat must precede control acceptance.
- Reset while disabled with partial collection, pending sequence diagnostics,
  admitted body work, and duplicate draining; the source restarts at a first beat.
- A 4,096-byte body delivered cut-through using a one-beat ingress FIFO.
- Thirty seeded scenarios of 70 packets each (2,100 generated packets), mixing
  short packets, sequencing faults, body lengths up to 256 bytes, and stalls.
  The explicit Quickcheck seed is `phase2-canonical-packets`; shrinking the
  scenario seed preserves valid framing while retaining intentional faults.
- The 917-bit canonical item ABI, directional port suffixes, and all four child
  module definitions in emitted hierarchical RTL.

The reviewed expect trace shows a normal packet, a gap diagnostic followed by
its start, a duplicate diagnostic, a short-header diagnostic, and a subsequent
header-only packet. A named eight-byte-short regression preserves the boundary
failure discovered by the scoreboard during implementation.

All 18 named unit/property tests and the reviewed expect trace passed. The full
repository build, functional suites, formatting check, and six optional RTL
hierarchy/elaboration targets passed using the installed `5.2.0+ox` switch:

```sh
./scripts/with-switch.sh dune runtest test/cme/packet_pipeline
./scripts/with-switch.sh dune build @all @runtest @fmt @rtl-check
```

The optional RTL alias now generates
`_build/default/test/cme/rtl_checks/cme_packet_pipeline.v` with all child
implementations, and runs Yosys hierarchy checking and Icarus elaboration beside
the existing targets. The other five RTL smoke targets remain included.

## Performance boundary

This phase establishes functional admission, byte preservation, ordering,
cut-through behavior, and safe backpressure. It does not establish sustained
10G acceptance or physical timing. Header collection currently uses two consume
cycles, with a separate empty marker or body transfer; sufficiently many tiny
packets can therefore require more processing cycles than input beats. The FIFO
absorbs bounded bursts and applies backpressure when full. Transition overlap
and the integrated pipeline's uninterrupted-input/latency acceptance remain
Phase 6 work. No FPGA synthesis, placement, routing, or 156.25 MHz timing result
is claimed by the hierarchy/elaboration smoke checks.
