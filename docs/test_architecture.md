# Verification architecture for the financial parser

Use the verification structure established in `hardcaml_networking`: OCaml
scenarios drive Hardcaml through `hardcaml_step_testbench`, typed observations
feed unit/property tests and expect tests, and Dune discovers and runs the suites.
Phase 0–1 now use this architecture; later phases extend it. The implemented
coverage and commands are recorded in [phase01_verification.md](phase01_verification.md).

The destination is the current `cme/` checkout, called `feed_parser_of_hardcaml`
in `dune-project`, with RTL library `cme_of_hardcaml`. “Financial” describes the
intended project; the separate sibling `hardcaml_financial/` is not the target of
this document. Paths and Dune examples below use this checkout's actual names.

The [parser plan](cme_mdp3_10g_parser_plan.md) and
[Phase 0 contracts](phase0_contracts.md) remain the behavioral specification.
This document defines test organization and execution. Pair it with
[the reporting architecture](hardcaml_reports.md) for synthesis and timing, and
[project conventions](hardcaml_project_conventions.md) for local tooling.

## Source and scope of extraction

Extracted on 2026-09-05 from the local `hardcaml_networking` checkout at commit
`4109a4a6540e3c328e431cfa58a6e7526fa9733f`, using both its settled conventions
and implemented suites:

| Source | What to reuse |
| --- | --- |
| [Test architecture](../../hardcaml_networking/test/test_architecture.md) | The **Settled Conventions** section; later exploratory notes are not requirements. |
| [Shared fixture](../../hardcaml_networking/test/common/verif/sim_fixture.ml) and [Dune library](../../hardcaml_networking/test/common/verif/dune) | Typed DUT functor, Cyclesim/Step construction, bounded execution. |
| [TX CRC testbench](../../hardcaml_networking/test/mii/tx_crc/tx_crc_testbench.ml), [properties](../../hardcaml_networking/test/mii/tx_crc/tx_crc_unit_quickcheck_tests.ml), [expect tests](../../hardcaml_networking/test/mii/tx_crc/tx_crc_expect_tests.ml), [Dune](../../hardcaml_networking/test/mii/tx_crc/dune) | Complete migrated suite, deterministic generation/shrinking, legacy executable. |
| [Width-adapter testbench](../../hardcaml_networking/test/common/axis_width_adapter_8_to_64/axis_width_adapter_8_to_64_testbench.ml) and [properties](../../hardcaml_networking/test/common/axis_width_adapter_8_to_64/axis_width_adapter_8_to_64_unit_quickcheck_tests.ml) | Closest streaming example: accepted beats, backpressure, low-lane packing, packet boundaries. |
| [UART testbench](../../hardcaml_networking/test/uart/uart_tx/uart_tx_testbench.ml) | Independent protocol decoder, interval observations, total error reporting. |
| [Hierarchy tests](../../hardcaml_networking/test/common/hierarchy_manifest/hierarchy_manifest_tests.ml) | OCaml assertions over circuit databases and emitted RTL. |
| [Sweep findings](../../hardcaml_networking/docs/verif_sweep_findings.md) | Reasons behind sampling, toolchain, and regression conventions. |

Sibling links require the workspace layout used for this extraction. The
instructions below are self-contained for a standalone checkout.

## One suite per DUT or integration boundary

For DUT `foo`, use this layout (three active OCaml modules, an optional legacy
module, and Dune metadata):

```text
test/
  common/verif/
    dune
    bits_conv.ml
    sim_fixture.ml
  cme/
    verif/                         # CME support shared by multiple suites
      dune
      stream_model.ml
      generators.ml
    foo/
      dune
      foo_testbench.ml
      foo_unit_quickcheck_tests.ml
      foo_expect_tests.ml
      foo_legacy_assertion_test.ml # only when superseding an existing harness
```

The generic layout above remains the convention for new suites. Current CME
support uses `verif/stream_scenarios.ml` for the shared ingress/integration driver
and `verif/stream_monitor_tests.ml` for negative contract tests. The adapted
`stream_fixture.ml` retains the original byte sources, monitor, and hardware
fixture for active and legacy consumers. Introduce a standalone software decoder
and shared generators as later phases require them.
Give integration boundaries their own suite directories, such as
`stream_foundation/` and `cme_feed_parser/`, using the same pattern.

