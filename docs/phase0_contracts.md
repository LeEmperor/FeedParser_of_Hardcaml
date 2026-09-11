# Phase 0: portable parser contracts

This is the implementation contract supplement to the [delivery plan](cme_mdp3_10g_parser_plan.md).
The top is an **inactive skeleton**: `ready_o`, `control_ready_o`, and
`event_valid_o` are always zero, and `event_o` is zero. It accepts no traffic or
controls. The behavior below is the contract for subsequent phases, not a claim
that parsing or sequence state exists today.

The standalone FIFOs, aligner, and transport fixture are now implemented; see
[Phase 1](phase1_streaming.md) for their interface and verification. The public
top's inactive behavior described here is unchanged. [Phase 2](phase2_packets.md)
now implements packet extraction, sequencing, and the control fence in the
separate canonical `Packet_pipeline` boundary.

## Public boundary

`Cme_feed_parser.I` and `O` in `lib/cme/cme_feed_parser.ml` are the public
Hardcaml interfaces. `create ?config scope i` supports flat composition;
`hierarchical ?config ?instance scope i` supports scoped instantiation;
`circuit ?config ()` builds `cme_mdp3_feed_parser` with all declared ports,
including inputs unused by the skeleton.

| Direction | Ports | Widths |
| --- | --- | --- |
| Input | `clock_i`, `reset_i`, `en_i` | 1 each |
| Input | `data_i`, `keep_i` | 64, 8 |
| Input | `valid_i`, `first_i`, `last_i` | 1 each |
| Input | `ingress_timestamp_i` | 64 |
| Input | `session_reset_i`, `resync_valid_i`, `resync_next_seq_i` | 1, 1, 32 |
| Input | `event_ready_i` | 1 |
| Output | `ready_o`, `control_ready_o`, `event_valid_o` | 1 each |
| Output | `event_o` | 677, provisional until Phase 4 |

The stream is the plan's low-byte-first, trusted UDP payload contract. No network
status or packet length is required. Timestamp is sampled only on an accepted
first beat. An empty UDP payload has no representation; a nonempty short payload
is representable and will produce a truncated-header diagnostic in Phase 2.

### Reset, enable, and handshakes

All state changes occur at the rising edge of `clock_i`. Active-high synchronous
`reset_i` overrides `en_i` and every request. Reset discards every buffered beat,
context, partial decode, and pending event, and clears sequence initialization and
channel validity. It produces no diagnostic. After reset, the source must begin
with a new packet's first beat; a packet interrupted by reset is not resumed.

In an implemented core, the active condition is `en_i && !reset_i`. While it is
false, input ready, control ready, and output valid are suppressed, so the usual
`valid && ready` equations never report a transfer. With enable low and reset low,
all state and pending output payloads are held. Re-enabling resumes the pending
work. Reset may cancel stalled work; disable may hide valid but must preserve its
payload and reassert valid on resume. Synchronous reset must span a clock edge;
combinational handshake suppression alone does not clear stored state.

While active, a producer holds valid, payload, qualifiers, and associated context
until accepted. The ingress timestamp must be stable with a stalled first beat;
on later beats its external value is ignored. Invalid data lanes and values when
valid is low are ignored. Input framing/keep violations are simulation contract
failures, not additional CME diagnostic codes. `en_i` is a shared pause control,
not an extra handshake for external producers or consumers.

### Sequencer control fence

"Input idle" means fully quiescent: no open input packet, no ingress FIFO beats,
no aligner bytes, no packet/message context in any stage, no drain in progress,
and no pending diagnostic or output FIFO event. The skeleton always advertises
control not ready because it cannot apply a control yet.

For the implemented core:

1. `control_ready_o = active && quiescent`. It does not depend on request valid or
   the presence of an offered first beat.
2. At quiescence, an asserted control takes priority over a simultaneously offered
   packet: `ready_o = 0` for that cycle. `session_reset_i` wins over
   `resync_valid_i`; exactly one operation occurs on the accepting edge.
