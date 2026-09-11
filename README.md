# FeedParser_of_Hardcaml

Portable Hardcaml CME MDP 3.0 feed parser, starting at a framed 64-bit UDP payload
stream. The public parser now decodes template-46 MBP entries and emits ordered
normalized updates, end-of-event markers, and diagnostics. Phases 0–5 are
implemented. [Phase 6 verification](docs/phase6_verification.md) passes the
functional, cycle-level performance, and structural checks, with fresh device
reports recorded. The parser **meets its 156.25 MHz target on the deployment
part** `xcu50-fsvh2104-2-e` (Alveo U50) post-synthesis, WNS +0.340 ns with zero
failing endpoints; see [retargeting](docs/retargeting.md) for both device
profiles and what remains. It does not meet 156.25 MHz on the Arty's
`xc7a100tcsg324-1`, which is the functional-validation part and runs at a 25 MHz
application clock. [Phase 7 integration](docs/phase7_integration.md) now supplies
the Arty harness, UART counters, synthetic sender and passing full MII simulation.
The native harness also passes Vivado synthesis/implementation timing and all seven
physical Ethernet/UART cases on the programmed Arty A7.

The [delivery plan](docs/cme_mdp3_10g_parser_plan.md) describes the phases and
acceptance criteria. The [Phase 0 contracts](docs/phase0_contracts.md) define the
module hierarchy, reset/enable behavior, control priority, internal streams, and
provisional event layout. Follow the
[project conventions](docs/hardcaml_project_conventions.md) for source changes.

Use the existing `5.2.0+ox` opam switch (override with `OPAM_SWITCH`):

```sh
./bootstrap.sh
./scripts/with-switch.sh dune build
./scripts/with-switch.sh dune runtest
./scripts/with-switch.sh dune build @fmt
./scripts/with-switch.sh dune exec lib/common/generate.exe -- cme
```

`./bootstrap.sh --install-deps` installs the project dependencies if needed.
`./tools/dune_fmt.sh` applies the pinned formatter. The CME generator requires an explicit
target and prints the available subcommands when one is omitted. The `cme` target writes
`cme_mdp3_feed_parser.v`; generate the native Arty top with
`-- cme_feed_parser_validation_harness_arty`. Generated Verilog is ignored by Git.

Phase 1's bounded FIFOs, two-beat byte aligner, and pass-through fixture are
integrated into the parser top. The
[Phase 0–1 verification record](docs/phase01_verification.md) maps their active
Step/Cyclesim unit, Quickcheck, and expect suites.

[Phase 2 packet extraction and sequencing](docs/phase2_packets.md) now provides
`Packet_pipeline`: a tested canonical packet stream with header removal, sequence
admission, ordered diagnostics, duplicate draining, and fenced reset/resync
controls.

[Phase 3 message iteration and recovery](docs/phase3_messages.md) adds
`Sbe_message_iterator`, the composed `Message_pipeline`, and `Event_orderer`.
They expose bounded message bodies, recover at trustworthy message or packet
boundaries, and serialize diagnostics with downstream decoder events. Template
admission is configurable; the public parser selects production template 46.

Optional backend checks and device project generation:

```sh
./scripts/with-switch.sh dune build @rtl-check

# Production closure: the deployment part at the production clock.
./scripts/with-switch.sh dune exec synthesis/xilinx_reports.exe -- cme-feed-parser \
  -dir _build/xilinx-reports/u50 -part xcu50-fsvh2104-2-e \
  -clock clock_i:156.25 -full-design-hierarchy true -jobs 1

# Functional validation: the Arty part at its application clock.
./scripts/with-switch.sh dune exec synthesis/xilinx_reports.exe -- cme-feed-parser \
  -dir _build/xilinx-reports/arty -part xc7a100tcsg324-1 \
  -clock clock_i:25 -full-design-hierarchy true -jobs 1
```

Yosys checks hierarchy and Icarus checks elaboration. The reporting command
invokes Vivado only with `-run`; see [reporting](docs/hardcaml_reports.md) for
profiles and evidence limits. Every recorded device number must name both its
part and its clock — [retargeting](docs/retargeting.md) explains why, and what
holding the validation part to the production clock cost this project.

[Phase 4 schema tooling and reference decoding](docs/phase4_schema.md) pins CME
Production schema ID 1/version 13, generates template-46 extraction descriptors
during the Dune build, and supplies an independent XML-driven golden decoder with
synthetic and classic-PCAP fixtures.

[Phase 5 decoding and normalized events](docs/phase5_decoding.md) implements the
RTL MBP decoder and activates the public parser, including schema/version rules,
runtime group skips, event storage, and full-payload differential checks. Packet
truncation tests verify ordered cut-through prefixes and recovery under stalls.

Phase 7 integration verification uses the installed `hardcaml_networking` package to emit
the native `cme_feed_parser_validation_harness_arty` hierarchy and requires Icarus; see
[setup and acceptance](docs/phase7_integration.md):

```sh
./validation/phase7/check.sh
```

The board sender verifies seven cases using UART counter snapshots and writes a
JSON capture plus raw UART bytes. Build and physical capture commands are in the
Phase 7 document.
