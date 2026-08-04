# Pine 2.0 agent release matrix

This matrix is the release gate for Pine's agent workflows. A row marked
`Pending` blocks the Pine 2.0 release; it must not be converted to `Pass`
without recording the exact environment and a human result. Automated tests
use only checked-in synthetic data and must not read a user's agent config,
credentials, prompts, terminal output, or network services.

## Automated gates

| Gate | Coverage | Release command or evidence |
| --- | --- | --- |
| First-party adapter conformance | Every catalog entry runs the same identity, exact-alias, detected-tier, observed-generation, and generic-fallback assertions | `PineTests/AgentReleaseGateTests` and `PineTests/FirstPartyAgentCompatibilityTests` |
| Protocol and process fixtures | Versioned synthetic working, waiting, completion, failure, malformed, delayed, PID-reuse, and process-replacement streams | `PineTests/Fixtures/AgentAdapters/process-v1.json` and `fake-agent.sh` |
| Multi-project routing and Inbox | Two projects, multiple panes and agents, background project reopen, exact task/run/generation routing, stale routes, relaunch, and project close | `PineTests/AgentInboxTests`, `PineTests/AgentTaskRegistryTests`, and `PineTests/ProjectRegistryTests` |
| Notification correctness | Exact transitions, process-only downgrade, stale/reordered/replacement rejection, cross-project suppression, de-duplication, and persisted settings | `PineTests/AgentNotificationTests` |
| Security and privacy | Spoofs, lookalikes, cross-project identity, replay, path traversal, opaque-value redaction, untrusted registration, and malformed persistence | `PineTests/AgentAdapterContractTests`, `PineTests/AgentAdapterRegistryTests`, `PineTests/AgentReleaseGateTests`, and `PineTests/AgentTaskRegistryTests` |
| Fuzzing | Envelope decoding, identifiers, relative paths, cursors, future trust/source values, and diagnostic redaction | `PineTests/FuzzAgentBoundaryTests`; nightly and opt-in `fuzz` CI jobs |
| Performance | Process polling, provenance-event decoding, durable registry refresh, Inbox projection, and notification transition coalescing | `PinePerformanceTests/AgentWorkflowPerformanceTests`; nightly performance workflow and checked-in budgets |
| Accessibility logic | Keyboard selection, deterministic review behavior, localized announcements, and Reduce Motion animation policy | `PineTests/AgentKeyboardSelectionTests`, `PineTests/AgentInboxTests`, and `PineTests/AgentModelsTests` |
| UI sharding | Every UI test class appears exactly once and shard counts differ by no more than three | `python3 .github/scripts/check_ui_test_shards.py --tests-dir PineUITests --workflow .github/workflows/ci.yml --max-delta 3` |

The blocking unit-test job excludes only deterministic fuzz suites, which run
nightly and when a PR has the `fuzz` label. No automated gate launches a real
agent, uses a paid API, accesses live provider state, or requires network
access.

## Compatibility environments

Record all four commands for every tested OS, even when the failure appears
unrelated to the SDK:

```sh
sw_vers
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -version
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --sdk macosx --show-sdk-version
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --sdk macosx --show-sdk-build-version
```

The currently available macOS 27 beta machine was captured on August 3, 2026:

```text
ProductName:            macOS
ProductVersion:         27.0
BuildVersion:           26A5388g
Xcode 27.0
Build version 27A5218g
SDK version:            27.0
SDK build version:      26A5378i
```

Environment capture is not a manual product pass. Complete each row below on
the named OS and attach the command output plus effective terminal renderer to
the release PR.

| OS | Terminal renderer | Agent detection and replacement | Inbox/review and notifications | Accessibility | Status |
| --- | --- | --- | --- | --- | --- |
| macOS 26.x | Default (Metal when available; record fallback) | Not run | Not run | Not run | Pending |
| macOS 26.x | Forced CoreGraphics (`PINE_DISABLE_METAL=1`) | Not run | Not run | Not run | Pending |
| macOS 27 current beta | Default (Metal when available; record fallback) | Not run | Not run | Not run | Pending |
| macOS 27 current beta | Forced CoreGraphics (`PINE_DISABLE_METAL=1`) | Not run | Not run | Not run | Pending |

For each renderer row, use two projects with at least two terminal panes and
two simultaneous agents. Exercise working, waiting, completion, failure,
terminal close, project-window close/reopen, application relaunch, PID reuse,
and process replacement. Confirm every notification returns only to its exact
task/run/generation and that a stale or replaced run never steals focus.

## Adapter matrix

These claims are deliberately conservative. Process observation is the
supported mechanism and generic execution is the lower-tier fallback; terminal
text is never parsed as trusted lifecycle evidence.

| Adapter | Verified version | Tier | Mechanism | Required fallback | Limitation |
| --- | --- | --- | --- | --- | --- |
| Pi | 0.83.0 | Detected | Exact executable alias + process generation | Generic terminal command | Process termination only |
| Codex | 0.146.0 | Detected | Exact executable alias + process generation | Generic terminal command | Process termination only |
| Claude Code | 2.1.220 | Detected | Exact executable alias + process generation | Generic terminal command | Process termination only |
| OpenCode | 1.18.10 | Detected | Exact executable alias + process generation | Generic terminal command | Process termination only |
| GitHub Copilot CLI | 1.0.77 | Detected | Exact executable alias + process generation | Generic terminal command | Process termination only |
| Aider | 0.86.0 | Detected | Exact executable alias + process generation | Generic terminal command | Process termination only |
| Gemini CLI | 0.53.1 | Detected | Exact executable alias + process generation | Generic terminal command | Process termination only |

If the installed version differs, record it and rerun the shared adapter
conformance suite. Do not raise the tier based on terminal presentation,
timing, an undocumented file, or an unauthenticated local endpoint.

## Manual accessibility and privacy checklist

- Use the keyboard to open the Agent Inbox, traverse every section and row,
  open a task, mark it reviewed/unreviewed, and dismiss eligible history.
- Repeat Inbox/review navigation with VoiceOver. Confirm labels include the
  agent, project, state, freshness, and available action without exposing an
  absolute path, prompt, command output, token, or opaque provider identifier.
- Enable Reduce Motion and confirm attention indicators do not pulse and
  navigation/review state changes remain immediate and understandable.
- Exercise notification permission states: not determined, denied,
  authorized, globally disabled, event disabled, agent disabled, project
  disabled, task muted, duplicate delivery, and click-through after process
  replacement.
- With two projects open, verify the Inbox aggregates both while all review,
  dismissal, navigation, and notification actions affect only the selected
  exact task.
- Inspect logs and crash reports for secrets, environment variables, home
  paths, terminal output, prompts, and raw vendor session/cursor values.
- Run `python3 .github/scripts/check_ui_test_shards.py --tests-dir PineUITests
  --workflow .github/workflows/ci.yml --max-delta 3` after adding or moving any
  UI test class.

Record failures with the exact OS/Xcode/SDK evidence above, adapter version,
support tier, mechanism, renderer, Mac model/chip, and display configuration.
