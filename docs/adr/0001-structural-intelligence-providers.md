# ADR 0001: LSP-first structural intelligence with local fallbacks

- Status: Accepted
- Date: 2026-07-23
- Issues: [#1182](https://github.com/batonogov/pine/issues/1182),
  [#1008](https://github.com/batonogov/pine/issues/1008)

## Context

Pine currently has three unrelated structural heuristics:

- `FoldRangeCalculator` scans bracket pairs and produces UTF-16 character
  offsets plus 1-based lines.
- `SymbolParser` uses language-specific regular expressions and returns a flat
  symbol list.
- `BracketMatcher` scans around an `NSTextView` UTF-16 caret, excluding the
  comment/string ranges produced by the regex syntax highlighter.

All three execute synchronously from editor or navigator paths. Pine also has a
working, per-language LSP client, but it does not yet decode server
capabilities or request
[`textDocument/foldingRange`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_foldingRange)
and
[`textDocument/documentSymbol`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_documentSymbol).

Adding Tree-sitter to production could provide fast incremental syntax even
without a language server. It would also add a second language-intelligence
stack, grammar/query maintenance, binary cost, and a second range model. We
therefore measured both paths before changing production dependencies.

## Decision

Pine will use a layered model, selected separately per feature:

| Feature | Preferred provider | Fallback | Production dependency change |
| --- | --- | --- | --- |
| Folding | LSP `foldingRange` | Existing bracket `FoldRangeCalculator` | None |
| Document symbols | LSP `documentSymbol` with hierarchy | Existing regex `SymbolParser` | None |
| Bracket navigation/highlight | Existing bounded `BracketMatcher` with syntax skip ranges | Full-file bounded scan already in place | None |

Tree-sitter is not a production provider in the first implementation sequence.
It remains the planned offline structural provider if the exit criteria below
are met. Regex syntax highlighting is unchanged.

### Provider precedence

Each feature chooses exactly one result set for one immutable document
revision. Results from different providers are never merged:

1. A fresh, valid, non-empty LSP result wins.
2. A missing capability, missing executable, timeout, cancellation, transport
   error, invalid range, stale generation, or empty LSP result selects the
   current local fallback.
3. The fallback remains visible while an LSP request is pending. Replacing it
   with an LSP result is one atomic main-actor update.

An empty LSP result deliberately falls back. An empty response can mean “no
structure”, unsupported syntax, or incomplete recovery; using the local result
prevents malformed edits from blanking all folding or symbols.

Bracket navigation stays local because LSP defines no bracket-matching
request. Pulling in a parser solely for this cursor-local operation is not
justified by the measured Swift-only prototype. The existing bounded scan is
also immediately available during every edit and for every grammar Pine
already supports.

### Provider seams

Issue #1008 should introduce data-source-independent seams before adding
endpoints:

```swift
nonisolated struct StructuralDocumentSnapshot: Sendable {
    let identity: UUID
    let revision: Int
    let text: String
    let language: String
}

nonisolated protocol FoldRangeProviding: Sendable {
    func foldRanges(
        for snapshot: StructuralDocumentSnapshot
    ) async throws -> [StructuralFoldRange]
}

nonisolated protocol DocumentSymbolProviding: Sendable {
    func symbols(
        for snapshot: StructuralDocumentSnapshot
    ) async throws -> [StructuralSymbol]
}
```

`StructuralSymbol` is recursive. Both normalized output models carry validated
`NSRange` values and the source revision. They do not expose LSP lines,
Tree-sitter byte ranges, or provider-specific kinds. Existing
`FoldableRange`/`PineSymbol` become UI adapters rather than provider APIs.

### Range ownership

Pine's normalized structural coordinate system is UTF-16 `NSRange`, matching
`NSString`, `NSTextStorage`, and `NSTextView`.

- The LSP adapter owns every LSP `Position`/`Range` conversion. It converts
  against the exact immutable text snapshot used for the request and uses the
  fail-closed behavior of `LSPPositionConverter.utf16OffsetIfValid`. Negative
  values, out-of-bounds lines/columns, reversed ranges, positions inside a
  surrogate pair, and ranges from another revision invalidate the entire
  provider result.
- The client advertises only UTF-16 initially. LSP defaults to UTF-16 when
  `positionEncoding` is absent, as the measured SourceKit-LSP did. A server
  selecting another encoding is unsupported until that encoding has its own
  tested adapter; silently interpreting UTF-8/UTF-32 as UTF-16 is forbidden.
- The LSP adapter expands an omitted folding `startCharacter` to the start of
  its line and an omitted `endCharacter` to the end of its line, excluding the
  line terminator. It validates `DocumentSymbol.range` and
  `DocumentSymbol.selectionRange` independently and requires the selection to
  be contained by the symbol range.
- A future Tree-sitter adapter must parse as UTF-16 and expose only
  `Node.range`. The reviewed Swift binding documents `Node.range` as
  `NSRange`; its encoding-dependent `byteRange` must not escape the adapter.
  `InputEdit` is the sole boundary that converts an `NSRange` to UTF-16LE
  bytes and Tree-sitter points.
- Consumers validate every normalized range against the same snapshot before
  applying it. UI code owns only display conversion (for example, 0-based
  normalized lines to `FoldableRange`'s current 1-based lines).

### Background work, cancellation, and stale results

- The main actor captures document identity, revision, language, and an
  immutable text snapshot. Request/parse work and range normalization run
  away from the main thread.
- Each document has one task per structural feature. A new edit, close,
  language change, server restart, or provider change cancels its predecessor.
- LSP cancellation sends
  [`$/cancelRequest`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#cancelRequest)
  and cancels the local Swift task. Cancellation is advisory, so application
  still requires an exact `(identity, revision, providerEpoch)` generation
  match.
- Folding and symbols use a 250 ms interactive deadline. The local fallback
  remains usable after the deadline; a late response is discarded rather than
  causing visible range churn.
- A future Tree-sitter provider runs on a dedicated serial utility queue per
  document, uses parser timeout/cancellation, calls `reset()` after a timeout,
  and applies a new tree only under the same generation check.
- Provider errors never clear the last valid local result and never block the
  main thread.

## Measured prototype

The checked-in
[`scripts/structural-intelligence`](../../scripts/structural-intelligence/README.md)
tool runs the installed SourceKit-LSP and a separate SwiftPM executable. The
prototype package is not referenced by `Pine.xcodeproj`. Exact raw results are
in
[`2026-07-23-xcode-27-beta.json`](../../scripts/structural-intelligence/results/2026-07-23-xcode-27-beta.json).

The baseline used:

- Pine `56e1a19222f2cf041d2f1d4d599e5c465576ba83`;
- macOS 27 arm64, Xcode 27 beta `27A5218g`;
- Apple Swift `6.4 (swiftlang-6.4.0.25.4)`;
- SourceKit-LSP executable SHA-256
  `7cc11570a25398b677214cddd0463952b3834788de0f33ee4da7911b89b39582`;
- a 425-byte valid fixture, a 411-byte malformed fixture, and a deterministic
  644,047-byte/32,005-line fixture.

### Latency and recovery

All values are milliseconds from one measured run. They are evidence, not CI
thresholds.

| Fixture | LSP fold first / after edit | LSP symbols first / after edit | Tree-sitter cold / incremental |
| --- | ---: | ---: | ---: |
| Valid, 425 B | 59.48 / 1.04 | 2.34 / 0.43 | 0.94 / 0.03 |
| Malformed, 411 B | 2.59 / 0.56 | 0.50 / 0.33 | 0.29 / 0.10 |
| Large, 644 KB | 139.10 / 144.25 | 171.03 / 180.94 | 61.62 / 0.03 |

SourceKit-LSP advertised both capabilities and returned:

- valid: 13 folds and 7 symbols, nested to depth 3;
- malformed: 8 folds and 6 symbols, nested to depth 3;
- large: 14,001 folds and 12,001 symbols, nested to depth 4.

The raw Tree-sitter walk returned useful structure despite an error root in the
malformed fixture (4 fold candidates and 2 declaration symbols). Its
incremental edit reported exactly one changed range. The simple probe walk is
not a curated production query, so its counts are not expected to match LSP.

Cancellation was observable in both paths: SourceKit-LSP answered an immediate
large `documentSymbol` cancellation with JSON-RPC error `-32800`, and every
Tree-sitter fixture honored a one-microsecond parser timeout and recovered
after `reset()`.

### Build, binary, and dependency evidence

SourceKit-LSP is external and already resolved by Pine, so the selected first
sequence adds zero Pine package dependencies and zero bytes to the application
bundle. The measured Xcode toolchain binary itself was 35,848,000 bytes, but
Pine does not ship it.

The tooling-only Tree-sitter probe produced a 4,463,240-byte release
executable. A fresh SwiftPM scratch tree occupied 262,154,423 bytes and
resolved/built in 21.85 seconds with the machine-wide repository cache warm.
This is not an exact Pine bundle delta, but it confirms non-trivial build and
artifact cost that LSP-first avoids.

### Reviewed upstreams

Research date: 2026-07-23. Only primary upstream repositories and the official
LSP specification were used.

| Component | Reviewed revision/release | License | Maintenance observation |
| --- | --- | --- | --- |
| [SourceKit-LSP](https://github.com/swiftlang/sourcekit-lsp/tree/b5d9b039698f52ee417886a8bbec4193b92cd75f) | Xcode toolchain above; upstream `b5d9b03` | [Apache-2.0](https://github.com/swiftlang/sourcekit-lsp/blob/main/LICENSE.txt) | Upstream commit on the research date; bundled with Xcode/Swift toolchains |
| [SwiftTreeSitter](https://github.com/tree-sitter/swift-tree-sitter/tree/0f40435cdb41673ce4194d731571cf2a2f7c3285) | `0f40435`, 2026-05-26 | [BSD-3-Clause](https://github.com/tree-sitter/swift-tree-sitter/blob/0f40435cdb41673ce4194d731571cf2a2f7c3285/LICENSE) | Active and maintained in the official `tree-sitter` organization |
| [Tree-sitter runtime 0.25.10](https://github.com/tree-sitter/tree-sitter/tree/da6fe9beb4f7f67beb75914ca8e0d48ae48d6406) | `da6fe9b`, 2025-09-22 | [MIT](https://github.com/tree-sitter/tree-sitter/blob/da6fe9beb4f7f67beb75914ca8e0d48ae48d6406/LICENSE) | Mature runtime with current releases |
| [Swift grammar generated 0.7.3](https://github.com/alex-pinkus/tree-sitter-swift/tree/31d17fe7e818a2048c808b5c6fdc2dc792f4f5b5) | `31d17fe`, 2026-06-01 | [MIT](https://github.com/alex-pinkus/tree-sitter-swift/blob/31d17fe7e818a2048c808b5c6fdc2dc792f4f5b5/LICENSE) | Active main grammar, but SwiftPM needs its separately maintained generated-source branch |

The grammar's split between current grammar sources and a generated-source
branch is an additional integration/upgrade cost. All three Tree-sitter
revisions are pinned in `Package.resolved`; no mutable branch is used.

## Consequences

### Positive

- Pine reuses language intelligence and processes it already owns.
- Swift gets rich folding, hierarchical symbols, malformed-buffer recovery,
  and cancellation without increasing the production dependency graph.
- Unsupported languages and offline environments retain today's behavior.
- One UTF-16 normalized model prevents provider-specific offsets from leaking
  into editor state.
- Provider seams preserve a measured path to Tree-sitter later.

### Negative

- LSP latency is much higher than Tree-sitter incremental parsing on the large
  fixture, so results must be asynchronous and retain fallbacks.
- Structural quality initially depends on installed server coverage.
- Bracket matching remains heuristic and can still miss language-specific
  constructs outside syntax-highlighter skip ranges.
- LSP and fallback results can differ after an atomic provider switch; they
  must never be merged.

## Rejected alternatives

### Tree-sitter for all three features now

Tree-sitter won the incremental-latency measurement and recovered from
malformed input, but the prototype covers only Swift. Shipping it now would add
runtime, binding, grammar, generated sources, queries, and a second update
cadence before Pine has measured other initially supported languages. It also
does not replace semantic LSP features.

### LSP only, with no fallback

This would blank structure when a binary or capability is missing, violate
offline/unsupported-language behavior, and cannot implement bracket matching.

### Merge LSP and Tree-sitter ranges

Merging creates ambiguous range ownership and unstable duplicate structure.
Provider results are snapshots with different recovery rules; deterministic
precedence is simpler and testable.

## Implementation sequence for #1008

1. Add normalized recursive symbol/fold models, provider protocols, immutable
   document revisions, and fail-closed UTF-16 conversion tests. Dependency set:
   Foundation/AppKit only.
2. Decode initialize capabilities/position encoding and add cancellable
   `foldingRange`/`documentSymbol` requests to the existing LSP client.
3. Wire LSP-first folding with the current calculator always available;
   enforce the 250 ms deadline and generation checks.
4. Make the Symbol Navigator hierarchical and wire LSP-first symbols with the
   current regex parser as fallback.
5. Keep `BracketMatcher` unchanged except for adapting it to the normalized
   snapshot/generation seam. Do not add Tree-sitter.
6. Derive supported-language claims from provider/registry capabilities and
   add valid, malformed, Unicode, CRLF, timeout, cancellation, stale-response,
   and fallback integration tests.

## Tree-sitter exit strategy

Re-open the production dependency decision only with repository evidence that
one of these is true:

- a key language lacks a usable LSP folding/symbol capability;
- p95 LSP structural latency exceeds the 250 ms deadline for representative
  files;
- offline structural quality is a documented product requirement; or
- bracket/syntax recovery defects cannot be fixed within the bounded local
  scanner.

At that point, extend this prototype to every proposed initial language,
measure an actual Pine bundle/build delta, review grammar licenses and
generated-source health again, and implement Tree-sitter behind the same
provider seams. It may replace the fallback for a feature/language, but it must
not merge its ranges with LSP output. Removing that provider later requires no
UI rewrite because provider-specific coordinates remain inside its adapter.