3. Session reset clears initialization and channel validity. The next complete
   packet header establishes expected sequence and makes the channel valid.
   Resync sets `expected_seq = resync_next_seq_i`, initialized and valid.
4. A control offered while busy is not acknowledged or latched. The caller holds
   the request and its value until `control_ready_o`. While a request is asserted,
   stop admitting **new first beats**, but continue accepting the remainder of an
   already open packet and processing all buffered work. This drain fence avoids
   starving controls behind continuous packet arrivals. A pulse while busy has no
   accepted effect and must be retried.
5. Previously queued events must transfer before a control is accepted. Thus a
   stalled consumer can delay control indefinitely. No old event is relabeled
   with the new sequence/validity state.

The first packet's baseline and all increments wrap modulo 32 bits. Signed delta
zero is expected; positive is a gap; negative is duplicate/late. Delta exactly
`0x80000000` is negative (late). A gap snapshots channel validity false into its
diagnostic and admitted packet. It stays false until recovery control. A short
packet header never establishes or advances the sequence baseline.

## Named hierarchy and ownership

Only the contracts, configuration, and top entry points existed in Phase 0. The
following filenames are reserved for subsequent implementations under `lib/cme/`;
there are no pretend functional child instances in the generated skeleton.

| Module / file stem | Phase | Input → output and ownership |
| --- | --- | --- |
| `Cme_types` / `cme_types` | 0 | Direction-neutral records, event and diagnostic encodings |
| `Cme_config` / `cme_config` | 0 | Positive FIFO depth parameters, defaults 64 beats / 16 events |
| `Cme_feed_parser` / `cme_feed_parser` | 0, integration later | Public boundary, control fence, composition |
| `Ingress_fifo` / `ingress_fifo` | 1 | Public beat plus sampled timestamp → `Ingress_beat` |
| `Event_fifo` / `event_fifo` | 1 | Ordered `Event` → packed public event stream |
| `Byte_aligner` / `byte_aligner` | 1 | At most two beats → low-lane byte window and explicit consume count |
| `Packet_header` / `packet_header` | 2 | Ingress byte stream → header-stripped `Packet_item` |
| `Single_feed_sequencer` / `single_feed_sequencer` | 2 | Pre-sequence `Packet_item` → canonical `Packet_item` |
| `Sbe_message_iterator` / `sbe_message_iterator` | 3 | Canonical packets → bounded `Message_item` |
| `Template_dispatcher` / `template_dispatcher` | 5 | Messages → selected decoder or size-bounded skip |
| `Mbp_decoder` / `mbp_decoder` | 5 | Root/group collectors → normalized `Event` |
| `Event_orderer` / `event_orderer` | 3, 5 | Diagnostics and decoder results → one position-ordered `Event` stream |

Portable CME modules depend on Hardcaml libraries, not the networking or board
helper library. The existing UART framing experiment remains separate. The
Phase 1 pass-through test fixture lives in `test/cme/stream_fixture.ml` and
exposes beats, not reinterpret the public normalized-event bus as bytes.

`Beat` contains data, keep, first, and last. `Ingress_beat` adds timestamp, valid
only on its first beat (zero on other FIFO entries). Each buffered first beat
owns its timestamp, so a later packet cannot overwrite an earlier one's context.
`Packet_context` contains timestamp, source, sequence, sending time, header
presence, and channel validity. Source is zero for feed A. `Message_context`
contains all five prefix fields, header presence, transaction time/presence, and
an offset from the beginning of the UDP payload to `MsgSize`.

