(lang dune 3.17)

(name feed_parser_of_hardcaml)

(generate_opam_files true)

(formatting
 (enabled_for ocaml))

(package
 (name feed_parser_of_hardcaml)
 (allow_empty)
 (synopsis "FPGA market-data feed parsers (CME, NASDAQ, ...) written in Hardcaml")
 (depends
  (ocaml (>= 5.1))
  (dune (>= 3.17))
  hardcaml
  hardcaml_step_testbench
  ppx_expect
  base_quickcheck
  hardcaml_xilinx_reports
  async
  core_unix
  hardcaml_circuits
  ppx_hardcaml
  ppx_jane
  hardcaml_waveterm
  xmlm
  core))
