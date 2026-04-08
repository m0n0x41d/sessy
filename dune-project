(lang dune 3.16)
(name sessy)
(generate_opam_files true)

(package
 (name sessy)
 (synopsis "Terminal-native AI session switcher for Claude Code and Codex")
 (depends
  (ocaml (>= 5.4))
  (dune (>= 3.16))
  (yojson (>= 2.1))
  (ppx_yojson_conv (>= 0.17))
  (otoml (>= 1.0))
  (eio_main (>= 1.0))
  (alcotest (and (>= 1.7) :with-test))))
