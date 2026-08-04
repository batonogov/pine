# CLI agent compatibility

Pine 2.0 uses a versioned, fail-closed compatibility model. Detection means
that Pine observed a supported executable in one of its terminal process
trees. It does not mean that Pine can read a provider's private state, infer a
successful completion, or resume a provider session.

The executable release procedure, automated gate inventory, OS/renderer test
matrix, and accessibility checklist live in the
[Pine 2.0 agent release matrix](pine-2.0-agent-release-matrix.md).

The checked-in catalog schema is version 1. The versions below were verified
on August 3, 2026 against sanitized command-shape fixtures; Pi, Codex, and
OpenCode were also checked against locally installed binaries. Links point to
the upstream projects used to verify the remaining current releases.

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

## Tier meanings

- **Generic:** Pine can host the command in a terminal but makes no identity or
  lifecycle claim.
- **Detected:** Pine recognizes an exact executable alias and observes the
  process generation. Lookalike names remain generic.
- **Attention-aware:** Pine has a verified provider signal for a user-action
  transition. No first-party adapter currently claims this tier.
- **Structured:** Pine negotiates a documented, authenticated structured
  lifecycle contract. No first-party adapter currently claims this tier.

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

The sanitized protocol fixture covers documented messages plus malformed,
reordered, replay/duplicate where applicable, oversized, and future inputs.
Every case remains process-only and therefore cannot emit waiting or successful
completion, persist an opaque provider ID, or resume a provider session.
