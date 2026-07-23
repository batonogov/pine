# Structural intelligence prototype

This tooling reproduces the evidence for
[ADR 0001](../../docs/adr/0001-structural-intelligence-providers.md). It
compares `textDocument/foldingRange` and `textDocument/documentSymbol` from
the installed `sourcekit-lsp` with a Swift Tree-sitter parse. It does not add
packages to `Pine.xcodeproj`, link a parser into Pine, or change user-visible
behavior.

## Inputs

- `fixtures/valid.swift` contains nested declarations, closures, emoji, CJK
  text, and the representative document symbol `类型🌲`.
- `fixtures/malformed.swift` deliberately omits closing braces.
- `benchmark.py` deterministically generates a 644,047-byte fixture with
  2,000 nested declarations. Its SHA-256 is checked before every run.
- `tree-sitter-probe/Package.resolved` pins the tooling-only parser stack.

The checked-in fixture hashes and package revisions fail closed under
`--validate-only`. This validation is also run by CI.

## Run

The full benchmark requires macOS, Xcode with `sourcekit-lsp`, Python 3, and
network access for SwiftPM on the first run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  python3 scripts/structural-intelligence/benchmark.py \
  --output /tmp/structural-intelligence.json
```

Use `--sourcekit-lsp /absolute/path/to/sourcekit-lsp` when the active
toolchain is not discoverable through `xcrun`. Use `--scratch-path <path>` to
retain or reuse the SwiftPM build. Without it, the script uses and removes a
fresh scratch directory.

Validate the immutable inputs without Xcode, network access, or a build:

```sh
python3 scripts/structural-intelligence/benchmark.py --validate-only
```

## What is measured

The script records:

- toolchain and executable identity, including the `sourcekit-lsp` SHA-256;
- advertised LSP capabilities and negotiated position encoding;
- fail-closed validation of every folding range, document-symbol range, and
  selection range against the exact UTF-16 snapshot, including selection and
  parent/child containment, with SHA-256 fingerprints of the canonical range
  streams;
- first and post-`didChange` folding/symbol request latency;
- fold count, symbol count, hierarchy depth, malformed-buffer recovery, and
  `$/cancelRequest` behavior;
- Tree-sitter cold parse and incremental reparse latency, changed ranges,
  hierarchy depth, error recovery, and timeout cancellation;
- fresh-scratch SwiftPM release-build time, probe executable size, and total
  scratch-tree size.

Timing values are observations, not pass/fail thresholds. Compare results only
on equivalent hardware and toolchains. A fresh scratch directory can still use
SwiftPM's machine-wide repository cache, so the build number is not a
network-cold download time. The probe executable size is evidence about the
prototype stack, not a promised Pine application-size delta.

The reviewed baseline is
[`results/2026-07-23-xcode-27-beta.json`](results/2026-07-23-xcode-27-beta.json).

The LSP run accepts only negotiated UTF-16. It checks that every reported
position lands on a real UTF-16 boundary (never inside a surrogate pair), every
range is ordered and in bounds, each symbol selection is inside its symbol, and
each child symbol is inside its parent. The representative `类型🌲` selection
must be exactly zero-based line 24, UTF-16 characters `7..<11`: the name is 10
UTF-8 bytes but 4 UTF-16 code units. Both the cold and post-edit evidence are
stored in the baseline JSON, along with fingerprints that cover every validated
folding range and every hierarchical symbol range/selection pair.
`--validate-only` also runs a synthetic surrogate-pair and containment
self-check without starting a language server.

## Pinned tooling dependencies

| Package | Revision | License |
| --- | --- | --- |
| `tree-sitter/swift-tree-sitter` | `0f40435cdb41673ce4194d731571cf2a2f7c3285` | BSD-3-Clause |
| `tree-sitter/tree-sitter` 0.25.10 | `da6fe9beb4f7f67beb75914ca8e0d48ae48d6406` | MIT |
| `alex-pinkus/tree-sitter-swift` generated 0.7.3 | `31d17fe7e818a2048c808b5c6fdc2dc792f4f5b5` | MIT |

These packages belong only to the nested prototype package. Production
dependency selection remains empty under ADR 0001.