Internal directional interfaces wrap these records as `item_i`/`item_o` (or
`beat_i`/`beat_o`) plus `valid_i`/`ready_o` or `valid_o`/`ready_i`. Valid and ready
are not part of stored value records. Every transfer has the same active gating
as the public boundary. The aligner reports 0–16 available bytes and a boundary
flag, accepts a consume count of 0–8 no greater than available, and advances only
on an accepted consume. A zero consume does not retire bytes. It never presents
bytes from two packets in one window; a boundary can retire only after all its
valid bytes are consumed. FIFO acceptance may proceed independently when the
second beat slot is free. Detailed aligner ports and lookahead logic are recorded
in [Phase 1](phase1_streaming.md).

### Canonical packet stream

`Packet_item` is one ordered ready/valid stream with kind `start = 0`, `body = 1`,
or `diagnostic = 2`; value 3 is reserved. This same type connects header peel to
the sequencer, where pre-sequence channel validity is zero, and connects the
sequencer (or future A/B arbiter) to the iterator.

- A nonempty `start` carries packet context **and the first body beat in the same
  transfer**. The 12-byte header is gone, and byte 12 of the UDP payload is lane 0.
  Its beat has first asserted. A single body beat may also have last asserted.
- Subsequent `body` items carry beats with first zero. Keep is full except on the
  final beat, whose nonzero keep is contiguous from bit 0. Last closes the packet.
- A header-only packet is one `start` with `body_empty = 1` and zero beat fields.
  It establishes/advances sequencing and closes the packet on that transfer;
  there is no fake zero-keep beat and no message or end-of-event output.
- A diagnostic item contains a complete `Event` of diagnostic kind. All fields
  unused by an item kind are zero; `body_empty` is only meaningful on start.
- No packets interleave. Context is accepted atomically with the first body bytes
  or empty marker. The receiver owns that context until the final body bytes have
  been consumed or copied into its own bounded storage. A sender may release its
  copy once the corresponding final item transfers; it must not wait for the
  eventual external event consumer if downstream already owns all relevant data.
- Gap diagnostics precede their packet's start. Duplicate/late and short-header
  diagnostics have no associated admitted start. A rejected packet is drained
  through its accepted last beat before the next packet can be published.

A diagnostic may be queued before a rejected packet is fully drained, but later
packet output cannot overtake it. Backpressure may pause draining if there is no
space to retain the pending diagnostic; no unbounded side queue is assumed.

`Message_item` uses the same three kinds and combined context/first-body transfer.
Its start contains packet and message contexts, with the 10-byte prefix removed
and its first body byte at lane 0. Last means the declared **message** boundary,
not the packet boundary. `MsgSize = 10` is a structurally legal empty start;
template-specific root requirements can still reject it. The iterator retains
unconsumed bytes of the next message in the aligner. Decoder completion releases
message context only after all its events have transferred to ordered storage.
This prevents a subsequent diagnostic from overtaking stalled entry events.

If the actual packet ends before MsgSize, an iterator diagnostic item with code
`message_beyond_packet` terminates any active message at this boundary. It is an
abort marker as well as an ordered event: the dispatcher/decoder must consume it,
discard any incomplete collector, suppress end-of-event, and release the active
message after preceding completed-entry events are queued. Do not manufacture a
last beat at the wrong byte position or wait forever for the declared size. The
same diagnostic can appear without a start when truncation is known before the
first body transfer. Other iterator diagnostics are standalone between messages.

## Event layout, ordering, and errors

`event_o` is `Cme_types.Event.Of_signal.pack event` with default `rev = false`.
Fields occupy increasing bits in declaration order; nested packet/message records
use their own declaration order. `Of_bits.pack`/`unpack` provide the software
counterpart. There is one packed Verilog port, no accidentally renamed nested
output leaves. The current width is 677 bits.

| Field region | Inclusive bits |
| --- | --- |
| Kind | 1:0 |
| Packet context | 164:2 |
| Message context | 326:165 |
| Entry index / count | 342:327 / 358:343 |
| Security ID / report sequence | 390:359 / 422:391 |
| Price mantissa / null | 486:423 / 487 |
| Entry size / null | 519:488 / 520 |
| Number of orders / null | 552:521 / 553 |
| Price level / update action / entry type | 561:554 / 569:562 / 577:570 |
| Tradeable size / null | 609:578 / 610 |
| Match event indicator / message last | 618:611 / 619 |
| Diagnostic code | 627:620 |
| Expected sequence / presence | 659:628 / 660 |
| Diagnostic byte offset | 676:661 |

