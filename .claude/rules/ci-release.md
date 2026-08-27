---
paths:
  - ".github/**"
  - "scripts/**"
  - "release-please-config.json"
  - ".release-please-manifest.json"
  - "version.txt"
  - "Package.resolved"
---

# Release, CI, and dependency maintenance

- **Release Please** (`.github/workflows/release-please.yml`) automates versioning and changelog via [Conventional Commits](https://www.conventionalcommits.org/):
  - On every push to `main`, Release Please creates/updates a Release PR with version bump in `version.txt` and auto-generated `CHANGELOG.md`
  - When the Release PR is merged, Release Please creates a git tag (e.g. `v0.13.0`) which triggers the build workflow
  - Config: `release-please-config.json`, manifest: `.release-please-manifest.json`
  - Requires `RELEASE_PLEASE_TOKEN` secret (PAT with `contents: write` + `pull-requests: write`) — default `GITHUB_TOKEN` won't trigger downstream workflows
- **Build workflow** (`.github/workflows/release.yml`) triggers on `v*` tags
- Pipeline: build → code sign → notarize → create DMG → GitHub Release → update Homebrew Tap
- Secrets: `CERTIFICATE_P12`, `CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_ID_PASSWORD`, `APPLE_TEAM_ID`, `TAP_GITHUB_TOKEN`, `RELEASE_PLEASE_TOKEN`
- Homebrew: `brew tap batonogov/tap && brew install --cask pine-editor`
- **CI pipeline** (`.github/workflows/ci.yml`): Lint (Linux) + SourceKit-rules lint (macOS) → Build → Unit Tests (with code coverage) + 7 UI Test shards (parallel) + Flaky Test Summary. All UI tests always run (no conditional skip). Coverage threshold: 70% logic-only (SwiftUI view files excluded). Flaky tests auto-retry once and are reported separately. UI test shards must be balanced (±3 tests, currently 33-35 per shard); verify script checks all test classes are assigned to a shard
- **Branch protection**: requires all checks to pass. Does NOT require the branch to be up-to-date with main, and does NOT use a merge queue — multiple PRs can be merged in parallel/sequence without re-running CI on each. GitHub recomputes mergeability after each merge, but stale branches merge cleanly (3-way merge handles shared files)
- **Action pinning** — all third-party GitHub Actions are pinned by full commit SHA (not mutable tags) for supply-chain safety. To update: find the new version's commit SHA on GitHub (Tags → verify the commit), replace the SHA in the workflow file, and keep the trailing `# vX.Y.Z` comment on the exact release tag (a floating `# vX` comment hides drift once the moving tag advances)
- **Dependency maintenance** — keep every pinned dependency within **N-1 of upstream** (one release behind latest stable); **never downgrade** an already-current pin. The new version/SHA must be a strict descendant of the one it replaces. Run `scripts/check-deps.sh` to list pinned-vs-latest before each pass. Scope:
  - **GitHub Actions** (SHA-pinned across `.github/workflows/*.yml`): `actions/checkout`, `actions/cache`, `actions/upload-artifact`, `actions/download-artifact`, `actions/github-script`, `googleapis/release-please-action`. Bump by replacing the SHA and the trailing `# vX.Y.Z` comment. **Major-version jumps** — notably `upload-artifact`/`download-artifact` (whose v4 line changed artifact immutability) — must land in their own `chore(deps)` PR with a green CI run; do not bundle them into a feature PR.
  - **SwiftLint** (`SWIFTLINT_VERSION` + `SWIFTLINT_SHA256` (Linux binary) + `SWIFTLINT_MACOS_SHA256` (macOS portable binary) in `.github/workflows/ci.yml`): **exception to the N-1 rule above** — this pin tracks the version developers actually run (`brew install swiftlint`, currently 0.65.1) so CI and local lint agree; a lint pin one release behind local just means CI misses violations you already see. The Linux lane enforces everything except SourceKit-dependent rules, which SwiftLint skips silently on Linux; those run in the separate `SwiftLint (SourceKit rules)` macOS lane (#1546), which fails closed if the rule is skipped. When bumping, diff `swiftlint --strict` output between the old and new version across the whole tree before merging, and move all three fields together (the `sha256sum -c -` / `shasum -a 256 -c -` install steps fail closed on a mismatch).
  - **SPM packages** (`Package.resolved`): SwiftTerm, Sparkle, swift-markdown, swift-cmark, swift-argument-parser. Bump via Xcode → File → Packages → Update, then rebuild and run `PineTests` before merge. A bump that regresses behavior is reverted and filed as an issue, not pinned to an older release.
- **Nightly performance** (`.github/workflows/nightly-perf.yml`) — runs performance tests nightly and on schedule, uploads `PerformanceResults.xcresult` artifact, detects regressions via `scripts/check_perf_regression.py`
- **Nightly fuzz** (`.github/workflows/nightly-fuzz.yml`) — scheduled fuzz testing
- **Screenshots** (`.github/workflows/screenshots.yml`) — regenerates GitHub/landing page screenshots in `assets/` on demand

## Adding a dependency

- **Dependency:** SwiftTerm added via Xcode SPM (File > Add Package Dependencies > `https://github.com/migueldeicaza/SwiftTerm.git`)

## Utility scripts

- **Utility scripts** — `scripts/` directory contains `normalize-xcstrings.sh` (called by pre-commit hook to unstage cosmetic xcstrings changes), `reset-cosmetic-xcstrings.sh` (reverts cosmetic-only xcstrings diffs), `test-normalize-xcstrings.sh` (tests for the normalizer), `update-screenshots.sh` (regenerates GitHub/landing page screenshots), `check-no-post-under-inout.py` (pre-commit + CI guard that blocks the exclusivity-abort reentrancy class), `tests/test-check-no-post-under-inout.sh` (tests for that guard), and `check-deps.sh` (read-only dependency audit: prints pinned-vs-latest for GitHub Actions, SwiftLint, and SPM packages — run before each dependency pass)