| File | Responsibility |
| --- | --- |
| `foo_testbench.ml` | `module Dut`, fixture instantiation, complete input construction, reset, drivers/monitors, typed `Observation`/`Output_snapshot`, scenarios, and `run_*` entry points. |
| `foo_unit_quickcheck_tests.ml` | Named `let%test_unit` examples and deterministic `Quickcheck.test` properties against independent expectations. |
| `foo_expect_tests.ml` | Small `let%expect_test` traces using the same scenarios and typed observations. |
| `foo_legacy_assertion_test.ml` | Superseded harness, kept compiling as a bare executable and excluded from `runtest`. |

Within a behavioral suite, the testbench owns `Bits`, Step, port assignments,
and sampling. Tests consume plain OCaml values and never duplicate a simulator
driver. Shared fixture/conversion support may also use Hardcaml. Dedicated
structural/ABI tests may inspect interfaces and circuit objects directly, as
networking's hierarchy tests do; do not force them through a cycle driver.

The UVM correspondence is lightweight: scenario = test/sequence, driver = Step
input producer, monitor = typed observation collector, scoreboard = software
model plus assertions. These roles need no class hierarchy or separate runner.

## Shared support and independent models

Start with a local `hardcaml_verif` library under `test/common/verif/`, following
networking's `Bits_conv` and `Sim_fixture`. It is test support, with no dependency
from production `lib/cme/`. If the projects later share one Dune workspace,
resolve duplicate private library names explicitly or extract a shared package.

`Sim_fixture.Make` accepts `I : Interface.S`, `O : Interface.S`,
`create : Scope.t -> Signal.t I.t -> Signal.t O.t`, and a diagnostic `name`.
It exposes:

- `Sim = Cyclesim.With_interface (Dut.I) (Dut.O)`.
- `Step = Hardcaml_step_testbench.Functional.Cyclesim.Make (Dut.I) (Dut.O)`.
- `create_simulator`, using a flattened simulation scope with hierarchical port
  labels enabled.
- `run_with_timeout`, converting the runner's `None` into a named test failure.

Keep Step's API visible rather than inventing wrappers around every operation.
Every scenario must have a finite execution bound and must fail on timeout;
an incomplete observation is not a passing result. Driver completion should
mean all expected transfers were observed and the scenario drained, not merely
that the source ran out of offers.

Networking also supplies CRC, Ethernet, IPv4/UDP models and generators. Those
are examples of pure software support, not dependencies to copy into a parser
that begins at framed UDP payloads. CME shared support should instead provide
byte/packet values, framing models, reproducible traffic schedules, and later
the independent SBE decoder required by Phase 4. Keep one-suite helpers local
until a second suite needs them.

Model accepted bytes, packet boundaries, sequencing decisions, and normalized
events independently of RTL implementation. Do not reuse the RTL's extraction
logic as the expected decoder. Do not use the driver's pack/unpack round trip
as the only oracle: add asymmetric literal vectors that can expose a shared
endianness mistake. Preserve full bit patterns with `int64` or another suitable
representation; OCaml `int` is unsuitable for arbitrary 64-bit fields.

## Scheduling, observations, and reset

`Step.cycle` returns both sides of the edge. Define the sampling meaning in
each testbench before writing assertions:

| Observation | Sampling rule |
| --- | --- |
| Accepted ready/valid transaction | Use inputs and outputs from the same cycle, normally `Step.O_data.before_edge`, to decide which offer transfers at that edge. |
| Updated register, occupancy, accumulator, or entered state | Use `Step.O_data.after_edge`. |
| Combinational control consumed during the cycle | Use `before_edge`; `after_edge` may already select the next operation. |
| Purely combinational DUT | Check equality of both views where that is part of the contract. |