Event kinds are `Mbp_update = 0`, `End_of_event = 1`, `Diagnostic = 2`; 3 is
reserved. Diagnostic codes are none = 0, sequence gap = 1, duplicate/late = 2,
truncated packet header = 3, invalid message size = 4, message beyond packet = 5,
unsupported template = 6, schema incompatibility = 7, invalid enum = 8, internal
overflow = 9. Codes 10–255 are reserved. A diagnostic event never uses code zero.

A complete packet header sets `packet_header_present`. For early short-header
errors, sequence and sending time are both zero with presence false, even if a
partial sequence was collected; ingress timestamp/source remain available and
channel validity snapshots the existing sequencer state. A complete ten-byte
message prefix sets `message_header_present`; absent prefix fields are all zero.
Transaction time has an independent presence bit. No absent value is represented
by a magic all-ones sentinel. `packet_byte_offset` remains useful when a prefix is
partial; it is zero for errors outside a message.

For sequencing diagnostics, `expected_seq_present` is true and expected sequence
is the pre-decision value; diagnostic byte offset is zero. Other diagnostics zero
those expected-sequence fields. A structural truncation offset is the first
missing byte (the accepted payload byte count), an invalid size points at MsgSize,
and template/schema/enum errors point at their offending field. These unsigned
16-bit positions cover a UDP payload without requiring a packet length sideband.

Every event snapshots context when it is created; later sequence changes never
modify queued events. Ordering is packet arrival order, then message order, then
entry order. A gap diagnostic comes before all events of that packet. An entry's
`message_last` is true exactly on its final MBP entry; indices start at zero. An
end-of-event follows all updates for a successfully decoded message with match
indicator bit 7 set, including a legal zero-entry message. Its MBP-only fields are
zero, but it retains the match indicator and common context. Diagnostics zero
MBP-only fields. Ordinary market events zero diagnostic-only fields.

Unsupported templates generate one diagnostic and skip the declared message.
A size below ten or a partial prefix makes the size untrustworthy and drains the
packet remainder. A message extending past accepted last also ends parsing of
that packet. With a trustworthy size, template/schema/enum failure skips the rest
of that message and permits the next one. Emit one primary failure diagnostic per
failed message; a subsequent discovered packet truncation may additionally report
message-beyond-packet. Already emitted cut-through updates are not retracted;
a failed message emits no end-of-event. Sequence validity tracks gaps/recovery,
not a guarantee that every template decoded successfully.

Normal FIFO fullness applies backpressure and is not overflow. Internal overflow
is an invariant violation, must fail simulation, and in hardware must preserve an
ordered pending diagnostic, invalidate channel state, and drain the affected
packet; implementation must reserve diagnostic capacity rather than silently drop
it. Physical network receive overflow remains a shell responsibility.

### Phase 4 schema decisions

Phase 4 confirmed these containers against pinned CME Production schema ID 1,
version 13, `MDIncrementalRefreshBook46`. Full provenance and enum details are in
the [Phase 4 implementation record](phase4_schema.md).

| Fields | Stable containers | Selected schema definition |
| --- | --- | --- |
| Entry index and count | unsigned 16 each | `numInGroup` is unsigned 8-bit; the wider event count is retained |
| Security ID, report sequence | 32 each | `Int32` and `uInt32`, respectively |
| Price mantissa | signed 64 + null flag | `PRICENULL9`; null is signed max; exponent is `-9` |
| Entry size, number of orders, tradeable size | signed 32 + individual null flags | `Int32NULL`; null is signed max; tradeable size is since version 10 |
| Price level, update action, entry type | 8 each | `uInt8`, `uInt8` enum 0–5, and one-byte character enum |
| Match event indicator | 8 | `uInt8` set; bit 7 is `EndOfEvent` |
| Transaction time | unsigned 64 + presence | `uInt64`, present in the selected template root |

