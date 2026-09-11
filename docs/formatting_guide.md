# Hardcaml Source Formatting Guide

## 1. Purpose

This guide defines reusable source formatting and signal-naming conventions for Hardcaml
hardware modules. It does not require a particular protocol, board, organization, directory
layout, or toolchain wrapper. An adopting project should record its paths, attribution policy,
formatter configuration, and verification commands in a separate project conventions document.

The rules apply primarily to synthesizable modules, wherever the project stores them.
Testbench-local variables, software-only helpers, and direction-neutral value types follow
the exceptions described below.

Apply the guide to new modules and code being deliberately migrated. Preserve existing
interfaces outside the change's scope, especially when external RTL consumers depend on their
names. Treat a port rename as an interface change and update its consumers together.

## 2. File headers

Each hardware source file has a filename comment and a description. Projects that require
organization and author attribution prepend those as separate comments, producing this
four-part layout (replace placeholders with accurate project values):

```ocaml
(* Organization or copyright attribution, when required *)
(* Author: actual author, when required *)
(* Module: "module_name.ml" *)
(* Short description of the module.

   Additional paragraphs remain inside the fourth comment. Continuation lines use the
   indentation shown here.
*)
```

The header fields mean:

1. The optional first comment identifies the organization or copyright holder.
2. The optional second comment identifies the author according to project policy.
3. The third comment contains the source filename in quotation marks.
4. The fourth comment describes the module, its boundaries, and any important implementation
   context.

When editing or formatting a file:

- Preserve existing copyright, license, organization, and author attribution; do not
  invent attribution or replace it with example text from this guide.
- Preserve the header fields as separate comments.
- Preserve their order.
- Do not combine the attribution, module, and description fields into one block.
- Do not remove the quotation marks around the module filename.
- Keep longer design notes inside the description comment.
- Update the module filename if the file itself is renamed.

Any required license notice takes precedence over the example layout. Projects without an
attribution-header requirement use just the filename and description comments.

## 3. External port names

Hardcaml module ports use lower snake case and an explicit direction suffix.

### 3.1 Input ports

Every field in a module's `I` interface ends in `_i`:

```ocaml
module I = struct
  type 'a t =
    { clock_i : 'a
    ; reset_i : 'a
    ; data_i : 'a [@bits 64]
    ; valid_i : 'a
    }
  [@@deriving hardcaml]
end
```

Examples include:

- `clock_i`
- `reset_i`
- `request_valid_i`
- `event_ready_i`

### 3.2 Output ports

Every field in a module's `O` interface ends in `_o`:

```ocaml
module O = struct
  type 'a t =
    { data_o : 'a [@bits 64]
    ; valid_o : 'a
    ; error_o : 'a
    }
  [@@deriving hardcaml]
end
```

Examples include:

- `data_o`
- `request_ready_o`
- `event_valid_o`
- `overflow_o`

The suffix rule applies to every external port category, including:

- Clocks and resets
- Data and control buses
- Valid and ready handshakes
- Enables
- Status and error indicators
- Debug ports

Signal direction is always relative to the module declaring the `I` or `O` interface, not
relative to the surrounding system or remote endpoint. For example, a stream consumer
declares `valid_i` and `ready_o`; a stream producer declares `valid_o` and `ready_i`.
Handshake signals belong in `I` or `O` according to their actual direction.

## 4. Direction-neutral types

Do not add `_i` or `_o` to fields of a type that represents a value rather than a directional
module interface.

For example, a stream beat may be produced or consumed by multiple modules:

```ocaml
module Beat = struct
  type 'a t =
    { data : 'a [@bits 64]
    ; keep : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end
```

`Beat.data` and `Beat.keep` remain unsuffixed because `Beat` has no inherent direction.
Map these fields to directional port names at the module boundary. When using nested
interfaces, configure and inspect generated RTL names so the external leaves have the
intended direction suffix; a suffix on the OCaml container alone is not proof of RTL naming.

Other direction-neutral types include:

- FIFO words
- Operation descriptors
- Internal pipeline records
- Parsed headers
- Test vectors and expected-value records

## 5. Internal signal names

Internal signals and local OCaml bindings do not require `_i` or `_o`. Use a concise name
that describes the signal's role:

```ocaml
let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in
let buffered_data = reg spec i.data_i in
{ O.data_o = buffered_data }
```

This distinction keeps direction suffixes meaningful:

- `i.clock_i` is an external input port.
- `buffered_data` is an internal signal.
- `O.data_o` is an external output port.

Avoid carrying `_i` or `_o` through an entire internal pipeline merely because the original
value entered through an input or will eventually drive an output.

## 6. Interface comments

Group related ports by function and clock domain. Place the comment immediately before the
first field in the group:

```ocaml
module I = struct
  type 'a t =
    { (* Processing domain; active-high synchronous reset. *)
      clock_i : 'a
    ; reset_i : 'a
    ; (* Upstream payload, synchronous to clock_i. *)
      data_i : 'a [@bits 64]
    ; valid_i : 'a
    ; (* Event consumer, synchronous to clock_i. *)
      event_ready_i : 'a
    }
  [@@deriving hardcaml]
end
```

Comments should identify:

- The producer and consumer when that relationship is not obvious
- The clock domain
- Whether reset is synchronous or asynchronous
- Reset polarity and enable behavior when those affect transfers
- Any nonstandard validity or integration behavior
- Important ownership boundaries

Do not repeat information already made obvious by the field name and type.

## 7. Port references in implementation code

Access inputs through the typed input record:

```ocaml
let spec = Reg_spec.create ~clock:i.clock_i ~clear:i.reset_i () in
```

Construct outputs using their complete suffixed field names:

```ocaml
{ O.data_o = data
; valid_o = valid
; error_o = error
}
```

Comments that name an external port should use its complete `_i` or `_o` name. Comments that
describe a protocol concept rather than a concrete port may use the protocol name without a
suffix.

## 8. Tests and documentation

Testbenches access the same generated interface fields and therefore use the same suffixes:

```ocaml
i.reset_i := Bits.vdd;
expect_int "output valid" o.valid_o 0;
```

Interface tables and signal-specific prose in documentation must also use the complete port
names. When a port is renamed, update:

- The declaring `I` or `O` record
- All implementation references
- Testbench drivers and monitors
- Documentation tables and prose
- Generated-RTL or integration scripts that refer to the port by name

## 9. Formatting and verification

Use the adopting project's pinned formatter and configuration rather than manually aligning
code. Prefer two-space indentation, lower snake case for values and filenames, and normal
OCaml module capitalization such as `Packet_header`, `I`, and `O`. The formatter determines
line wrapping and record layout; this guide does not override its output.

A project using Dune may provide checks such as:

```sh
dune build @fmt
dune runtest
dune build
```

Run these through the project's toolchain wrapper when required. Use the project's formatter
application command (often `dune fmt`) to apply formatting. Run a lint alias only when one is
defined; neither `@lint` nor a particular wrapper path is a requirement of this portable guide.
Record missing configuration explicitly instead of treating an absent check as a passing one.

Before considering a source naming or formatting change complete:

1. Confirm all `I` fields end in `_i`.
2. Confirm all `O` fields end in `_o`.
3. Confirm direction-neutral record fields remain unsuffixed.
4. Confirm source headers follow project policy and existing attribution remains intact.
5. Search for stale port names in source, tests, documentation, and integration code.
6. Run configured formatting/lint checks, affected tests, and the build. For port changes,
   also inspect generated RTL names and check the affected integration boundary.

Documentation-only changes require checking examples, paths, and consistency with the
project's actual configuration; they do not require a hardware test run.
