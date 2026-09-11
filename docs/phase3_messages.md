# Phase 3: generic SBE message iteration

Implemented 2026-09-05 against the [Phase 0 contracts](phase0_contracts.md) and
[Phase 3 milestones](cme_mdp3_10g_parser_plan.md#phase-3--generic-sbe-message-iteration).
The canonical packet stream now feeds an independently usable message iterator.
An event orderer provides the decoder completion and abort seam. The public
`Cme_feed_parser` remains inactive until production schema decoding and event
integration in Phase 5.

## Components

| Component | Responsibility |
| --- | --- |
| `lib/cme/sbe_message_iterator.ml` | Collects the ten-byte prefix, bounds body delivery by `MsgSize` and the actual packet end, skips unsupported templates, and emits ordered structural diagnostics. |
| `lib/cme/message_pipeline.ml` | Composes `Packet_pipeline` with the iterator and includes iterator ownership in the sequencer control fence. |
| `lib/cme/event_orderer.ml` | Routes message items to a decoder and serializes its events with sequencer/iterator diagnostics, including terminal aborts. |

All three expose `create` and `hierarchical`. The iterator and message pipeline
require `~supported_templates:int list` at elaboration. IDs must fit an unsigned
16-bit field; an empty list rejects every template. This is an admission list,
not a schema descriptor. Tests use synthetic IDs 42 and `0x9876`; the RTL smoke
exports use 42. No production template ID, field offsets, block-size requirement,
or schema/version compatibility decision is selected by this phase. Those
choices remain with Phase 4 and the Phase 5 dispatcher/decoder.

`Message_pipeline.create ?config ~supported_templates scope i` accepts the same
input record as `Packet_pipeline`, including recovery controls and
`downstream_idle_i`. Its output uses `valid_o`, `ready_i`, and `item_o`, with
`ready_o` for upstream input and `control_ready_o` for controls. The packed
`Cme_types.Message_item` is 1079 bits, exposed by `message_item_width`. The
677-bit normalized event ABI is unchanged.

## Message consumption and packet ownership

`Sbe_message_iterator.I` consumes packed canonical `Packet_item` values on
`item_i`/`valid_i`/`ready_o`. Its output is one ordered `Message_item` stream on
`item_o`/`valid_o`/`ready_i`:

- Start (`kind = 0`) carries packet context, all five little-endian prefix fields,
  header presence, the UDP-relative offset of `MsgSize`, and the first body beat.
  The ten-byte prefix is removed and the first body byte occupies lane 0.
- Body (`kind = 1`) carries subsequent body beats. Context and unused fields are
  zero. Keep is contiguous from lane 0 and full except on the final message beat.
- Last denotes the declared message boundary, even if the next message begins
  within the same incoming beat. The iterator retains those next-message bytes.
- `MsgSize = 10` emits a start with `body_empty = 1` and all beat fields zero.
  A header-only packet emits no message item.
- Diagnostic (`kind = 2`) contains a complete diagnostic event. The packet and
  message fields outside that event, and all other unused item fields, are zero.

A start transfers context atomically with its bytes or empty marker. The decoder
owns that context until its terminal item and all resulting events have been
accepted by ordered storage. Transaction time and its presence flag remain zero
at this seam because the iterator interprets no template body fields.

The iterator retains one packet context, a prefix collector, length/state
registers, a diagnostic register, a two-beat aligner, and one elastic output item.
It does not accept the next packet's start or diagnostic into the aligner while
processing the current packet. The output register may own the prior packet's
last item while processing begins on the next packet. Each queued item carries
its own required context. The register also prevents new aligner lookahead from
changing an externally stalled message item into a truncation diagnostic.

Input/output transfers are suppressed during reset or disable. Reset clears
pending work even when disabled; enable pause preserves it. `idle_o` includes
retained bytes, packet/message processing, pending diagnostics, and output
storage. `Message_pipeline` combines this with `downstream_idle_i` when fencing
sequencer controls. The caller must include decoder context, event ordering,
and output event storage in that downstream idle signal.

## Recovery and diagnostic precedence

| Condition | Result |
| --- | --- |
| Fewer than ten prefix bytes before the packet ends | One message-beyond-packet diagnostic; message header fields and presence are zero, but its starting offset is retained. |
| Complete prefix with `MsgSize < 10` | One invalid-message-size diagnostic; drain the remainder of the packet. A later plausible prefix in those bytes is not interpreted. |
| Unsupported ID with a valid size | One unsupported-template diagnostic, then skip the declared body and resume at the next message. |
| Actual packet ends before the declared message end | One message-beyond-packet diagnostic and drain remaining bytes; resume at the next packet. |
| Unsupported message also truncated | Unsupported-template diagnostic first, then message-beyond-packet, including a packet ending exactly after the prefix. |

Invalid size takes precedence over template admission. A partial prefix is
untrustworthy even when its `MsgSize` bytes happened to arrive. The size itself
bounds traversal; root block-length and schema/version checks belong to the
decoder, so the generic iterator exposes their values without interpreting them.

Diagnostic positions follow Phase 0: invalid size points to `MsgSize`, unsupported
template to prefix offset + 4, and truncation to the first missing UDP payload
byte. Sequencer diagnostics pass through unchanged and precede their packet's
messages. Expected-sequence fields are zero/absent on iterator diagnostics.

Truncation known before body output produces a standalone diagnostic. After
cut-through output has begun, the same diagnostic terminates the active message.
Already delivered bytes are a valid prefix of that message; the iterator does
not manufacture a final beat at the wrong position. Any final incomplete or
unpublished body portion is discarded. The decoder must abort its incomplete
collector and suppress end-of-event while preserving previously completed events.

## Event ordering and decoder completion

Connect `Message_pipeline.item_o`/`valid_o` to `Event_orderer.item_i`/`valid_i` and
return `Event_orderer.ready_o` as the message pipeline's `ready_i`.

| Event orderer ports | Contract |
| --- | --- |
| `decoder_item_o`, `decoder_valid_o`, `decoder_ready_i` | Ordered start/body delivery; also delivers one terminal truncation diagnostic when a message is active. |
| `decoder_event_i`, `decoder_event_valid_i`, `decoder_event_ready_o` | Decoder's completed events in message order, held stable while stalled. |
| `decoder_done_i`, `decoder_done_ready_o` | Explicit completion handshake after the terminal item and all decoder events. It may coincide with the final event transfer. |
| `event_o`, `event_valid_o`, `event_ready_i` | Single ordered event stream, suitable for `Event_fifo` input. |
| `idle_o` | No owned decoder message and no retained abort diagnostic. |

A normal final beat or empty start closes message input. The orderer continues
accepting decoder events until completion. It blocks the next message and its
diagnostics during that ownership interval. The decoder must hold completion
until acknowledged and must never emit another event for the released message.

An in-message truncation is forwarded to the decoder exactly once. The orderer
retains its diagnostic event, waits for the decoder to flush earlier completed
updates and acknowledge completion, then emits the diagnostic. The decoder does
not echo the abort event. A standalone diagnostic bypasses the decoder only when
no message is owned. This permits a decoder to drain a rejected message while
emitting its own schema/enum diagnostic through the ordinary decoder-event port.

For the control fence, connect the message pipeline's `downstream_idle_i` to
orderer idle AND decoder idle AND empty ordered event storage (and any additional
retained downstream work). Output ready alone does not establish quiescence.
The production decoder and final public-top composition remain Phase 5 work.

## Verification evidence

`test/cme/message_pipeline/` contains 15 named unit/property tests and a reviewed
expect trace. Its Step/Cyclesim driver checks accepted transfers and stalled
payload stability, compares completed messages/diagnostics against an independent
byte-string walker, and checks every emitted body byte directly against the
original packet. Truncation expectations permit variable cut-through progress
without permitting incorrect bytes, a false last, or a lost abort.

Coverage includes all eight prefix alignments, every partial-prefix length at
each alignment, empty packets/messages, multiple messages, body tails, invalid
sizes 0–9, unsupported-to-supported recovery, supported/unsupported truncation,
high-bit prefix values, a large legal IPv4 UDP payload, sequence diagnostics,
control fencing, reset while disabled, enable pauses, input bubbles, output
stalls, byte-source-like gaps, and cut-through delivery. Ingress FIFO depths 1,
3, and 64 are exercised. The deterministic Quickcheck seed
`phase3-message-walker` runs 25 trials of 40 packets with randomized messages and
malformed tails; shrinking the scenario seed preserves the generation rules.

`test/cme/event_orderer/` contains four named unit/property tests and a reviewed
expect trace. A delayed synthetic decoder produces completed updates and normal
end events, accepts aborts, and exercises final-event/completion handshakes.
Coverage includes stalled updates ahead of abort and standalone diagnostics,
normal and zero-body completion, reset cancellation, and 50 randomized schedules
using seed `phase3-event-orderer`.

The full repository build, functional suites, formatting check, and nine optional
RTL hierarchy/elaboration targets passed with the installed `5.2.0+ox` switch:

```sh
./scripts/with-switch.sh dune build @all @runtest @fmt @rtl-check
```

New generated RTL under `_build/default/test/cme/rtl_checks/` includes
`cme_sbe_message_iterator.v`, `cme_message_pipeline.v`, and `cme_event_orderer.v`.
Yosys checks hierarchy resolution and Icarus checks Verilog elaboration. The
existing Phase 0–2 targets remain in the alias.

## Performance boundary

This phase establishes message traversal, recovery, cut-through behavior, ordering,
and safe backpressure. Like the Phase 2 collector, the prefix collector currently
uses two consume cycles, followed by body or empty-marker delivery. Short-message
traffic can exhaust finite input elasticity and backpressure upstream. Decoder
completion also gates the next message's admission to the orderer. Boundary
transition overlap, uninterrupted 64-bit acceptance, and entry-to-event latency
remain Phase 6 work; this implementation is not evidence of sustained 10G
throughput. No device synthesis, placement/routing, or 156.25 MHz timing result is
claimed by the RTL smoke checks.
