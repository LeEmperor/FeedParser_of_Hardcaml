# Documentation index

Start here for the CME MDP 3.0 single-feed 10G parser. Open only the document or
section needed for the task; the XML references are large and can be searched
without loading them in full.

| Document | Contents and when to read it |
| --- | --- |
| [Parser plan](cme_mdp3_10g_parser_plan.md) | Authority for scope, interfaces, module boundaries, phased delivery, and acceptance criteria. Start with **Summary**, then the relevant phase under **Phased delivery plan**. |
| [Phase 0 contracts](phase0_contracts.md) | Detailed public ports, reset/enable and handshake rules, sequencer control, pipeline ownership, provisional event layout, errors, and throughput constraints. Read when implementing or testing parser behavior; distinguishes the inactive skeleton from future behavior. |
| [Phase 1 streaming foundation](phase1_streaming.md) | Implemented ingress/event FIFOs, aligner peek/consume ports, byte offsets, packet isolation, fixtures, and verification evidence. Read before composing the packet-header stage. |
| [Phase 2 packet extraction and sequencing](phase2_packets.md) | Implemented canonical packet pipeline, header/sequence behavior, control fence integration, scoreboard coverage, and performance limits. Read before composing the SBE iterator. |
| [Phase 3 message iteration](phase3_messages.md) | Generic prefix/body iteration, size-bounded recovery, decoder completion and abort ordering, control-fence wiring, and verification evidence. Read before implementing the dispatcher/decoder. |
| [Phase 4 schema tooling](phase4_schema.md) | Production schema provenance/digest, finalized event encodings, generated descriptor, independent golden decoder and PCAP support, fixtures, and verification evidence. Read before implementing or testing the MBP decoder. |
| [Test architecture](test_architecture.md) | Step/Cyclesim fixtures, per-DUT unit/Quickcheck/expect suites, sampling, models, and migration conventions imported from networking. |
| [Synthesis reporting](hardcaml_reports.md) | OCaml/Dune Xilinx reporting command, hierarchy profiles, fresh-artifact validation, and device evidence limits. |
| [Phase 0–1 verification](phase01_verification.md) | Implemented migration, coverage mapping, optional Yosys/Icarus checks, and reporting smoke evidence. |
| [Project conventions](hardcaml_project_conventions.md) | CME source/test locations, attribution policy, interface names, toolchain wrappers, formatting checks, and RTL generation commands. Read before changing code or running verification. |
| [Formatting guide](formatting_guide.md) | Reusable Hardcaml rules for file headers, port suffixes, internal names, interface comments, and formatting. Read the relevant section when writing or migrating modules; pair with project conventions for repository-specific settings. |
| [CME channel configuration](config.xml) | Downloaded product/channel and connection data: feed A/B, multicast addresses, ports, and replay endpoints. Use for channel selection or network integration. Root metadata: `environment="PROD"`, `updated="2026/09/04-17:30:03"`; approximately 19,800 lines / 499 KB. |
| [Pinned CME Production schema](templates.xml) | Canonical Phase 4 build input, schema ID `1`, version `13`, selected template `MDIncrementalRefreshBook46`; provenance and SHA-256 are recorded in the Phase 4 implementation record. |
| [CME SBE templates, v13](templates_v13.xml) | Historical version-named source copy retained for reference. Builds and tests use `templates.xml`. |

The XML metadata above describes the local downloads. `config.xml` is channel
configuration, while `templates.xml` is the provenance-qualified schema pin.
Phase 4 selects template 46; other message templates remain unsupported by v1.

For focused lookups, run these from the repository root, then read a small range
around the matching lines (or extract the matching XML element):

```sh
# Locate a design section before reading it.
rg -n '^#{1,4} ' docs/cme_mdp3_10g_parser_plan.md docs/phase0_contracts.md

# List available SBE messages, or locate the MBP layouts and a shared type.
rg -n '<ns2:message ' docs/templates_v13.xml
rg -n 'name="(MDIncrementalRefreshBook46|MDIncrementalRefreshBookLongQty64|PRICE9)"' docs/templates_v13.xml

# Locate a channel or product before extracting its configuration.
rg -n '<channel id="310"|<product code="ES"' docs/config.xml
```

When inspecting a message, also look up its referenced types and group dimensions.
Update this index when adding documents or replacing XML downloads, especially
if the schema versions or duplicate-file relationship change.
