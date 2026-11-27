# Pine 3.0 ADE acceptance evidence record

Retention structure for the #1761 acceptance gate. One record per candidate
revision; records are updated, not replaced, when a row's implementation or
candidate assumption changes. This file holds the structure, the record for
the base slice executed 2026-11-16, and a single-observation record for the
#1846 ACP v2 real-binary probe (2026-11-26).

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

## Record: ACP v2 real-binary probe (2026-11-26)

A single-observation record for the #1846 opt-in probe
(`PineTests/ACPv2ProbeTests.swift`), not a candidate gate run: no full
suite, scenario fixture, or UI test was executed. It reuses the base
record's environment shape and changes nothing in the base record.

- **Candidate:** `95c9803b1dc47f5b128bbcb39bcfff3d07a97a60` plus the
  uncommitted #1870 edit to `PineTests/ACPv2ProbeTests.swift` (the run
  log's header records `M` on that file) on the #1870 lane branch
  `test/1846-acp-v2-kimi-repin`, 2026-11-26. #1870 merged as
  `44eb1840fa1c17d7e22446cbb17c840a57b39ccf`; refs #1846.
- **Environment** (captured 2026-11-27 with the same selected toolchain as
  the run; the result bundle's device record confirms the macOS line):

  | Field | Value |
  | --- | --- |
  | macOS | 27.2.1, build 26B131 |
  | Xcode | 27.2, build 27B52 |
  | macOS SDK | 27.2, build 26B118 |
  | SwiftLint | not run for this record (documentation-only change); the CI pin is 0.65.1 |
  | Toolchain | `/Applications/Xcode.app/Contents/Developer`, set as `DEVELOPER_DIR` by the queue wrapper for both test runs |

- **Provider versions (read-only probes):**

  | Provider | Version | Probe line (exact output) |
  | --- | --- | --- |
  | `claude-agent-acp` (standalone adapter) | 0.109.1 | `0.109.1` (install-day `--version`, exit 0; not re-run for this record) |
  | `claude` CLI bundled in the same archive | not probed | never executed |
  | opencode, codex-cli, claude, kimi | not probed in this record | no claim |

  Discovery: no `PINE_ACP_V2_BINARY` override is recorded; the first entry
  of the probe's search list, `/opt/homebrew/bin/claude-agent-acp`, exists,
  so that is the binary it found. Handshake: one v2 `initialize` answered
  (below). End-to-end: none.

- **Commands and counts (2026-11-26, UTC):**

  | Command | Result |
  | --- | --- |
  | direct stdio probes, one `initialize` each (15:53:40Z): v2 request; the same with `CLAUDE_AGENT_ACP_PROTOCOL=v1`; v1-shaped request | exit 0; all three answered without an error object; 0.26 s / 0.1 s / 0.1 s process wall time |
  | `xcodebuild ... test ... -only-testing:PineTests/ACPv2ProbeTests` with `PINE_RUN_ACP_V2_SMOKE=1` in the `xcodebuild` environment (15:54:22Z–15:56:12Z) | exit 0 — `ACPv2ProbeTests`: 4 tests, 3 passed / 1 skipped / 0 failed |
  | same command with `TEST_RUNNER_PINE_RUN_ACP_V2_SMOKE=1` (15:57:50Z–15:58:00Z) | exit 0 — `ACPv2ProbeTests`: **4 tests, 4 passed / 0 skipped / 0 failed / 0 expected failures** |
  | `git diff --check` | clean (this documentation change) |

  The test command is the repository's focused-test form with
  `-destination 'platform=macOS'`. In the 4/4 run
  `realV2PeerInitializeHandshake()` passed in 0.211 s wall time (suite
  0.212 s); CPU time was not captured. Negotiated version, quoted from
  that run's log:
  `ACP v2 probe: negotiated protocolVersion 2 with @agentclientprotocol/claude-agent-acp 0.109.1; session capability present. Handshake only — no session created, no prompt sent.`
- **Scenario results:** `ade-negative-scenarios-v1.json` rows and the #1762
  boundary cards were not executed. C1–C11: no gate result is claimed or
  changed. A pinned provider binary was observed, but only through one
  `initialize` sent by the probe's own launch path, not by the Claude
  adapter; Claude's gates stay as the
  [acceptance matrix](ade-acceptance-matrix.md) records them.
- **Artifacts:**
  - Result bundle of the 4/4 run:
    `$TMPDIR/opencode/ade-swarm/results/1846-08-acpv2-probe-test-runner-env.xcresult`
    (present as of 2026-11-27; temporary, not copied to the 14-day
    diagnostics directory).
  - Run log of that run, 192,274 bytes, SHA-256
    `d05413f8156c3025b691bde683004ef5c3ce4571427c7fb75ede967f310a288c`:
    `$TMPDIR/opencode/ade-swarm/logs/1846/08-acpv2-probe-test-runner-env.log`.
  - Direct-probe record (version, identity, capability keys; no session),
    6,187 bytes, SHA-256
    `27c3b4de9a4f4dd04e5ceefa9909ed903876ca0c54868b0cbc7150aa06f877dc`:
    `$TMPDIR/opencode/ade-swarm/tmp/1846/claude-acp-raw/claude-agent-acp-initialize.jsonl`.
  - Install: `claude-agent-acp-darwin-arm64.zip`, 202,506,243 bytes,
    SHA-256 `becbcbb93bf4b0d0a47254324816d6fe60c4b22ab2a765adbceda4192e030d52`,
    the official asset of tag `v0.109.1` (commit
    `4af4581ad510a85d5cdfa3b9100412479e1cfef4`, published 2026-11-21,
    Apache-2.0). It holds `claude-agent-acp` (92,594,562 bytes, SHA-256
    `4d091dbeac3271cd5fe0151d8f6e9aecfbac6ee4d8ac364fbe5e06ef7e3e8294`,
    ad-hoc code signature, no team) and the bundled `claude`
    (363,855,808 bytes, SHA-256
    `f7c5093b9dd6560d08af28bc27b123fb55091deae3180ac39df199522da86815`),
    installed under `/opt/homebrew/opt/claude-agent-acp/` with
    `/opt/homebrew/bin/claude-agent-acp` as a relative symlink; not managed
    by Homebrew. The archive hash equals GitHub's asset digest for the same
    release (same origin as the download: transfer integrity only; the
    release's 8 assets are all archives and there is no checksum file).
    Every hash above was recomputed from the installed files and the
    retained archive on 2026-11-27.
  - No transcript, prompt, or answer content exists for this record: no
    session was created and no prompt was sent. stderr was drained and
    discarded (0 bytes in each direct probe; not counted in the test run).
- **Unresolved limitations:**
  - **v2 message-level flows are not exercised** (owner: #1846). Prompt
    acceptance (`messageId`), foreground/background `state_update`,
    `replay_complete`, and `idempotencyKey` retry were never exchanged with
    the live peer; they are covered by the deterministic envelope tests in
    `ACPv2ProbeTests` only. The #1846 criterion that requires them against
    a maintained v2 adapter is unmet; the issue stays open.
  - **The merged probe revision has no real-binary run** (owner: #1846
    follow-up). The compiled `ACPv2ProbeTests.o` used by both test runs
    contains the #1870 `protocolVersion` guard but still the earlier
    `#expect` identity check, so it predates the review polish in
    `44eb1840f`; the version guard, the request, and the print are the
    same. Per the reuse rule below, the pass is not carried to the merged
    revision: rerun `PineTests/ACPv2ProbeTests` on a current `main` with
    `PINE_RUN_ACP_V2_SMOKE=1 TEST_RUNNER_PINE_RUN_ACP_V2_SMOKE=1`.
  - **The v1 Claude adapter smoke was not run against this install**
    (owner: #1727). `ClaudeCodeACPNativeSmokeTests`
    (`PINE_RUN_CLAUDECODE_ACP_SMOKE=1`), the adapter's executable-identity
    capture, and its own `initialize` gate are unobserved on this binary;
    the direct v1-shaped answer is not the adapter smoke.
  - **Opt-in environment record.** The retained log header names only
    `TEST_RUNNER_PINE_RUN_ACP_V2_SMOKE=1`; whether the plain form was also
    exported is not recorded. The outcome does not depend on it — the test
    ran, which proves the hosted process saw the opt-in.
  - **Provider state.** Both probes gave the child an isolated `HOME` and
    XDG tree and a fresh working directory. The real provider configuration
    directory was fingerprinted (metadata only) as identical before and
    after the direct probes, and was not re-fingerprinted after the test
    runs.
  - **One host, one run:** macOS 27.2.1 only, macOS 26 not exercised, no
    repeat run.
  - **Stale outside this file:** the #1870 body and the 2026-11-25 status
    comment on #1846 still say the real-binary v2 handshake is unexecuted
    on this host. This record supersedes both; neither was edited.
  - **Still not claimed:** provider authentication, an authenticated
    real-model journey, a live permission exchange, and `codex-acp` v2.9.0
    (needs an npm runtime).

## Reuse rule

When a row's owner lands, reuse this record's environment and version
sections; rerun the affected scenario rows and the full local gate; add a
new candidate section. Never carry a pass from an older candidate across a
changed implementation or candidate assumption.
