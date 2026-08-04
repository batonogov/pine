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

## Pre-freeze candidate evaluation

On August 3, 2026, Pine also evaluated the five actively maintained macOS
terminal agents named in issue #1304. A candidate qualifies for a separate
adapter review when it has a documented macOS CLI, a stable executable name,
current first-party documentation or releases, and a credible integration path
that does not require scraping ANSI presentation. Qualification does not grant
support in Pine 2.0; each adapter must pass the same offline fixtures,
provenance, fail-closed, privacy, and compatibility gates as the initial seven.

| Candidate | Evidence reviewed | Evaluation | Follow-up |
| --- | --- | --- | --- |
| Amp | Documented `amp` CLI and newline-delimited streaming JSON input/output | Qualifies; assess structured tier, keep detected fallback | [#1316](https://github.com/batonogov/pine/issues/1316) |
| Cursor Agent | Documented `cursor-agent`, version output, opaque resume IDs, and JSON/stream-JSON print modes | Qualifies; structured print mode only, interactive mode detected unless documented | [#1317](https://github.com/batonogov/pine/issues/1317) |
| Goose | macOS `goose` CLI, active v1.45.0 release, and documented ACP server support | Qualifies; prefer standards-based ACP negotiation | [#1318](https://github.com/batonogov/pine/issues/1318) |
| Qwen Code | macOS `qwen` CLI and active v0.21.4 release | Qualifies for detected tier; no TUI/slash-command scraping | [#1319](https://github.com/batonogov/pine/issues/1319) |
| Crush | macOS `crush` CLI, active v0.88.0 release, and documented local workspace/SSE design | Qualifies for protocol review; experimental or unauthenticated paths remain detected | [#1320](https://github.com/batonogov/pine/issues/1320) |

The review used the candidates' official manuals or repositories linked in
their follow-up issues. They remain outside the initial Pine 2.0 compatibility
set so the first-party matrix can be reviewed and shipped without silently
expanding its trust surface.
