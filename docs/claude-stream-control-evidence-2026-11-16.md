# Claude Code owned stream-json/control evidence — 2026-11-16

Scope: [#1727](https://github.com/batonogov/pine/issues/1727) CLI capability
audit additions for the fourth structured ADE adapter. This record is dated
evidence, not a compatibility claim: it separates what was exercised against
the installed executable from what remains the final real-version gate.

## Pinned executable and environment

- Executable: `/opt/homebrew/bin/claude`, `2.1.311 (Claude Code)`, macOS,
  observed 2026-11-16. The pinned executable floor for the first owned
  stream-json/control slice is recorded as **2.1.311**; versions above the
  pin are not verified and are not claimed.
- `claude auth status` (JSON, read-only): `loggedIn: false`,
  `authMethod: "none"`, `apiProvider: "firstParty"`, `configDirectory`
  present (field requires ≥ 2.1.268), exit 1. Provider account
  authentication is checked separately from owned-pipe transport
  authentication and is not exercised here.
- Native authentication and configuration are preserved deliberately. Pine
  does not pass `--bare` (see below) and does not modify global or project
  Claude settings.

## Exercised: owned stream-json/control handshake

Bounded handshake probe, no model calls: launched
`claude -p --input-format stream-json --output-format stream-json --verbose
--no-session-persistence` in a scratch directory, sent one `initialize`
control request as the first stdin line, closed stdin after the response.
Observed on 2.1.311:

- Envelope:
  `{"type":"control_response","response":{"subtype":"success",
  "request_id":"<uuid>","response":{...},
  "pending_permission_requests":[],
  "pending_user_dialog_requests":[]}}`.
- `pending_permission_requests` is present on the response wrapper (empty
  with no live session work), confirming the documented **2.1.268 floor**
  for reliable pending-request enumeration. Per the protocol docs, a missing
  field on older CLIs means an older CLI, never "no pending requests": the
  codec keeps post-reconnect approval state **unknown** in that case.
- Initialize payload carried `claude_code_version: "2.1.311"` (floor 2.1.296),
  `account: {"tokenSource":"none","apiProvider":"firstParty"}`,
  `current_permission_mode: "default"`, `output_style`, `models`, and the
  open `capabilities` array.
- The observed `capabilities` array was
  `["ui_surface_v1","mcp_call_result_not_for_model_v1"]` on this
  unauthenticated handshake; `interrupt_receipt_v1` and
  `interrupt_cancel_queued_v1` were not advertised in that observation.
  Feature detection therefore prefers the observed array when present and
  falls back to the recorded version floors (`interrupt_receipt_v1` ≥
  2.1.205, `interrupt_cancel_queued_v1` ≥ 2.1.219) when absent; missing
  evidence stays unknown, never unavailable.

`--help` listing flags is not control-protocol compatibility evidence; the
handshake above is the first owned-protocol observation recorded for this
entry.

## Permission host, questions, denial, cancellation

- Permission host: print-mode permission prompts route to the host via the
  default `--permission-prompts host` (floor 2.1.259) or
  `--permission-prompt-tool`. Pine's owned session is the host:
  `can_use_tool` control requests surface as shared
  waiting-for-approval state and are answered one-shot (allow as-is or deny
  with fixed Pine text; no `updated_input` is generated in this slice).
- Native user questions: the initialize wrapper also carries
  `pending_user_dialog_requests`. This slice parses the field as a bounded
  array and retains the count only; the entry shape is not exercised, so no
  question state is mapped. This is a documented capability difference in
  the shared contract suite, not a silent skip.
- Denial: one-shot deny responses use fixed Pine text; provider error text is
  never echoed.
- Cancellation: `interrupt` control request; the receipt
  (`still_queued`, `cancelled`) is observation only. Queued messages are
  never automatically resent. `cancel_queued` is sent only when the
  capability is available (floor 2.1.219). Cancellation stays requested
  until the receipt confirms it; a result after a requested-but-unconfirmed
  cancellation is a race outcome, never success.
- Pending-request recovery: redelivered permission requests (entries of
  `pending_permission_requests`, or standalone redelivery) receive the
  previous valid response from the connection's bounded remembered set; a
  redelivered request never prompts the user twice.

## Settings, trust, and resume semantics

- **`--bare` is not an innocuous integration flag.** Installed help
  documents that bare mode skips hooks, LSP, plugin sync, attribution,
  auto-memory, background prefetches, keychain reads, and CLAUDE.md
  auto-discovery, and that Anthropic auth is strictly `ANTHROPIC_API_KEY`
  or `apiKeyHelper` — OAuth and keychain are never read. Pine's owned
  sessions therefore do not pass `--bare`; they preserve native
  authentication and configuration.
- **`--safe-mode` differs**: it disables customizations (CLAUDE.md, skills,
  plugins, hooks, MCP, output styles, …) while authentication, model
  selection, built-in tools, and permissions work normally; managed policy
  settings still apply. Not used by the owned slice; recorded so the two
  flags are not conflated.
- **Noninteractive trust-dialog bypass and ignored invalid settings**: with
  `-p` (or piped stdout) the workspace trust dialog is skipped and settings
  files that fail validation are silently ignored. Pine's existing workspace
  authorization therefore applies **before launch** (launch policy's
  responsibility, #1725/#1728); successful startup is not treated as proof
  that requested settings loaded. The only effective-settings evidence
  surface retained from the wire is the allowlisted `system/init`
  (`model`, `current_permission_mode`, `claude_code_version`,
  `capabilities`, `account`).
- **Persisted system-prompt snapshots on resume**: by default the system
  prompt is recorded on the conversation's first request and reused on
  `--resume`/`--continue` until compaction. Changed launch instructions or
  settings are therefore **not claimed effective on a resumed session**;
  `--system-prompt-snapshot off` (floor 2.1.257) is the opt-out if a future
  slice needs per-request rebuilds. Explicit fresh-session recovery remains
  #1756/#1759.
- **Native resume** is used only through explicit user action and only as a
  new Pine attempt/source namespace. Pine registry checkpoints are never
  persisted as Claude resume data, and a new process is never presented as
  live reattachment.
- **Stop with remaining background work**: a `result success` frame is
  agent-reported main-turn end (Stop) only. A `-p` run can wait for
  background work after the turn (with its own idle ceiling), so Stop may
  coexist with background work; it never independently establishes verified
  completion or Ready.

## Retention and redaction

- The wire codec retains allowlisted metadata only: session IDs, opaque
  UUIDs, tool-call identities and names, result subtypes, bounded
  capability strings, and a two-field account observation. Prompts,
  `tool_input`, assistant text, tool results, `cwd`, transcripts,
  environment values, and cost figures are dropped at the boundary. The one
  retained exception is the `control_response` error string: in-memory
  only, bounded at 256 bytes, used as a diagnostic category, and the owner
  must not persist, spool, or log it. Fixture and unit tests assert
  non-retention of marker content.
- Stderr of the owned child can contain secrets and is drained without
  retention (transport layer, shared with the owned-child supervision work).

## Explicit seams (separately owned)

- Reviewer permissions for structured sessions are bound separately under
  [#1755](https://github.com/batonogov/pine/issues/1755) (seam only).
- Inherited environment and billing provenance are owned by
  [#1765](https://github.com/batonogov/pine/issues/1765) (seam only); the
  `result` frame's cost fields are deliberately not retained.
- The TypeScript Agent SDK is not introduced; the owned transport is the
  pinned CLI over stdio. Choosing the SDK would require a separate runtime,
  packaging, dependency, and teardown design.
- User-launched terminal hooks are reporting-only: allowlisted bounded
  metadata, explicit consent plus preview before installation, project-local
  `settings.local.json` only (global settings are never modified), delivery
  bound to the exact launch/session identity, and nested, foreign, stale, or
  unauthenticated events rejected. Spooled/replayed reports are historical
  and cannot create current blocked, idle, or Ready state. A session ID or
  hook token visible to the agent is not independent proof against that
  agent (same-user/agent spoofing threat model). Process exit is an
  observation, not successful completion.

## Final gate (not performed here)

Full-turn real-version flows — live permission exchange, live interrupt
receipt with queued input, background-work coexistence at Stop, and
authenticated account states — require paid model generation and an
authenticated account. They are recorded as the final gate for #1727. The
`can_use_tool` wire shape is implemented from the documented
CanUseTool/PermissionResult contract and was not observed live.
