# Sanitizer testing

Pine runs separate AddressSanitizer and ThreadSanitizer jobs from
`.github/workflows/nightly-sanitizers.yml`. The workflow runs every day at
05:00 UTC and can also be started manually from the Actions tab. It is
scheduled-only so sanitizer adoption starts non-blocking, while findings still
fail the individual job.

Both jobs consume `.github/sanitizer-test-manifest.txt`. The manifest is kept
small enough for a 60-minute job budget and represents Pine's highest-risk
native and concurrency boundaries:

- terminal, subprocess ownership, SwiftTerm, AppKit, and Metal;
- agent detection, terminal ownership, and durable task persistence;
- file watching and external-change delivery;
- LSP process and stream lifecycle;
- tab, pane, project, window, save, and termination races.

`UserTaskRunnerTests` and `LSPProcessTransportTests` exercise real child
processes. Their lifecycle assertions require termination and reaping before a
test completes so one case cannot leave a process behind for the next case.
The manifest runs serially and enables per-test timeouts as a second bound.

The sanitizer command is deliberately run once. There is no
`-retry-tests-on-failure`: an initial sanitizer finding must remain a failed
run. Each job uploads its `.xcresult`, full `xcodebuild` console log, and any
per-process sanitizer logs for 14 days. No suppressions are currently used.
Any future suppression must be scoped to one report, link an owner issue, name
an owner, and include a review date in this document and next to the option.

## Promotion threshold

Make the lanes required release gates only after both sanitizers achieve all
of the following over 30 consecutive scheduled runs:

- zero sanitizer findings;
- at least 95% infrastructure completion, excluding confirmed runner outages;
- no unbounded test or leaked-process incident.

Reset the 30-run window after a sanitizer finding, a manifest expansion, or a
new suppression. Review the threshold and manifest when promoting the jobs.

## Local run

Select the same Xcode used by CI, turn each non-comment manifest line into an
`-only-testing:` argument, and run `xcodebuild test` with one of these options:

- `-enableAddressSanitizer YES`
- `-enableThreadSanitizer YES`

Also pass `-parallel-testing-enabled NO`, `-test-timeouts-enabled YES`, and a
fresh `-resultBundlePath`. Never add retry-on-failure to a sanitizer run.
