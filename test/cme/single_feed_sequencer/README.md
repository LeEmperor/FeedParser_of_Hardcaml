# `single_feed_sequencer` test suite

## What is here today

One file, `single_feed_sequencer_invariant_tests.ml`, holding internal-node invariants
and their coverage guards. It is deliberately *not* a behavioural suite: it never checks
what the sequencer emits, only that the four rules the module is built on hold on every
cycle of randomised traffic.

This follows the `packet_header` precedent rather than the `foo_testbench` /
`foo_unit_quickcheck_tests` / `foo_expect_tests` trio in `docs/test_architecture.md`. A
leaf whose output is already scored one level up gets invariants; it does not get a second
copy of the scoreboard.

## Where the behavioural coverage actually lives

`test/cme/packet_pipeline/`. That suite instantiates `Ingress_fifo` → `Packet_header` →
`Single_feed_sequencer` together and scores the emitted `Packet_item` stream against an
independent software model that reads literal payload bytes. Most of what it asserts is
sequencer semantics:

| Scenario | `packet_pipeline_unit_quickcheck_tests.ml` |
| --- | --- |
| gap diagnostic then admit | `short header after a gap snapshots invalidity without sequence advance` |
| resync establishes `expected` | `resync establishes expected value before first packet` |
| duplicate drained before next packet | `fence waits for complete long duplicate drain` |
| session reset restores baseline | `session reset restores baseline after gap and queued diagnostics drain` |
| control not latched while busy | `busy pulse is not latched` |
| `channel_valid` recovery | `resync recovers validity after gap` |

So the gap this directory fills is not "the sequencer is untested". It is "the sequencer's
internal rules are only tested by consequence".

## Direction for a future session

A dedicated behavioural suite is worth building when the sequencer grows past single-feed
— an arbitrated A/B feed, or a gap-fill request path — because at that point the
composition-level model stops being able to attribute a diagnostic to a cause. Until then,
the work below is the useful backlog, roughly in priority order.

### 1. Cases packet_pipeline's stimulus cannot reach

These need a driver that hands the sequencer `Packet_item`s directly, because
`packet_header` will never produce them from a real UDP payload:

- **Delta at exactly `2^31`.** `late = msb (packet_seq -: expected)`, so the boundary
  between `sequence_gap` and `duplicate_or_late` sits there. The invariant suite already
  checks that `late` agrees with the model at the boundary; nobody checks which
  *diagnostic code* comes out, or that the code and the `channel_valid` stamp agree.
- **Back-to-back gaps with no intervening admit.** Reachable only if upstream offers two
  starts without the first being consumed, which the fault protocol should make
  impossible. Assert it directly rather than inferring it.
- **A `diagnostic` item arriving mid-drop.** `open_packet_next` holds on diagnostics, and
  `dropping` keeps `ready` high, so the sideband passes through while a body is being
  swallowed. That interleaving is not scored anywhere.
- **Resync to the current `expected`.** Delta is zero, but `resync` still forces
  `initialized` and `channel_valid` high — a "revalidate without moving the sequence"
  gesture. Whether that is intended is worth pinning with a named test.

### 2. What the software model must capture

Anyone writing the model should encode these before writing scenarios; each one is a place
a naive model diverges from the RTL on the second or third packet:

- **The fault protocol takes two cycles.** On the faulting cycle `emit_fault` forces
  `ready` low, so the diagnostic *replaces* the item without consuming it; the admit
  happens the cycle after, once `gap_sent` has suppressed `fault`.
- **`last` is `beat.last | (start & body_empty)`.** A header-only packet ends on its start
  item, which is what lets `dropping` clear in one cycle for an empty duplicate.
- **The gap diagnostic stamps its own validity.** The emitted event carries
  `mux2 late channel_valid gnd` — a gap reports `channel_valid = 0` (the channel is about
  to become invalid), a late/duplicate reports the value still held. The pass-through path
  for a *sideband* diagnostic instead carries the pre-update register value. The asymmetry
  is deliberate; a model that treats both the same will drift.
- **The first admit of a session is valid at any sequence number.** `admit &: ~:initialized`
  drives `channel_valid` high and `admitted_context` overrides the field with `vdd`.
- **Controls need `quiescent_i` from the composition.** The sequencer's own `idle_o` covers
  only `dropping`, `gap_sent` and `open_packet`; `packet_pipeline.ml:88` ANDs in the fifo,
  the header stage and everything downstream. A unit-level model must supply the same
  fence or it will expect controls that never fire.

### 3. Open design question found while reviewing

`gap_sent` is cleared only by `admit`, and `admit` requires `ready_i`. So while a gap
diagnostic is outstanding and the sink is stalled, `idle_o` stays low indefinitely, which
means `control_ready_o` stays low and a `session_reset_i` can never be applied. That is
defensible as ordinary backpressure — you should not reset a pipeline mid-recovery — but
it makes reset liveness depend on downstream progress, which is not stated anywhere in the
module's header comment. Decide whether it is a contract or a wedge, then either document
it on `idle_o` or give the composition an escape.

A test for it is easy and worth having either way: drive a gap, hold `ready_i` low, pulse
`session_reset_i` for a long while, and assert whichever behaviour is chosen.

## Running

```sh
./scripts/with-switch.sh dune runtest test/cme/single_feed_sequencer/
```

The coverage assertion fails the suite if the randomised stimulus stops reaching an arm —
a gap, a late packet, a drained drop, a control at idle, a refused control, a wrapped
delta, or a delta at the half-space boundary. If a change to the RTL or the driver makes
one of those unreachable, that failure is the point, not a flake to retune.
