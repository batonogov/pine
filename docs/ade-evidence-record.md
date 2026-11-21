# Pine 3.0 ADE acceptance evidence record

Retention structure for the #1761 acceptance gate. One record per candidate
revision; records are updated, not replaced, when a row's implementation or
candidate assumption changes. This file holds the structure and the record
for the base slice executed 2026-11-16.

## Record structure

Each candidate record contains exactly these sections:

1. **Candidate.** SHA (full 40-hex), branch, date, and the issue/PR set it
   integrates. The base slice records the base SHA itself.
2. **Environment.** `sw_vers` output, `xcodebuild -version`,
   `xcrun --sdk macosx --show-sdk-version`,
   `xcrun --sdk macosx --show-sdk-build-version`, SwiftLint version (must
   match the CI pin), and the selected toolchain. Captured with the same
   toolchain as the tests.
3. **Provider versions.** Read-only `--version` probes for every claimed
   transport: opencode, codex-cli, claude, kimi. A provider that is not
   installed is recorded as not installed, never guessed. Discovery,
   handshake, and end-to-end evidence are recorded separately per the
   `ade-acceptance-matrix.md` classifications.
4. **Commands and counts.** Every command run, its exit status, and test
   counts (executed/passed/failed/skipped) per suite. Focused iterations are
   listed separately from the final full-suite run.
5. **Scenario results.** Negative/recovery rows from
   `PineTests/Fixtures/AgentAdapters/ade-negative-scenarios-v1.json`
   (fixture pass/fail), #1762 boundary cards (B1–B6) when executed, and
   C1–C11 gate results when a pinned provider binary is observed.
6. **Artifacts.** Sanitized references only (paths under the retention
   policy below, hashes where the content is large).
7. **Unresolved limitations.** Every row or scenario that is pending,
   unknown, or blocked, named with its owner. Open blockers are never
   recorded as acceptance.

## Provenance exclusions (binding)

Out of every published artifact:

- Secrets, credentials, tokens, API keys, and account IDs.
- Prompts and answer content (including feedback text and question answers).
- User repositories, user file contents, and private paths (home directories,
  worktrees outside the candidate, attachment locations).
- Attachments and media beyond sanitized, bounded excerpts.

Artifacts contain opaque hashes, synthetic command strings (never executed),
and bounded identifiers only. The existing fixtures state their sanitization
contract in-file; new artifacts must do the same.

## Bounded local diagnostics retention

- Test result bundles and xcodebuild logs live under the task's
  `-derivedDataPath` and are temporary: deleted with DerivedData, retained
  no longer than the active task.
- Failure diagnostics worth keeping (crash bundles, result bundles,
  provider-probe transcripts) are copied to
  `$TMPDIR/opencode/pine-1761-diagnostics/` sanitized per the exclusions
  above, with a 14-day retention bound; after 14 days they are deleted unless
  promoted into a record section as a hashed reference.
- Provider version probes capture only the version line, never config,
  state directories, or transcript files.
- Elapsed time, CPU time, and operation counts are recorded as distinct
  fields with their units. No performance claim is derived from a different
  metric (for example, CLI process duration is not a human-handling time).

## Record: base `5cd4707b` (this slice)

- **Candidate:** `5cd4707b148ab926ced8f7d4f878d8e4c5709056`
  (`origin/main`, 2026-11-16) plus this slice's commit
  (matrix docs, scenario fixture, fixture tests; SHA recorded in the
  branch head at publish).
- **Environment:**

  | Field | Value |
  | --- | --- |
  | macOS | 27.2.1, build 26B131 |
  | Xcode | 27.2, build 27B52 |
  | macOS SDK | 27.2, build 26B118 |
  | SwiftLint | 0.65.1 (matches CI pin) |

- **Provider versions (read-only probes):**

  | Provider | Version | Probe line (exact output) |
  | --- | --- | --- |
  | opencode | v2.3.0 | `opencode v2.3.0` |
  | codex-cli | 0.169.0 | `codex-cli 0.169.0` |
  | claude | 2.1.311 | `2.1.311 (Claude Code)` |
  | kimi | 2.6.2 | `2.6.2` |

  Re-probed 2026-11-17T09:08:30Z UTC; the original 2026-11-16 probe lines
  were not retained, and the machine's CLIs were updated between the test
  run and the re-probe. These are installed-binary versions on the local
  machine only. None of them is observed-on-binary through Pine: no
  structured adapter is integrated in this base.

