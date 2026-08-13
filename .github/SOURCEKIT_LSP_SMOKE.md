# SourceKit-LSP smoke testing

Pine runs its real SourceKit-LSP integration suite every day at 06:00 UTC in
`.github/workflows/nightly-sourcekit-lsp.yml`. The workflow can also be started
manually. It is scheduled-only while runner stability is measured, so it does
not block pull requests or releases yet; a failed smoke run still fails its
job.

The job resolves `sourcekit-lsp` through `xcrun` after selecting Xcode and
fails before testing if the executable is missing or belongs to another
developer directory. It runs only
`PineTests/SourceKitLSPIntegrationTests`, without retry-on-failure. The suite
bounds initialize, diagnostics, document synchronization, hover, definition,
graceful shutdown, and forced cleanup. It also verifies that failure,
cancellation, and timeout paths reap the real language-server process.

Every fixture creates an isolated temporary Swift package. The server receives
an allowlisted environment with private HOME, CFFIXED_USER_HOME, XDG config and
cache, SwiftPM config and module cache, Clang module cache, scratch, and TMPDIR
paths. It does not inherit the runner user's configuration. Fixture project and
cache directories are removed after each test. Captured server stderr is
written to `SourceKitLSPArtifacts` so it survives fixture cleanup.

The workflow has a 30-minute job bound, enables per-test timeouts, validates
that the fresh `.xcresult` contains executed passing tests, and always uploads
the result bundle, `xcodebuild` log, and server stderr for 14 days.

## Promotion threshold

Make this lane a required main and release check only after 30 consecutive scheduled runs meet all of these conditions:

- zero functional failures, timeouts, or leaked SourceKit-LSP processes;
- at least 95% infrastructure completion, excluding confirmed runner outages;
- no test skip caused by a missing or mismatched Xcode toolchain component.

Reset the 30-run window after a smoke-test expansion or a failure. Review the
threshold before promoting the lane.

## Local run

Select Xcode, resolve `xcrun --find sourcekit-lsp`, and run:

```sh
PINE_RUN_SOURCEKIT_LSP_SMOKE=1 \
PINE_SOURCEKIT_LSP_EXECUTABLE=/absolute/path/to/sourcekit-lsp \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -project Pine.xcodeproj \
  -scheme Pine \
  -destination 'platform=macOS' \
  -only-testing:PineTests/SourceKitLSPIntegrationTests \
  -parallel-testing-enabled NO \
  -test-timeouts-enabled YES
```
