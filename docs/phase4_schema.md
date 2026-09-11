# Phase 4: pinned schema tooling and independent reference decoder

Implemented 2026-09-05 against CME Production core schema ID 1, version 13. This
phase selects `MDIncrementalRefreshBook46` (template ID 46), generates hardware
extraction constants during the Dune build, and provides a separate XML-driven
software oracle. It does not add the Phase 5 RTL decoder or activate the public
`Cme_feed_parser` top.

## Production schema pin

| Property | Pinned value |
| --- | --- |
| Repository file | `docs/templates.xml` |
| CME distribution URL | `https://www.cmegroup.com/ftp/SBEFix/Production/Templates/templates_FixBinary.xml` |
| Pin date | 2026-09-05 |
| Distribution directory observation | Current Production file listed as modified 2025-04-09 16:39, size 143K |
| XML metadata | package `mktdata`, ID `1`, version `13`, description `20230411`, `littleEndian` |
| SHA-256 | `f45ebadf65ccb1a2d416f00ee755480072ecff030970cc170a78540541d78d60` |
| Selected message | `MDIncrementalRefreshBook46`, ID 46, since version 9 |

`docs/templates.sha256` is checked by `dune runtest`. The versioned
`templates_v13.xml` download remains as a historical source copy; all Phase 4
builds and tests use the canonical `templates.xml` pin. CME's distribution
directory and message-schema documentation identify the Production directory as
the authoritative source and describe `blockLength`, explicit offsets, and
appended schema extensions.

## Final normalized-field decisions

The Phase 0 event remains 677 bits. No ABI width changed.

| Normalized field | Selected wire definition |
| --- | --- |
| Entry index/count | Event containers are unsigned 16-bit; `groupSize.numInGroup` is unsigned 8-bit |
| `SecurityID` | `Int32`, retained as 32 raw two's-complement bits |
| `RptSeq` | `uInt32`, 32 bits |
| Price | `PRICENULL9.mantissa`, signed 64-bit; null `9223372036854775807`; constant exponent `-9` |
| `MDEntrySize` | optional signed 32-bit; null `2147483647` |
| `NumberOfOrders` | optional signed 32-bit; null `2147483647` |
| `TradeableSize` | optional signed 32-bit; null `2147483647`; present since version 10 |
| `MDPriceLevel` | unsigned 8-bit |
| `MDUpdateAction` | unsigned 8-bit enum values 0–5 |
| `MDEntryType` | 8-bit character enum: `0`, `1`, `E`, `F`, `J`, plus `w` and `x` since version 12 |
| `MatchEventIndicator` | unsigned 8-bit set; bit 7 is `EndOfEvent` |
| `TransactTime` | unsigned 64-bit root field, present for the selected template |

Nulls normalize to a zero value plus the existing field-specific null flag.
Fields absent due to `sinceVersion` use the same normalized representation. The
software model preserves signed numeric minima as values, distinct from CME's
positive maximum sentinels.

## Schema parser and generated descriptor

`lib/schema/` is a software-only library using `xmlm`. `Schema_xml` reads the
pinned XML into reusable definitions for primitive integer/character types,
constants, optional nulls, composites, enums, sets, explicit offsets,
`sinceVersion`, fixed blocks, group dimensions, and repeating fields.
`Mbp_descriptor` resolves only the selected message and rejects missing or
unsupported selected-template shapes with the template and XML construct in the
error.

`lib/cme/dune` invokes `schema_descriptor_generator.exe` and creates
`generated_mbp_descriptor.ml` in Dune's build tree. The generated module contains
schema/template constants, root and group dimension layouts, field offsets and
widths, signed/null/version metadata, and legal enum values. It is deterministic
and is never maintained by hand. Changing `docs/templates.xml` automatically
regenerates it.

## Independent golden decoder

`Golden_decoder` loads `templates.xml` directly and resolves its own field
locations. It does not import `Mbp_descriptor`, `Schema_codegen`, or
`Generated_mbp_descriptor`. Its input is a UDP payload byte string beginning with
the 12-byte CME packet header. It models:

- first-packet sequence initialization, modulo-32 expected sequence, gaps,
  duplicate/late drops, session reset, resynchronization, and channel validity;
- packet and ten-byte SBE message headers, trustworthy-size traversal,
  unsupported-template skip, and packet truncation;
- schema ID/version compatibility, version-gated fields and enum values, runtime
  root/group block lengths, and compatible appended padding;
- one normalized update per `NoMDEntries` entry, nullable signed values, a legal
  zero-entry message, end-of-event, and runtime skipping of `NoOrderIDEntries`;
- ordered structural, schema, enum, and sequence diagnostics.

`Pcap_payloads` independently extracts UDP payloads and nanosecond ingress
timestamps from classic PCAP Ethernet/IPv4/UDP records. It rejects malformed
captures explicitly and ignores non-UDP and fragmented IPv4 frames. PCAPNG and
non-Ethernet link types are intentionally outside the Phase 4 fixture scope.

## Reference fixtures and verification

`test/cme/schema/` encodes packet/message/group bytes directly rather than using
generated offsets. Named tests cover hand-checked signed and unsigned limits,
every null sentinel, all selected enum sets, zero and multiple entries, version 9
field absence, newer-version appended root/group padding, runtime MBO group
skipping, incompatible schemas and blocks, invalid enums, malformed/truncated
messages, sequence gaps/duplicates, and classic-PCAP extraction. A deterministic
100-trial Quickcheck property generates schema-valid entry values. The compact
expect trace reviews two normalized updates followed by end-of-event.

Verification command:

```sh
./scripts/with-switch.sh dune build @all @runtest @fmt
```

The Phase 5 decoder can consume the generated build artifact, while its
differential tests can compare against this independent oracle.