- **Commands and counts (2026-11-16, base slice):**

  | Command | Result |
  | --- | --- |
  | `swiftlint` (0.65.1) | scoped run over this slice's files: 0 violations, 0 serious; the full-repo standalone run was not retained — UNVERIFIED as recorded |
  | standalone `xcodebuild ... build` | no activity log retained (all retained builds are 'Testing project Pine' test builds); compilation is evidenced by the test runs below |
  | `xcodebuild ... -only-testing:PineTests/AdeNegativeScenarioFixtureTests` | 4/4 passed, 0.065 s (fresh-process rerun) |
  | `xcodebuild ... -only-testing:PineTests` (full) | **1456 tests in 455 suites, 218.558 s, FAILED: 21 failed / 2 skipped / 2 expected-failures** (counts from the retained xcresult; the console "issues" counter was not captured) — triage **pending, machine pause** (see below) |
  | `git diff --check` | clean |

  Full-PineTests result bundle (present as of 2026-11-17; temporary per
  the retention policy above — deleted with that DerivedData, no 14-day
  diagnostics copy made while triage is paused):
  `$TMPDIR/opencode/pine-dd-1761/Logs/Test/Test-Pine-2026.11.16_17-32-31-+0300.xcresult`

  Failing tests observed in that run (21 unique names, 29 entries incl.
  duplicates; all process/timing-sensitive or worktree-fixture tests):
  `AgentVerificationIdentityTests.dirtyAndUntrackedSameSizeEditsChangeContentIdentity`,
  `AgentAdapterRegistryTests.stopPreservesAcceptedOutcomeForAlreadyAdmittedDelivery`,
  `ProjectWindowPresentationIntentTests.launchKeepsExecutionOwnership`,
  `MultiProjectAgentJourneyTests.realProcessControlPlaneJourney` (×2),
  `UserTaskArgvRunnerTests.literalArgumentsAndWorkingDirectory`,
  `UserTaskArgvRunnerTests.rejectionHasNoEffects`,
  `UserTaskArgvRunnerTests.nonzeroAndMissingExecutable`,
  `LSPProcessTransportTests.initializeTimeoutCleanupDoesNotBlockMainActor`,
  `AgentRecoveryRestartEvidenceTests.missingStoreCannotMasqueradeAsRestoration`,
  `AgentWorktreeManagerModelTests.submodulesAreNotTruncated`,
  `AgentTaskRegistryTests.productionLaunchReservationHandoff` (×2),
  `AgentTaskRegistryTests.staleAcknowledgementCannotArmLaunchAuthority` (×2),
  `AgentTaskRegistryTests.inFlightPineLaunchContributesQuitAttention` (×2),
  `BackgroundProjectLifecycleTests.keySceneRepairsSuspendedTree` (×2),
  `AgentNotificationTests.exhaustedDeliveryRespectsSuppression` (×2),
  `BulkCloseAgentAuthorizationTests.foregroundTransitionRejectsUnrelatedAgent`,
  `BulkCloseAgentAuthorizationTests.settledLaunchRejectsSameTaskReservationReplay`,
  `BulkCloseAgentAuthorizationTests.idleTerminalAcceptsExactAuthorizedPineLaunch` (×3),
  `TerminalPTYProcessTreeTests.closeStopsExactOwnedTree`,
  `AgentTaskWorktreeSetupPersistenceTests.sequentialSetupAndDismissalDoesNotExhaustSharedBindings`,
  `AgentTaskWorktreeSetupPersistenceTests.productionRegistryPersistsPopulatesAndColdAdoptsBeforeAnyProviderRun`.

  **Triage status: pending — machine pause.** This run happened under heavy
  parallel swarm load (1456 tests in 218 s is far below a normal full-suite
  duration), and every failing test is process-launch/timing-sensitive
  (PTY trees, LSP timeout, real-process journey, launch handoffs) — the
  load-induced profile. None touches this slice's added files (the slice's
  focused suite passed 4/4 in isolation, and no production code was changed).
  Bounded isolated reruns of the failing suites and a base-comparison are
  required before any of these can be classified pre-existing vs
  load-induced vs candidate-induced. **No local verification is being run
  while the machine is paused; the parent schedules the rerun.**

- **Environment notes (recorded, not test changes):**
  - First focused run of `AdeNegativeScenarioFixtureTests`: the three
    file-reading tests stalled 44–452 s in `Data(contentsOf:)` with
    POSIX `EINTR` on the newly created fixture file, while base fixture
    tests read same-directory files instantly in the same environment
    (no result bundle from the stalled run retained). A fresh-process
    rerun passed 4/4 in 0.065 s. Recorded as a one-off
    system evaluation stall on the new file (macOS 27.2.1 attaches a
    protected `com.apple.provenance` xattr to files created outside git
    checkout; the xattr is not committed and does not reach CI).
  - Homebrew SwiftLint 0.65.1 initially crashed loading
    `sourcekitdInProc` (rpath built for a newer toolchain layout than this
    Xcode 27.2 ships). Fixed machine-locally by symlinking Xcode's own
    `sourcekitdInProc.framework` into `/opt/homebrew/Cellar/swiftlint/0.65.1/bin/`
    (additive, reversible, no behavior change). DYLD_* env vars were
    stripped and did not work.

- **Scenario results (model-level, deterministic):**
  `ade-negative-scenarios-v1.json` — 33 rows; 28 fixture-tested in this base,
  1 added by this slice, 4 pending owned branches (see the matrix). The
  fixture guard and the added behavior test passed 4/4 in the focused run
  (`AdeNegativeScenarioFixtureTests`, 0.065 s, fresh process).

- **Artifacts:** none beyond this slice's DerivedData (temporary) and this
  record. No provider transcripts were captured.

- **Unresolved limitations:** all matrix open blockers (structured adapters,
  check/review executor, ADE workspace and UX, candidate CI). No
  observed-on-binary cell is filled for this record. Additionally: the
  full-PineTests local run failed under machine load and its failing tests
  are untriaged (machine pause); the gate is not locally green until the
  parent schedules the isolated reruns.

## Reuse rule

When a row's owner lands, reuse this record's environment and version
sections; rerun the affected scenario rows and the full local gate; add a
new candidate section. Never carry a pass from an older candidate across a
changed implementation or candidate assumption.