For CME, follow `active = en_i && !reset_i`, reset precedence, enable pause,
handshake suppression, and source resumption exactly as specified in the
[contract](phase0_contracts.md#reset-enable-and-handshakes). Networking's CRC
enable signal reloads its accumulator; that behavior must not be imported as
CME enable semantics. A synchronous reset changes stored state at the edge,
even when combinational handshake suppression is already visible before it.

Sources retain an unaccepted valid offer and its meaningful sidebands during
backpressure, subject to the specified reset/pause rules. Advance source and
scoreboard positions only on actual transfers. Record accepted input/output
transactions separately from offered or stalled observations. Check stability
over consecutive stalled cycles, then compare drained output for loss,
duplication, ordering, and context preservation.

Use protocol-level expected results for functional tests and cycle indices for
explicit latency/throughput properties. For the Phase 6 latency requirement,
record acceptance of the final required entry byte and assertion of the
corresponding output event under the specified ready conditions; do not measure
from the first offer or silently substitute output retirement for validity.

## Unit tests, properties, and reviewable goldens

Use `let%test_unit` and `[%test_result: t]` for named deterministic cases and
model comparisons. Generate bounded scenarios with `Quickcheck.test`, an
explicit ``~seed:(`Deterministic "suite-property")``, explicit trial count,
`~sexp_of`, and a shrinker when available. Preserve validity constraints when
shrinking a valid packet; malformed inputs should be intentional cases. Save
the minimized failing input as a named regression.

Exercise boundary cases directly even if generators cover them: full/empty
FIFO transitions, simultaneous enqueue/dequeue, offsets 0–7, all legal final
lane counts, same-beat first/last, partial packets, reset with pending work,
enable pauses, bubbles, and backpressure. Parameterized tests should include
non-power-of-two depths when supported and asymmetric byte patterns, so a
default value cannot conceal a wrap or byte-order bug.

Expect tests reuse the testbench's scenarios. Print short structured sexps;
use compact hexadecimal fields for wide values and aligned waveform rows for
bit-per-cycle behavior. Keep detailed numeric observations for assertions and
a separate compact presentation when useful. Long randomized runs belong in
unit/property tests, not enormous golden traces.

Phase 4's software oracle is deliberately outside the Step/Cyclesim DUT path. Its
fixtures encode bytes independently, load the pinned XML rather than generated
RTL descriptors, and use the same named unit, deterministic Quickcheck, and
compact expect conventions. Phase 5 and 6 use that oracle at the hardware test
boundary without sharing field-offset code.

Start a new golden empty, run its suite, inspect the correction, promote only
the intended file, then read the result against the behavioral contract. A
golden records current behavior; promotion alone does not establish correctness.

## Dune wiring

The following is the standard `test/cme/foo/dune` pattern for this library name:

```lisp
(library
 (name foo_inline_tests)
 (modules foo_testbench foo_unit_quickcheck_tests foo_expect_tests)
 ; Networking's ppx_expect v0.18~preview drops the source directory when
 ; registering tests. The trailing flag overrides Dune's workspace-root value;
 ; "." points at the runner's cwd, where Dune copied the test sources.
 ; Remove this workaround only after verifying an upgraded ppx_expect fixes it.
 (inline_tests
  (flags (:standard -source-tree-root .)))
 (libraries core hardcaml cme_of_hardcaml hardcaml_step_testbench hardcaml_verif)
 (preprocess (pps ppx_hardcaml ppx_jane)))
```

Add the `cme_verif` support library to `libraries` when the suite uses it.
The shared `hardcaml_verif` stanza needs `core`, `hardcaml`,
`hardcaml_step_testbench`, and the same PPX preprocessing; it has no inline
tests of its own. Follow [networking's actual stanza](../../hardcaml_networking/test/common/verif/dune).

`dune-project` now declares `hardcaml_step_testbench`, `ppx_expect`, and
`base_quickcheck` alongside the existing `ppx_jane`/`ppx_hardcaml` setup, and Dune
regenerates the `.opam` file.
Do not copy networking's `alcotest` dependency or `ppx_js_style` lint stanzas
just to reproduce its dependency list: Alcotest is deferred in its settled
architecture, and this project has no established `@lint` workflow.

When coverage has been ported, keep a superseded harness in a separate
`(executable (name foo_legacy_assertion_test) (modules foo_legacy_assertion_test)
...)` with its required libraries and preprocessing. Mark its header
`Tags: [{ "DEPRECATED" ; "ASSERTION_TEST" }]`. It should compile under
`dune build`, with no test stanza or `runtest` rule invoking it. Do not move
unported assertions out of the active test path.

Commands from this checkout's root after the relevant suite exists:

```sh
./scripts/with-switch.sh dune build @fmt
./scripts/with-switch.sh dune build
./scripts/with-switch.sh dune runtest test/cme/foo
./scripts/with-switch.sh dune runtest
# Only after reviewing the generated correction for this file:
./scripts/with-switch.sh dune promote test/cme/foo/foo_expect_tests.ml
# Rerun the affected suite after promotion.
```

Use targeted promotion in a shared working tree. Do not run a blanket promotion
that could accept another contributor's expect changes.

## OxCaml implementation traps to preserve from networking

When forwarding the local Step handler through the fixture, preserve the
explicit, unparenthesized function type from `sim_fixture.ml`:

```ocaml
let run_with_timeout
  ~timeout
  ~(testbench : Step.Handler.t @ local -> Step.O_data.t -> 'a)
  =
  (* Construct simulator and invoke Step.run_with_timeout here. *)
  ...
```

In this OxCaml API, changing the inferred arity to a function returning a
closure can make the local handler escape its region. Likewise, an allocating
`List.map` closure capturing the handler can be rejected. Follow networking's
explicit recursive driver loops with a locally annotated handler. Use
sequential `let` bindings for short effectful sequences; list-literal evaluation
order must not determine the order of simulation cycles.

A DUT with optional `create` arguments needs an adapter fixing those arguments
to match `Sim_fixture.S`; do not simply `include Dut`. Parameterized testbench
functors should expose observation types outside the functor when multiple
configurations must share a runner list. Plain `Signal.t` helper functions
need a small suite-local DUT wrapper with `I`/`O`/`create`; an output that is
literally an input may need `wireof` to elaborate.

## Migration status and completion criteria

The Phase 0 top and Phase 1 stream migration is implemented. The two former
executables remain compile-only legacy harnesses; all their assertion categories
remain active in the new suites. The main plan now records this architecture.
The sequence below documents the migration boundaries and guides later phases:

1. Add shared fixture/conversion support and one pilot suite, preferably a FIFO
   or byte aligner. Keep the current tests running while their checks are ported.
2. Split stream-foundation checks into per-DUT suites plus a pass-through
   integration suite. Preserve the existing monitor invariants and literal
   vectors; adapt the current `stream_fixture.ml` rather than dropping its
   coverage during a rewrite.
3. Move the top's ABI/event-layout/configuration checks into active inline
   coverage. Keep inactivity assertions explicitly tied to Phase 0; replace
   them deliberately as real functionality becomes specified and implemented.
4. Add packet/sequencer, message-walker, and decoder suites as their phases
   arrive. Share the independent software decoder with system differential
   tests, and retain small goldens at each useful boundary.
5. Add Phase 6 stress, uninterrupted-stream throughput, and latency properties
   to the same architecture. Keep device reports in the separate Dune
   reporting executable described in [hardcaml_reports.md](hardcaml_reports.md).

A migrated suite is complete when its prior assertions remain covered, its
scenarios terminate within explicit bounds, deterministic properties print
reproducible failures, reviewed goldens are clean, and Dune both compiles and
runs the intended active modules. Record known behavioral discrepancies
explicitly instead of silently promoting them or changing RTL during migration.

The implemented networking baseline is Step + Cyclesim. Its settled document
defers both Alcotest adoption and EventSim suites; the later backend-neutral
notes describe a future extension. Use an OCaml event-driven backend later
when real multiple clocks, asynchronous reset, or primitive behavior require
it, with separate evidence for those capabilities. Routine parser verification
runs through Dune's OCaml suites. The optional `@rtl-check` alias preserves
Yosys `hierarchy -check` and Icarus Verilog elaboration as thin backend smoke
checks, independently of `runtest` and the Xilinx reporting command. Neither
external check simulates behavioral test vectors or serves as device reporting.