Signed values use two's-complement containers; narrower signed fields will be
sign-extended. Null values use zero in the value container and assert their null
flag; unavailable fields use zero, with availability determined by event kind,
context presence, and the pinned schema's version rules. Phase 4 fixtures verify
this normalization, including that signed minima are not confused with nulls.
There is no decimal arithmetic in the RTL.

## Throughput budget and implementation constraints

At 156.25 MHz, eight bytes per cycle is 10 Gb/s of payload capacity. The ingress
FIFO defaults to 64 beats (512 payload bytes); the event FIFO defaults to 16
complete events. Both depths are positive elaboration-time parameters. Phase 0
allocates neither FIFO and makes no functional or timing claim.

Context cannot consume a mandatory extra message cycle. A combined start/body
item requires at most `max(1, ceil((MsgSize - 10) / 8))` transfers per message,
which is no greater than `MsgSize / 8` for any integer MsgSize at least ten.
Likewise header removal supplies the packet handoff budget. This avoids an
obvious token-rate bottleneck, but is not proof that collectors, dispatch, or
boundary transitions will sustain the rate. Overlap header/root collection,
lookahead, handoff, and FIFO enqueue/dequeue; do not add an obligatory idle state
between every packet, message, or entry.

The output budget is one event per cycle. Phase 4 must check the actual selected
entry width and root/group overhead against updates plus end-of-event and
possible diagnostics, especially many short or zero-entry messages. The event
FIFO absorbs finite bursts, not an average rate exceeding one event per cycle.
Phase 6 must prove uninterrupted input acceptance under a ready consumer and the
eight-cycle entry-to-event latency bound. A two-beat aligner is a maximum 128-bit
byte window, never a packet-wide barrel shifter. The packed event width does not
imply any correspondingly wide input datapath.

## Verification entry points

```sh
./scripts/with-switch.sh dune build
./scripts/with-switch.sh dune runtest
./scripts/with-switch.sh dune build @fmt
./scripts/with-switch.sh dune exec lib/common/generate.exe -- cme
./scripts/with-switch.sh dune exec lib/common/generate.exe -- uart
```

The CME command writes ignored `cme_mdp3_feed_parser.v`, prominently marked
inactive. The UART command writes `uart_test_top.v`; no argument retains the
existing UART default. The active `test/cme/cme_feed_parser/` inline suite checks
actual rendered RTL declarations, the provisional packed event ABI and reserved
codes, configuration validation, and inactivity through reset, disable, offered
traffic, stalls, and simultaneous controls. It does not validate the future
sequencer, drain fence, FIFOs, or decoding behavior.

The original Phase 0 verification completed on 2026-09-05 with the default switch: bootstrap,
`dune build @all @runtest @fmt`, both RTL generation targets, Icarus compilation
of both generated tops, and Yosys `hierarchy -check; proc; check -assert` on the
CME top all passed. The hierarchy smoke check also elaborates a wrapper using
`Cme_feed_parser.hierarchical`. Yosys reports zero cells for the constant-output
skeleton; this is not parser synthesis, resource, throughput, or timing evidence.

The migrated suite now uses Step/Cyclesim for inactivity scenarios and native
OCaml inline tests for structural/ABI checks, with deterministic Quickcheck
inputs and a reviewed expect trace. The original executable remains compile-only
as `cme_feed_parser_legacy_assertion_test.ml`. The optional `@rtl-check` alias
preserves only Yosys hierarchy resolution and Icarus elaboration; the original
Yosys lowering result above is historical evidence. See
[Phase 0–1 verification](phase01_verification.md) for current commands and coverage.
