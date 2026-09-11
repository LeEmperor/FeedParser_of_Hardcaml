# CME Hardcaml Project Conventions

This document supplies repository-specific settings for the reusable
[Hardcaml formatting guide](formatting_guide.md). Keep these settings separate so
the guide can be copied to other Hardcaml projects without carrying CME paths,
author names, or toolchain assumptions.

## Scope and source layout

- Portable CME RTL and interfaces belong under `lib/cme/`.
- Shared local circuits and RTL generation currently live under `lib/common/`.
- CME tests belong under `test/cme/`; shared test support is under `test/common/`.
- Keep board/network integration dependencies outside the portable CME library.
- Use the [parser plan](cme_mdp3_10g_parser_plan.md) as the authority for the
  parser's interfaces, module boundaries, and acceptance milestones.

Apply the guide to new parser modules and the phase 0 top-level replacement.
Existing UART and helper modules can retain their current interfaces until a
change explicitly includes their migration.

## Headers and interface names

Use the four-part header established by networking's
[`mac_top.ml`](../../hardcaml_networking/lib/mii/mac_top.ml): organization, author,
quoted source filename, and a short description, each in a separate comment.
For this project's OCaml files, including RTL, testbenches, tests, generators,
and reporting support, the default header is:

```ocaml
(* University of Florida *)
(* Author: Bohdan Purtell *)
(* Module: "cme_feed_parser.ml" *)
(* Portable CME MDP 3.0 parser entry point. Phase 0 is an inactive skeleton that
   accepts no payloads or sequencer controls and emits no events. *)

open! Hardcaml
```

Replace the filename and description with those of the file being written. Keep
the filename in double quotes, indent description continuations by three spaces,
and leave a blank line between the header and the code. Longer design notes and
source-provenance details belong in the description comment; retain existing
test tags and deprecation markers.

Preserve existing copyright, license, organization, and author attribution when
editing or importing a file. Keep any different established attribution instead
of replacing it with the project default. This section supplies the project
attribution required by the reusable [formatting guide](formatting_guide.md#2-file-headers).
For new Dune files and shell scripts, use the same fields with `;` and `#`
comments respectively; a shell script's shebang remains its first line.

Use `clock_i`, `reset_i`, and `en_i` for the parser's application-domain controls.
The incoming payload uses `data_i`, `keep_i`, `valid_i`, `first_i`, `last_i`, and
`ready_o`. Events use `event_o`, `event_valid_o`, and `event_ready_i`. Use
`control_ready_o` for sequencer control acceptance. Packet/event value records
retain unsuffixed field names, with explicit mapping at the external boundary.

Reset, enable, control arbitration, and internal ownership are specified in
[the Phase 0 contract](phase0_contracts.md). The current top is explicitly
inactive; smoke tests check that it acknowledges no traffic or controls.

## Toolchain and verification

Run commands from this repository root using the existing switch wrapper:

```sh
./scripts/with-switch.sh dune build
./scripts/with-switch.sh dune runtest
```

The wrapper defaults to the `5.2.0+ox` switch and accepts an `OPAM_SWITCH` override.
`tools/dune_build.sh` and `tools/dune_test.sh` also wrap the build and test commands.

The checked-in `.ocamlformat` uses the Jane Street profile and pins binary
revision `3aa293b`, reported by the installed OxCaml `ocamlformat` package
`0.26.2+ox2`. Bootstrap installs that package version when requested and verifies
the binary revision during its default check. `.ocamlformat-ignore` explicitly
excludes legacy UART/helper modules; remove each exclusion when migrating that
file. Dune formatting is enabled for OCaml sources only, keeping unrelated Dune
stanzas outside this migration. Use:

```sh
./scripts/with-switch.sh dune build @fmt
./tools/dune_fmt.sh
```

The first command checks formatting; the second invokes `dune fmt` to apply it.
Do not import the networking repository's `@lint` command unless an actual lint
alias is added here. Review formatter diffs and keep unrelated modules outside
the change's scope.

CME verification follows [test_architecture.md](test_architecture.md). The active
Phase 0 suite lives in `test/cme/cme_feed_parser/`. It checks generated Verilog port names,
directions and widths, event packing and reserved encodings, FIFO configuration,
and skeleton inactivity across reset/enable and offered traffic/control cases.
It does not yet validate parsing or the future stateful reset/control behavior.
Phase 1 has separate `ingress_fifo/`, `event_fifo/`, `byte_aligner/`, and
`stream_foundation/` inline suites. Each exposes a Step testbench, unit/Quickcheck
properties, and expect traces. Shared support lives in `test/common/verif/` and
`test/cme/verif/`, with the preserved source/monitor/hardware fixture in
`test/cme/stream_fixture.ml`. Legacy assertion executables compile but are not
part of `runtest`. `packet_pipeline/` now tests the Phase 2 header/sequencer integration with an
independent packet scoreboard and control-fence scenarios; see
[Phase 2](phase2_packets.md). `message_pipeline/` and `event_orderer/` now test
Phase 3 message traversal/recovery and decoder-event ordering; see
[Phase 3](phase3_messages.md). `schema/` contains the Phase 4 direct-XML unit,
Quickcheck, expect, checksum, and classic-PCAP oracle tests; see
[Phase 4](phase4_schema.md). Later phases extend these conventions for the RTL
decoder and system tests.

`./scripts/with-switch.sh dune build @rtl-check` runs the optional thin Yosys
hierarchy and Icarus elaboration checks. Device reporting is the separate
`synthesis/xilinx_reports.exe` command; see [reporting](hardcaml_reports.md) and
[current verification evidence](phase01_verification.md). Neither external
backend is part of ordinary functional `runtest`.

Generate RTL with:

```sh
./scripts/with-switch.sh dune exec lib/common/generate.exe -- cme
./scripts/with-switch.sh dune exec lib/common/generate.exe -- uart
```

Outputs are ignored `cme_mdp3_feed_parser.v` and `uart_test_top.v` at the project
root. No generator argument preserves the UART default. The CME RTL carries an
inactive-skeleton notice; unused declared inputs are retained in its port list.
