# CLI agent compatibility

Pine 2.0 uses a versioned, fail-closed compatibility model. Detection means
that Pine observed a supported executable in one of its terminal process
trees. It does not mean that Pine can read a provider's private state, infer a
successful completion, or resume a provider session.

The executable release procedure, automated gate inventory, OS/renderer test
matrix, and accessibility checklist live in the
[Pine 2.0 agent release matrix](pine-2.0-agent-release-matrix.md).

The checked-in catalog schema is version 1. The versions below were verified
against sanitized command-shape fixtures; Pi, Codex, and OpenCode were also
checked against locally installed binaries on August 3, 2026, and Kimi Code
2.1.1 was checked against a locally installed binary on September 28, 2026.
Empry⊙ 3.12.2-beta was checked locally with `empryo --version` and `empryo --help`; command shapes are covered by synthetic fixtures.
Antigravity 1.5.6, Droid 1.9.0, Cline 3.0.74, Grok Build 1.0.77, and Kilo
Code 7.8.27 were verified on November 12, 2026 against documented release
sources (the official Antigravity CLI release manifest, npm registry
metadata for `droid`, `cline`, and `@kilocode/cli` — cross-checked with the
Kilo GitHub release, and the Grok Build changelog). None of those five
executables was installed on the verification host, so their entries are
release-source-verified and fixture-tested, not binary-verified.
Links point to the upstream projects used to verify the remaining current
releases.

| Agent | Executable aliases | Verified version | Tier | Event source and trust | Launch / resume | Notification accuracy | Current limitation |
| --- | --- | --- | --- | --- | --- | --- | --- |
| [Pi](https://github.com/badlogic/pi-mono) | `pi` | 0.83.0 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | No documented structured event channel is enabled. |
| [Codex](https://github.com/openai/codex) | `codex` | 0.146.0 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | No documented structured event channel is enabled. |
| [Claude Code](https://github.com/anthropics/claude-code) | `claude` | 2.1.220 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | No documented structured event channel is enabled. |
| [OpenCode](https://github.com/anomalyco/opencode) | `opencode` | 1.18.10 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | No documented structured event channel is enabled. |
| [GitHub Copilot CLI](https://github.com/github/copilot-cli) | `github-copilot-cli`, `copilot` | 1.0.77 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | No documented structured event channel is enabled. |
| [Aider](https://github.com/Aider-AI/aider) | `aider` | 0.86.0 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | No documented structured event channel is enabled. |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli) | `gemini` | 0.53.1 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | No documented structured event channel is enabled. |
| [Amp](https://ampcode.com/manual) | `amp` | 0.0.1785747753-g51f676 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | Streaming JSON was reviewed but is disabled until Pine can authenticate and bind the launch transport. |
| [Cursor Agent](https://docs.cursor.com/en/cli/overview) | `cursor-agent` | 2026.07.23-e383d2b | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | JSON is limited to Pine-launched print mode; interactive sessions stay detected-only and `--force` is never enabled. |
| [Goose](https://github.com/aaif-goose/goose) | `goose` | 1.45.0 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | ACP was reviewed but is disabled until Pine provides authenticated, bounded stdio negotiation. |
| [Qwen Code](https://github.com/QwenLM/qwen-code) | `qwen` | 0.21.4 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | Machine-readable output was reviewed but is not trusted from an ambient terminal. |
| [Crush](https://github.com/charmbracelet/crush) | `crush` | 0.88.0 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | Workspace/SSE is experimental and not enabled without a registry-minted authenticated connection. |
| [Kimi Code](https://www.kimi.com/code/docs/en/) | `kimi`, `kimi-code` | 2.1.1 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | No documented structured event channel is enabled. The CLI rewrites its process title to `kimi-code`, so both aliases are required for detection. |
| [Empry⊙](https://empryo.com/) | `empryo` | 3.12.2-beta | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | Headless `--events` is not enabled as a trusted lifecycle transport. |
| [Antigravity](https://antigravity.google/docs/cli/headless) | `agy` | 1.5.6 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | Headless `--output-format json\|stream-json` events were reviewed but are disabled until Pine launches and authenticates the transport. |
| [Droid](https://docs.factory.com/droid-cli/cli-reference) | `droid` | 1.9.0 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | `droid exec` JSON/stream/JSON-RPC output and ACP were reviewed but are disabled until Pine launches and authenticates the transport. |
| [Cline](https://github.com/cline/cline) | `cline` | 3.0.74 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | `--json` output, `--acp` mode, and lifecycle hooks were reviewed but are disabled until Pine launches and authenticates the transport. |
| [Grok Build](https://github.com/xai-org/grok-build) | `grok` | 1.0.77 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | Headless `--output-format json\|streaming-json` and ACP were reviewed but are disabled until Pine launches and authenticates the transport. |
| [Kilo Code](https://github.com/Kilo-Org/kilocode) | `kilo`, `kilocode` | 7.8.27 | Detected | Process snapshot; observed process generation | Manual terminal / new session only | Process termination only | `kilo acp`, `kilo serve`, and `kilo run --format json` were reviewed but are disabled. Its OpenCode fork lineage does not grant `opencode` alias or schema compatibility; only the exact `kilo`/`kilocode` executables are detected. |

## Tier meanings

- **Generic:** Pine can host the command in a terminal but makes no identity or
  lifecycle claim.
- **Detected:** Pine recognizes an exact executable alias and observes the
  process generation. Lookalike names remain generic.
- **Attention-aware:** Pine has a verified provider signal for a user-action
  transition. No first-party adapter currently claims this tier.
- **Structured:** Pine negotiates a documented, authenticated structured
  lifecycle contract. No first-party adapter currently claims this tier.

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

## Structured-interface evaluation

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
