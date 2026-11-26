# CLI agent compatibility

Pine 2.0 uses a versioned, fail-closed compatibility model. Detection means
that Pine observed a supported executable in one of its terminal process
trees. It does not mean that Pine can read a provider's private state, infer a
successful completion, or resume a provider session.

The executable release procedure, automated gate inventory, OS/renderer test
matrix, and accessibility checklist live in the
[Pine 2.0 agent release matrix](pine-2.0-agent-release-matrix.md).

The checked-in catalog schema is version 1. **Catalog fixture version** below
identifies the version label in the synthetic process-name fixture; it is not
a minimum protocol version or a certified integration version. Retained
**Detected** entries provide process snapshots with observed process-generation
trust, manual terminal launch/new sessions, and process termination observations
only. A separately marked structured adapter adds its documented owned transport;
it does not add account/model discovery or verified completion. The manual
terminal can still run arbitrary programs.

The [dated capability evidence audit](cli-capability-evidence-2026-11-14.md)
separates source review, fixtures, limited version/help observations, handshake,
and end-to-end checks for every entry. It records identity, evidence dates and
platform gaps, current upstream transport candidates, and required follow-up.
The catalog's version labels are intentionally unchanged by the newer
version/help observations: the 1.18.10 fixture remains the V1 detection
record. The OpenCode V2 ACP integration landed on `main` on 2026-11-22
(#1843), pinned to `opencode v2.4.0` (re-probe 2026-11-24, #1866), and is
recorded in the OpenCode row and section below.

Empry⊙ first-party recognition/presentation is retired with
[#1766](https://github.com/batonogov/pine/issues/1766) (2026-11-14 decision).
Legacy records and manual generic terminal use remain; there is no planned
structured adapter. The earlier wrapper version probe changed its runtime;
that observation is not passive discovery and must not be repeated for a badge.
The active catalog and all nine Help pages reflect this retirement.

| Agent | Executable aliases | Catalog fixture version | Tier | Event source and trust | Launch / resume | Notification accuracy | Current limitation |
| --- | --- | --- | --- | --- | --- | --- | --- |
| [Pi](https://github.com/badlogic/pi-mono) | `pi` | 0.83.0 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | No structured transport enabled; upstream candidates and limitations are recorded in the dated audit. |
| [Codex](https://github.com/openai/codex) | `codex` | 0.146.0 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | No structured transport enabled; upstream candidates and limitations are recorded in the dated audit. |
| [Claude Code](https://github.com/anthropics/claude-code) | `claude` (terminal detection), `claude-agent-acp` (owned adapter) | 2.1.220 | Structured via official ACP adapter | ACP v1 over Pine-owned child stdio; observed process generation | Owned official adapter; exact `session/load` only by explicit user action as a new attempt; no auto-resume | Main-turn end is unverified, never Ready by itself | Adapter pin 0.109.1; synthetic fixtures and composition only. Real adapter handshake, provider authentication, and an authenticated real-model journey are not claimed. Provider auth/configuration remains adapter-owned. |
| [OpenCode](https://github.com/anomalyco/opencode) | `opencode` (terminal detection), `opencode acp` (owned V2 adapter) | 1.18.10 (V1 detection); 2.4.0 (V2 ACP) | Structured via OpenCode V2 `acp` adapter | ACP v1 over Pine-owned child stdio; observed process generation | Owned V2 adapter task dispatch from the Pine UI (in development; not in the latest release) plus manual terminal / new session; exact-ID `session/load` only by explicit user action as a new attempt; no auto-resume | Process termination only | Pinned `opencode v2.4.0`; deterministic fixtures and composition only, with an opt-in real-binary smoke that uses no model prompt and no auth mutation. Provider authentication and an authenticated real-model journey are not claimed. Main-turn end is unverified, never Ready by itself. |
| [GitHub Copilot CLI](https://github.com/github/copilot-cli) | `github-copilot-cli`, `copilot` | 1.0.77 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | No structured transport enabled; upstream candidates and limitations are recorded in the dated audit. |
| [Aider](https://github.com/Aider-AI/aider) | `aider` | 0.86.0 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | No structured transport enabled; upstream candidates and limitations are recorded in the dated audit. |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli) | `gemini` | 0.53.1 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | No structured transport enabled; upstream candidates and limitations are recorded in the dated audit. |
| [Amp](https://ampcode.com/manual) | `amp` | 0.0.1785747753-g51f676 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | No structured transport enabled; upstream candidates and limitations are recorded in the dated audit. |
| [Cursor Agent](https://docs.cursor.com/en/cli/overview) | `cursor-agent` | 2026.07.23-e383d2b | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | No structured transport enabled; upstream candidates and limitations are recorded in the dated audit. |
| [Goose](https://github.com/aaif-goose/goose) | `goose` | 1.45.0 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | No structured transport enabled; upstream candidates and limitations are recorded in the dated audit. |
| [Qwen Code](https://github.com/QwenLM/qwen-code) | `qwen` | 0.21.4 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | No structured transport enabled; upstream candidates and limitations are recorded in the dated audit. |
| [Crush](https://github.com/charmbracelet/crush) | `crush` | 0.88.0 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | No structured transport enabled; upstream candidates and limitations are recorded in the dated audit. |
| [Kimi Code](https://www.kimi.com/code/docs/en/) | `kimi`, `kimi-code` | 2.1.1 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | Structured `kimi acp` ACP floor recorded below; production activation stays pending the real-version smoke and task-owner wiring. |
| [Antigravity](https://antigravity.google/docs/cli/headless) | `agy` | 1.5.6 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | No structured transport enabled; upstream candidates and limitations are recorded in the dated audit. |
| [Droid](https://docs.factory.com/droid-cli/cli-reference) | `droid` | 1.9.0 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | No structured transport enabled; upstream candidates and limitations are recorded in the dated audit. |
| [Cline](https://github.com/cline/cline) | `cline` | 3.0.74 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | No structured transport enabled; upstream candidates and limitations are recorded in the dated audit. |
| [Grok Build](https://github.com/xai-org/grok-build) | `grok` | 1.0.77 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | No structured transport enabled; upstream candidates and limitations are recorded in the dated audit. |
| [Kilo Code](https://github.com/Kilo-Org/kilocode) | `kilo`, `kilocode` | 7.8.27 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | No structured transport enabled; upstream candidates and limitations are recorded in the dated audit. |

Empry⊙ first-party detection and presentation were retired on November 14,
2026. Existing task and history records remain readable as generic historical
metadata, and remembered defaults require a new explicit agent choice. Manual
terminal commands remain available. Empry⊙ is excluded from Pine 3.0 structured
adapter plans; historical release records remain unchanged.

## Claude Code official ACP adapter (#1727)

Claude's structured route is the official standalone `claude-agent-acp`
process, launched as a Pine-owned child. It is not the earlier native
stream-json/control launch path. The adapter wraps and owns the bundled Claude
CLI, provider authentication, and native configuration; Pine neither reads nor
manages Claude credentials, OAuth state, or keychain entries. The standalone
macOS x64/arm64 archives need no Node.js installation. The inherited
`CLAUDE_CODE_EXECUTABLE` setting may select a local CLI instead of the bundled
one; this does not relax the adapter identity/version pin.

| Item | Claude Code value |
| --- | --- |
| Transport | Literal-argv `claude-agent-acp` with no subcommand; ACP v1 JSON-RPC 2.0 over the shared bounded Pine-owned stdio channel/framer (JSONL frames ≤ 1 MiB); process-group stop/reap and bounded secret-free stderr drain |
| Pinned adapter | 0.109.1 exactly; `--version` has a 5-second cap and initialize requires protocol 1 plus `agentInfo.name == "@agentclientprotocol/claude-agent-acp"` and the same exact version |
| Protocol floor | ACP v1 only in this slice. ACP v2 Preview is not negotiated or enabled |
| Sessions | `session/new`; exact-ID `session/load` is a separate explicit action in a new Pine attempt/source namespace. No process reattachment, auto-resume, reconnect, or automatic prompt resend |
| User input | One-shot `session/request_permission` (`allow_once`/`reject_once`) and the strict form-only `elicitation/create` subset. Identical redelivery of an answered request replays its exact response; unsupported schemas and unowned reverse RPC fail closed |
| Cancellation | `session/cancel`; remains requested until the provider confirms cancellation. Late completion is a race outcome and queued input is never automatically resent |
| Main-turn end | `session/prompt` `end_turn` (including the other bounded terminal reasons) is unverified main-turn completion only. It never proves background-work settlement, checks, review, or Ready |
| Provider configuration | `mcpServers: []` from Pine and inherited native adapter configuration. Provider authentication is not inferred from process ownership or a successful ACP handshake |
| Verification boundary | Executable identity, framing, session/control behavior, ownership composition, stopped-provider replacement, and teardown have deterministic local coverage. This slice records no real adapter handshake result; no authenticated real-model turn or live permission exchange is claimed |

The opt-in `PINE_RUN_CLAUDECODE_ACP_SMOKE=1` (or
`$TMPDIR/pine-claude-acp-smoke`) check uses
`PINE_CLAUDECODE_ACP_BINARY`, a synthetic working directory, no model prompt,
and no auth mutation. It composes without launching, starts to idle with a
bound native session, and tears down the owned process. It remains the final
local smoke gate for the real adapter handshake; provider authentication and a
real-model journey are separate acceptance evidence, not implications of this
integration slice.

## OpenCode V2 ACP adapter (#1843)

OpenCode's structured route is the `opencode acp` entry point, launched as a
Pine-owned child with ACP v1 JSON-RPC 2.0 over the shared bounded Pine-owned
stdio channel/framer, per the [ACP reuse and dual-stack v1/v2 decision
record](ade-acp-reuse-comparison-2026-11-23.md).

| Item | OpenCode value |
| --- | --- |
| Transport | Literal-argv `opencode acp`; ACP v1 JSON-RPC 2.0 over the shared bounded Pine-owned stdio channel/framer; process-group stop/reap |
| Pinned binary | `opencode v2.4.0` exactly (`--version` has a 5-second cap and ACP `agentInfo.version` must equal `2.4.0`; re-probe 2026-11-24, #1866); any other version is refused |
| Protocol floor | ACP v1 only (`protocolVersion` 1); no v2 preview negotiation |
| Sessions | `session/new`; exact-ID `session/load` is a separate explicit action that replays bounded saved updates in a new Pine attempt. No process reattachment, auto-resume, or automatic prompt resend |
| User input | Request and same-session feedback through the Pine UI task sheet (in development); `session/request_permission` answered once with `allow_once`/`reject_once`; `session/cancel` remains requested until the provider confirms |
| Configuration | ACP `configOptions` discovery maps model/effort to probed capabilities with native options; explicit overrides for unknown/unsupported capabilities fail the launch policy closed (#1850); no configuration UI yet |
| Verification boundary | Deterministic fixture/contract suites (2.4.0 turn and fault fixtures) are the CI gate. The opt-in `PINE_RUN_OPENCODE_ACP_SMOKE=1` (or `$TMPDIR/pine-opencode-acp-smoke`) spawn check uses `PINE_OPENCODE_BINARY`, a synthetic working directory, no model prompt, and no auth mutation; it is the local gate for the real handshake. Provider authentication and an authenticated real-model journey are not claimed |

In-app status: the task sheet is dispatchable from the Pine UI on `main`
(#1848) and reports working, waiting, result, and unverified states as adapter
observations; it is in development and is not part of the latest release.
Notification accuracy remains process termination only: verified waiting-input
notifications are not claimed for OpenCode (#1753/#1754).

## Tier meanings

- **Generic:** Pine can host the command in a terminal but makes no identity or
  lifecycle claim.
- **Detected:** Pine recognizes an exact executable alias and observes the
  process generation. Lookalike names remain generic.
- **Attention-aware:** Pine has a verified provider signal for a user-action
  transition. No first-party adapter currently claims this tier.
- **Structured:** Pine negotiates a documented structured lifecycle contract
  over an owned authenticated channel. Claude's and OpenCode's rows mark
  integrated ACP adapter composition, not a completed authenticated provider
  journey. The Kimi Code CLI structured adapter (#1732) below stays
  **Detected** until its real-version smoke passes on the pinned binary.

## Kimi Code CLI structured ACP floor (#1732)

Pine ships a structured adapter for `kimi acp` (ACP protocol major 1, JSON-RPC
over stdio). The column below records the exact pinned Kimi Code CLI version
for every enabled capability; the pin is the version whose documented
capability matrix was verified against the [kimi acp
reference](https://www.kimi.com/code/docs/en/kimi-code-cli/reference/kimi-acp.html),
the [kimi command
reference](https://www.kimi.com/code/docs/en/kimi-code-cli/reference/kimi-command.html),
and the [session persistence
guide](https://www.kimi.com/code/docs/en/kimi-code-cli/guides/sessions.html).
The gate is exact equality: any other version is refused until re-pinned
through a fresh dated observation.

| Capability | Pinned CLI version (exact) |
| --- | --- |
| initialize-capability-matrix | 2.6.2 |
| session-new | 2.6.2 |
| session-prompt-text | 2.6.2 |
| session-prompt-image | 2.6.2 |
| session-prompt-text-resource | 2.6.2 |
| session-load-history-replay | 2.6.2 |
| session-resume-no-replay | 2.6.2 |
| session-fork | 2.6.2 |
| session-cancel | 2.6.2 |
| session-request-permission | 2.6.2 |
| elicitation-form | 2.6.2 |
| additional-directories-new-only | 2.6.2 |
| config-options-dynamic-parse | 2.6.2 |

Evidence status: the codec, mapping, request state machine, and sanitized
fixture corpus are fixture-verified and deterministic. Re-probed
2026-11-17T09:57:16Z (artifact `$TMPDIR/opencode/pine-1732-reprobe/`):
`kimi --version` = 2.6.2 and ACP `initialize` observed at 2.6.2
(protocolVersion 1, `loadSession` true, no server→client requests at init);
`session/new` answered `Authentication required`, so the per-capability rows
are documented-contract at the pinned version. The Kimi contract scenarios
await the shared provider outcome table port (#1821). The real-version smoke (bounded `kimi --version` discovery plus an
`initialize` handshake, terminated before any session call) is the final
gate, PENDING; until it passes on the pinned binary, the catalog record above
remains **Detected** and no structured tier is claimed.

Observed 2026-11-26 on the local machine, not re-pinned: Homebrew `kimi`
2.7.3 printed `2.7.3` and answered a v1 `initialize` as `Kimi Code CLI`
2.7.3 with the same capability matrix (`session/new` was not sent). The pin
stays 2.6.2 because Pine's executable identity model refuses the installed
2.7.3 entry: Homebrew links `kimi` to the bundled `dist/main.mjs` shebang
script (25,382,638 bytes), above the 1 MiB entry cap of
`KimiACPExecutableIdentity`, so `capture` fails with `unsupportedBinary`
before the version probe. Re-pinning needs a maintainer decision on that cap
and a fresh dated observation; see the
[decision record, section 7.3](ade-acp-reuse-comparison-2026-11-23.md#73-close-out-runs-2026-11-26).

Deliberate boundaries:

- `session/load` replays bounded history before settling; `session/resume`
  never replays; both start a NEW ACP process and a new Pine attempt/source
  namespace — neither is a reattachment to an old live process.
- `session/fork` (capability `session-fork`) sends only the source session ID:
  Kimi ignores supplied cwd/directories/MCP on fork, so no environment or
  configuration change is advertised merely because a request field was accepted.
- `additional-directories-new-only` is sent on `session/new` only; Kimi honors
  it there and nowhere else.
- Prompt content blocks (`text`, `image`, `resource` with text) are included
  only when the user explicitly supplied them. Documented dropped blob
  resources (no text) are rejected with an explanation before submission;
  feedback and attachments are preserved under #1758.
- Reverse-RPC client capabilities (`fs/read_text_file`, `fs/write_text_file`,
  `terminal/*`) are NOT advertised: Pine does not implement their ownership,
  authorization, bounds, cancellation, and teardown, so the agent acts on its
  own supervised process. URL-mode `elicitation/create` is not advertised and
  is rejected on receipt, letting Kimi fall back to
  `session/request_permission`.
- Provider authentication is checked separately from transport ownership: a
  non-empty `authMethods` list requires a verified terminal-auth observation
  from the separate auth UI before Pine creates a session. `--yolo`, `--auto`,
  hook installation, `kimi web`, and `--dangerous-bypass-auth` are never used.
- Dynamic `configOptions` are parsed with graceful unknown-type handling;
  `providers/*`, `nes/*`, `document/*`, and `elicitation/complete` are not
  implemented by Kimi and are never called.
- A permission denial or cancellation is a first-class outcome; cancellation
  is requested until the provider confirms the resulting turn state, and
  nothing is auto-resent after cancellation or reconnect.
- No in-channel reconnect: channel loss settles the attempt as `unknown`, and
  recovery is an explicit relaunch + `session/load` of the durable session.
- Form schemas outside the strict subset are refused (`methodNotFound`), and
  Kimi falls back to `session/request_permission`, turning an open-ended
  native question into a binary approval.
- MCP inheritance is not recorded because Pine forwards no MCP servers
  (`mcpServers: []` on every session call).

## Configuration capability observations (#1765)

Per-setting execution capability is recorded with the shared
`AgentTaskConfigurationCapabilities` model: `researched` (documented at the
pinned version, not observed by Pine), `probed` (observed on a live pinned
connection, no apply/readback cycle), `supported` (override applied and its
effective value read back — none claimed yet), `unsupported`, and `unknown`.
Transport observation beats the version floor; a setting absent from both
stays unknown. Every state below is produced from actual session observations
and stays fail-closed: a malformed or missing observation degrades to the
floor or unknown, never to a manufactured capability.

| Adapter (pinned) | model | reasoning effort | permissions | Effective-value readback |
| --- | --- | --- | --- | --- |
| Codex `0.169.0` (app-server) | researched floor; probed only when `model/list` is observed **with a non-empty catalog** at session start (native catalog options enumerated) | researched floor; probed only when the observed catalog carries `supportedReasoningEfforts` | researched floor (documented per-thread `approvalPolicy`/`sandbox`); probed only when `config/read` carries `approval_policy` or `sandbox_mode` | `config/read` confirms effective `model`, `model_reasoning_effort`, `approval_policy`(+`sandbox_mode`) as native labels; an empty catalog or config keeps the floor |
| Kimi `2.6.2` (ACP) | researched floor (re-probed 2026-11-17: `session/new` auth-gated); observed `configOptions` entry `model` (select) → probed | researched floor; observed `thinking` (select) → probed | researched floor; observed `mode` (select — the session permission mode: ask / never-ask / plan, per the CLI reference) → probed | ACP `currentValue` of an observed option is readback evidence for that setting only |
| Claude adapter `0.109.1` (ACP) | researched floor (v0.109.1 source-reviewed 2026-11-23; no real handshake claimed); observed `model` option (category `model`; present only when the gateway lists models) → probed | researched floor; observed `effort` option (category `thought_level`; present only when the model supports effort) → probed | researched floor; observed `mode` option (category `mode`, "Session permission mode"; always present) → probed | ACP `currentValue` of an observed option is readback evidence for that setting only |
| OpenCode `2.3.x` (ACP, #1850; not re-observed after #1866 re-pin to 2.4.0) | observed ACP `configOptions` → probed | observed → probed | unknown (OpenCode's `mode` is a primary agent, never mapped) | deferred in #1850; `currentValue` is validated but not yet recovered |

Evidence notes:

- Codex: `model/list`, `config/read`, and per-thread `approvalPolicy`/`sandbox`
  are verified against the pinned `rust-v0.169.0` protocol sources
  (non-mutating reads; `config/read` answers with the effective config after
  layering). The installed-machine version may differ from the pin; the
  session always re-admits the exact pinned image before the connection
  exists.
- Kimi: the documented `model`/`thinking`/`mode` option IDs come from the
  Kimi ACP reference (the `set_config_option` "unified model / thinking /
  mode picker dispatcher") and the pinned fixture (`mode`, `currentValue:
  "ask"`). Pine never calls `session/set_config_option` in this slice, so no
  overridable scope is claimed and no override is ever applied.
- Claude: the option set (and that `agent`, `fast_mode`, and `ultracode` are
  not Pine settings) comes from the reviewed v0.109.1 adapter source. The
  adapter's `auth/status_update` pushes carry no Pine authentication evidence,
  so the report's authentication stays unknown.
- No adapter in this slice applies session-local overrides: the contextual
  "How to run" surface (inside the task surface, not a permanent settings
  pane, per #1760) therefore shows confirmed effective values where the
  adapter reports them, "uses agent settings" where the setting is
  researched/probed/supported, and "the CLI controls this" where the state is
  unknown or unsupported. Override application remains deferred.

## Lifecycle and evidence contract (#1722)

The tier decides what the shared ADE lifecycle/evidence contract can
establish for a durable task:

- Terminal-hosted (detected/attention-aware) sessions project process
  observations only. Execution state is bounded by what the process snapshot
  proves (observed activity is `working`; anything else, including terminal
  silence, is `unknown`). A terminated attempt settles as `unverified`;
  process exit, terminal silence, and an agent claim alone can never produce
  a verified result or Ready.
- Structured sessions may additionally record agent-reported
  completion claims with provider session references and source sequences.
  Even then, `success` and Ready require independent check and reviewer
  outcome facts bound to one code-state identity, so a structured claim
  without independent verification remains `unverified`.

The contract, its fencing keys, invalidation rules, and persistence schema
v3 are specified in the
[adapter core boundary](agent-adapter-core.md#lifecycle-and-evidence-contract-1722).

## Security and privacy boundary

The presentation catalog may assign a stable name and color, but it cannot
grant adapter capabilities. Structured capabilities are negotiated separately
by the adapter registry and rejected if the schema, event ordering, trust
binding, replay cursor, or declared capability set is invalid. Unknown and
lookalike processes stay generic. Fixtures contain no prompts, tokens, session
identifiers, repository paths, or terminal output.

Process termination is an observation, not proof that an agent succeeded.
Accordingly, the compatibility layer must not trigger a success notification,
resume an old conversation, or mark an attention request solely from process
timing or terminal text.

## Historical structured-interface evaluation

The following records describe earlier source/fixture evaluations, not current
protocol floors or completed integration tests. The [2026-11-14 audit](cli-capability-evidence-2026-11-14.md)
supersedes their route descriptions where upstream changed.

On August 3, 2026, Pine evaluated the five additional macOS terminal agents
named in issue #1304. Their exact executable aliases are now first-party
detected adapters. The reviewed structured interfaces remain disabled because
Pine does not yet launch and authenticate those transports. This prevents
ambient terminal JSON, local services, private databases, configuration, logs,
and desktop notifications from acquiring authority.

| Adapter | Evidence reviewed | Pine 2.0 decision | Tracking |
| --- | --- | --- | --- |
| Amp | Documented `amp` CLI and newline-delimited streaming JSON input/output | Detected; structured transport disabled | [#1316](https://github.com/batonogov/pine/issues/1316) |
| Cursor Agent | Documented `cursor-agent`, version output, opaque resume IDs, and JSON/stream-JSON print modes | Detected; explicit resume and structured print transport disabled | [#1317](https://github.com/batonogov/pine/issues/1317) |
| Goose | macOS `goose` CLI, v1.45.0, and documented ACP server support | Detected; ACP transport disabled | [#1318](https://github.com/batonogov/pine/issues/1318) |
| Qwen Code | macOS `qwen` CLI, v0.21.4, and documented JSON/stream-JSON output | Detected; structured transport disabled | [#1319](https://github.com/batonogov/pine/issues/1319) |
| Crush | macOS `crush` CLI, v0.88.0, and documented local workspace/SSE design | Detected; experimental server transport disabled | [#1320](https://github.com/batonogov/pine/issues/1320) |

On November 12, 2026, Pine recorded the documented structured interfaces of
the five agents added by [#1726](https://github.com/batonogov/pine/issues/1726).
They are reviewed future candidates only: #1726 enables detection exclusively
and grants no authority to ambient terminal JSON, hooks, local servers, logs,
or desktop notifications. Wire-level protocol fixtures and authenticated
transports are deferred to future structured-adapter work, so the sanitized
protocol-review fixture above intentionally still covers only the #1304 set.
Droid's `droid exec` output formats, raw JSON-RPC surface, and
`.factory/hooks.json` hook files were re-verified on November 12, 2026
against the complete Factory documentation corpus (docs.factory.com) and the
public [Factory-AI/droid-sdk-typescript](https://github.com/Factory-AI/droid-sdk-typescript)
examples, which register project hooks through `.factory/hooks.json`.

| Adapter | Evidence reviewed | Pine 3.0 decision | Tracking |
| --- | --- | --- | --- |
| Antigravity | Documented `agy` headless mode: `--output-format json` envelope and `stream-json` NDJSON (`init`/`step_update`/`result` events), `--input-format stream-json`, and `--conversation` resume IDs | Detected; structured transport disabled | [#1726](https://github.com/batonogov/pine/issues/1726) |
| Droid | Documented `droid exec -o json\|stream-json\|stream-jsonrpc`, raw JSON-RPC control surface, ACP, and `.factory/hooks.json` lifecycle hooks | Detected; structured transport disabled | [#1726](https://github.com/batonogov/pine/issues/1726) |
| Cline | Documented `cline --json` message output, `--acp` editor mode, and runtime hook injection (`--hooks-dir`, `cline hook`) | Detected; structured transport disabled | [#1726](https://github.com/batonogov/pine/issues/1726) |
| Grok Build | Documented headless `grok -p --output-format json\|streaming-json`, ACP embedding, and configuration hooks | Detected; structured transport disabled | [#1726](https://github.com/batonogov/pine/issues/1726) |
| Kilo Code | Documented `kilo acp` server, headless `kilo serve`, and `kilo run --auto --format json`; executables verified as `kilo` plus the npm `kilocode` alias, distinct from the OpenCode `opencode` executable despite the fork lineage | Detected; structured transport disabled | [#1726](https://github.com/batonogov/pine/issues/1726) |

The sanitized protocol fixture covers documented messages plus malformed,
reordered, replay/duplicate where applicable, oversized, and future inputs.
Every case remains process-only and therefore cannot emit waiting or successful
completion, persist an opaque provider ID, or resume a provider session.
