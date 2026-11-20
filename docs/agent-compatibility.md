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
a minimum protocol version or a certified integration version. All retained
first-party entries remain **Detected**: process snapshots with observed
process-generation trust, manual terminal launch/new sessions, and process
termination observations only. No structured transport, approval, provider
resume, account/model discovery, or verified completion is enabled by these
entries. The manual terminal can still run arbitrary programs.

The [dated capability evidence audit](cli-capability-evidence-2026-11-14.md)
separates source review, fixtures, limited version/help observations, handshake,
and end-to-end checks for every entry. It records identity, evidence dates and
platform gaps, current upstream transport candidates, and required follow-up.
The catalog's version labels are intentionally unchanged by the newer
version/help observations: OpenCode 2.3.0 help does not upgrade the existing
1.18.10 fixture into a verified V2 ACP integration.

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
| [Claude Code](https://github.com/anthropics/claude-code) | `claude` | 2.1.220 | Detected | Process snapshot; observed process generation | Manual terminal / new session only; native resume only by explicit user action as a new attempt | Process termination only | Structured transport not enabled in the app yet; the owned stream-json/control codec/model foundation is implemented with pinned floors (see below), recorded in the [2026-11-16 evidence](claude-stream-control-evidence-2026-11-16.md). |
| [OpenCode](https://github.com/anomalyco/opencode) | `opencode` | 1.18.10 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | No structured transport enabled; upstream candidates and limitations are recorded in the dated audit. |
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

## Structured transport floors (Pine-owned, first slice)

The first owned structured-adapter slice is Claude Code's
stream-json/control protocol over supervised child stdio
(#1727). Codex's owned app-server slice precedes it and Kimi/OpenCode
extend the shared contracts; this table records the exact transport and
version floors for Claude at the codec/model level. These floors are
requirements of the implemented slice, not broad compatibility claims,
and the app does not enable the transport until the registry integration
and the real-version final gate (full turns, live permission exchange)
pass.

| Item | Claude Code value |
| --- | --- |
| Transport | Owned child stdio; `-p --input-format stream-json --output-format stream-json --verbose`; JSONL frames ≤ 1 MiB |
| Pinned executable | 2.1.311 (verified handshake, 2026-11-16, unauthenticated, no model calls) |
| Structured-slice minimum | 2.1.296 (max of the required feature floors) |
| Feature floors | `capabilities` field and interrupt receipts ≥ 2.1.205; `cancel_queued` ≥ 2.1.219; `--system-prompt-snapshot off` ≥ 2.1.257; `--permission-prompts` ≥ 2.1.259; `pending_permission_requests` ≥ 2.1.268; `claude_code_version` ≥ 2.1.296 |
| Feature detection | Observed `capabilities` array first (open set; unrecognized values ignored); recorded version floors when the array is absent; missing evidence is unknown, never "absent" |
| Pending-request recovery | `pending_permission_requests` on the `initialize` response wrapper; a missing field means an older CLI, so post-reconnect approval state stays unknown rather than "no pending requests" |
| Cancellation | `interrupt` control request; receipt (`still_queued`/`cancelled`) is observation only — queued messages are never auto-resent; a late completion after cancellation is a race outcome, never Ready |
| Stop semantics | `result success` = agent-reported main-turn end only; may coexist with background work; never independently establishes verified completion or Ready |
| Resume | Native `--resume` only through explicit user action, as a new Pine attempt/source namespace; registry checkpoints are never persisted as resume data; a new process is never live reattachment |
| Limitations | No transport reconnect on owned stdio (process death ends the attempt); native user questions (`pending_user_dialog_requests`) are parsed as count-only and unmapped; `can_use_tool` wire shape implemented from the documented contract, live exchange is the final gate; hooks are reporting-only with consent/preview and project-local settings only |

## Tier meanings

- **Generic:** Pine can host the command in a terminal but makes no identity or
  lifecycle claim.
- **Detected:** Pine recognizes an exact executable alias and observes the
  process generation. Lookalike names remain generic.
- **Attention-aware:** Pine has a verified provider signal for a user-action
  transition. No first-party adapter currently claims this tier.
- **Structured:** Pine negotiates a documented, authenticated structured
  lifecycle contract. No first-party adapter currently claims this tier in
  the catalog above: the Kimi Code CLI structured adapter (#1732) below
  stays **Detected** until its real-version smoke passes on the pinned binary.

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

## Lifecycle and evidence contract (#1722)

The tier decides what the shared ADE lifecycle/evidence contract can
establish for a durable task:

- Terminal-hosted (detected/attention-aware) sessions project process
  observations only. Execution state is bounded by what the process snapshot
  proves (observed activity is `working`; anything else, including terminal
  silence, is `unknown`). A terminated attempt settles as `unverified`;
  process exit, terminal silence, and an agent claim alone can never produce
  a verified result or Ready.
- Structured sessions (future) may additionally record agent-reported
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
