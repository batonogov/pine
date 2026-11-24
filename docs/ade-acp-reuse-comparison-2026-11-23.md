# ACP reuse comparison and dual-stack decision record — 2026-11-23

Scope: research slice of
[#1846](https://github.com/batonogov/pine/issues/1846), part of the
[#1729](https://github.com/batonogov/pine/issues/1729) epic and milestone
**Pine 3.0 — ADE**. It inventories Pine's current ACP wire, compares the
maintained reusable ACP components, and records the chosen route per
integration plane. The 2026-11-23 record itself is documentation only: no
Swift code, no dependency or runtime additions, no `.help` changes. Section 7
adds the dated probe-outcome evidence from the #1846 code slice. Companion evidence:
[CLI capability evidence](cli-capability-evidence-2026-11-14.md),
[Claude stream/control evidence](claude-stream-control-evidence-2026-11-16.md),
[T3 integration research](t3-code-agent-integration-2026-11-15.md), and the
[adapter core boundary](agent-adapter-core.md).

## Evidence meanings and limits

- **Repo-read (2026-11-23, base `321b780455977f1cef403a26b0ad3e4f10aa62a7`):**
  the file and ownership statements in section 1 were read from this
  checkout. They are not compile, test, or runtime evidence.
- **Fetched (2026-11-23):** upstream sources read over the web on this date;
  exact revision, tag, and release date are recorded per item. Mutable
  upstream documents, not immutable attestations.
- **Initial audit (2026-11-22, #1846 issue comment):** a source/documentation
  audit recorded in the issue. Claims carried from it are marked as such and
  were not re-verified in this pass.
- **Assumption / hypothesis:** explicitly labeled; none is treated as a
  verified fact.
- No Swift package compilation, no live provider session, and no ACP v2
  handshake were performed for this record.

## 1. Current ACP/agent wire in Pine

### 1.1 Shared owned-stdio JSON-RPC foundation (Codex-named)

| File | What it owns |
| --- | --- |
| `Pine/Agent/Adapters/CodexAppServerWire.swift` | The shared JSON-RPC 2.0 envelope (`CodexAppServerMessage`: request/notification/response/failure), the shared correlation ID type (`CodexAppServerRequestID`: integer or exact-UTF-8 string, control-character-rejecting), and `CodexAppServerFramer` — incremental bounded JSONL ingress (1 MiB frame cap, depth cap, one-delivery, any failure fences the channel). The framer's `requireJSONRPCVersion` flag is the channel seam that makes `jsonrpc: "2.0"` mandatory for ACP connections; it stays optional only for legacy Codex app-server traffic. |
| `Pine/Agent/Adapters/CodexAppServerStdioChannel.swift` | The supervised child pipes: non-blocking descriptors, one-message backpressure per direction, bounded framing, secret-free stderr draining (retain none), and one negative-only close observer that revokes owner authority. |
| `Pine/Agent/Adapters/CodexAppServerConnection.swift` | Connection-local bookkeeping for the Codex app-server protocol: phase machine, bounded pending/server-request tables, one-shot answers, byte-exact replay memory. The Kimi and OpenCode ACP connections follow the same correlation and replay discipline in separate implementations (section 1.2/1.3). |
| `Pine/Agent/Adapters/CodexAppServer*.swift` (Client, NativeBridge, TaskMapper, Wire, ApprovalPolicy, AccountState, …) | The Codex **app-server** protocol surface (merged under #1723). Not ACP; listed so the shared framer's original owner is unambiguous. |

### 1.2 Kimi ACP client (merged under #1732)

| File | What it owns |
| --- | --- |
| `Pine/Agent/Adapters/KimiACPWire.swift` | ACP v1 envelope discipline (every egress frame re-serialized with mandatory `jsonrpc: "2.0"`), `initialize` result validation (`protocolVersion` 1, agent name and version **exact** pin `2.6.2`), capability parsing (loadSession, image, embeddedContext, resume, fork, additionalDirectories, audio), `authMethods` observation (count only; no credential retention), bounded `configOptions` parsing. |
| `Pine/Agent/Adapters/KimiACPConnection.swift` | Connection-local ACP state machine: phase (fresh/initializing/ready/closed), integer request-ID allocation, bounded pending and server-request tables, remembered-answer replay (byte-for-byte on redelivery), and `methodNotFound` rejection of every reverse-RPC Pine does not own (fs/*, terminal/*, terminal-auth). |
| `Pine/Agent/Adapters/KimiACPTransport.swift` | The transport seam over the shared channel; launches nothing. Its `requireJSONRPCVersion` strictness tightens once the ACP channel seam is linearized (see the file's own note). |
| `Pine/Agent/Adapters/KimiACPSession.swift` | The session actor: one child per action (`new`, `load`, `resume`, `fork` — none reattaches to an old process), bootstrap with bounded history replay, prompt submission (text/image/resource with joint byte caps), cancellation, one-shot permission/elicitation answers with fences, and the fail-closed state machine whose `unverified`/`unknown` outcomes feed the ADE contract. |
| `Pine/Agent/Adapters/KimiACPAccountGate.swift` | Separate terminal-auth observation (managed account vs external provider), generation-fenced digest of the auth-flow outcome; transport ownership never proves account authentication. |
| `Pine/Agent/Adapters/KimiACPExecutableIdentity.swift` | Pinned executable identity: native image or Node-shebang entry plus the interpreter stamp; version probe against the exact pin. |
| `Pine/Agent/Adapters/KimiACPFactory.swift` | Probe/admission gating and the exact-CLI-version pin with the capability-to-version floor table. |
| `Pine/Agent/Adapters/KimiACPTaskMapper.swift` | Ephemeral mapping of one Kimi connection into the shared adapter contract: prompt-active tracking, attention events, request resolution. |
| `Pine/Agent/Adapters/KimiACPForm.swift` | Strict subset of ACP form-mode `requestedSchema`; unknown constraints block the turn, never discarded. URL mode rejected on receipt. |

Tests and fixtures: `PineTests/KimiACP*Tests.swift` and
`PineTests/Fixtures/AgentAdapters/kimi-acp-v1.json` (synthetic ACP envelopes,
redacted).

### 1.3 OpenCode ACP composition (merged under #1843 for #1811)

| File | What it owns |
| --- | --- |
| `Pine/Agent/Adapters/OpenCodeACPSession.swift` | The session actor, **ACP v1 only**: `initialize` with `protocolVersion` 1, `clientCapabilities.elicitation.form` and the pinned `_meta["opencode/child-session-updates"]` extension; agentInfo exact pin `OpenCode 2.3.2`; `session/new` and `session/load` (exact-ID explicit action, replay bounded, historical-not-live); child-session updates (`opencode/session/child_update` with parent/depth validation, turn-scoped tool attribution); `session/prompt`, `session/cancel`, one-shot permissions (`allow_once`/`reject_once`), form elicitation, uncertain-delivery fencing, and the explicit `unverified`/`unknown` settlement (no `succeeded`/`Ready` from ACP completion). |
| `Pine/Agent/Adapters/OpenCodeACPNativeBridge.swift` | Registry-owned launch materials, the literal-argv spawner, durable native ownership transitions (submission/cancellation/acknowledgement/response-observed/submission-unknown), the one-shot `OpenCodeACPNativeFactory`, and `OpenCodeACPNativeComposition` (runtime retention per task). |
| `Pine/Agent/Adapters/OpenCodeACPLaunch.swift` | `OpenCodeACPExecutableIdentity` (SHA-256 plus stat stamp, process-image revalidation, `opencode --version` probe against the exact pin), `OpenCodeACPOwnedChild` (channel plus process-group stop/reap, stderr drain owned by the session lifetime), and the fixture-only launch path, which builds the shared channel with `requireJSONRPCVersion: true`. |
| `Pine/Agent/Adapters/OpenCodeACPTransport.swift` | The transport seam; refuses any channel that does not require `jsonrpc: "2.0"`. Also `OpenCodeACPWire.encode` (mandatory `jsonrpc: "2.0"` re-serialization) and the shared validation helpers (bounded strings, session-ID charset). |
| `Pine/Agent/Adapters/OpenCodeACPTaskRuntime.swift` | `@Observable` projection/control handle for one durable task attempt; UI never talks to the session actor directly. |
| `Pine/Agent/Adapters/OpenCodeACPForm.swift` | Strict subset of OpenCode's documented question schema; unknown constraints block the turn. |
| `Pine/Agent/Adapters/OpenCodeACPFactory.swift` | Admission/probe gating; nil observation keeps the adapter unavailable until an authorized pinned observation exists. |

Tests and fixtures: `PineTests/OpenCodeACP*Tests.swift` and
`PineTests/Fixtures/AgentAdapters/acp-opencode-v2.3.2-turn.jsonl` /
`-faults.jsonl` (synthetic). The shared wire contract itself is exercised by
`PineTests/ACPSharedWireContractTests.swift` (exact-UTF-8 string request IDs
and independent connection caches across the shared Codex/Kimi/OpenCode
types).

### 1.4 Genuine sharing vs provider-specific behavior

Already shared: the framer, the stdio channel, the request-ID type, the
message envelope, the one-shot-response replay discipline, the fail-closed
capability-validation pattern, and the exact-pin executable-identity pattern.
Provider-specific and intentionally not shared: each adapter's `initialize`
parameter pin (Kimi 2.6.2 vs OpenCode 2.3.2), the session-action surface
(Kimi `new`/`load`/`resume`/`fork` vs OpenCode `new`/`load`), permission and
elicitation mapping, the OpenCode child-session `_meta` extension, and the
Kimi account gate. The concrete duplication a consolidation could remove
later: the repeated mandatory-`jsonrpc` encode plus bounded-string/session-ID
validation helpers in `KimiACPWire` and `OpenCodeACPWire`, the correlation
state machine (factored in `KimiACPConnection`, inlined in
`OpenCodeACPSession`, and present separately in `CodexAppServerConnection`),
and the Codex-prefixed names on the shared types. The
issue explicitly does not require a rewrite of a working adapter for naming
consistency.

## 2. Maintained reusable ACP components

All items below fetched 2026-11-23 unless marked otherwise. "unverified — not
fetched" means the source could not be fetched or verified in this pass.

### 2.1 Official ACP spec, schemas, and compatibility kit

| Item | Exact revision / date | License | Role | ACP versions | Runtime requirements | Capability gaps / notes |
| --- | --- | --- | --- | --- | --- | --- |
| [agentclientprotocol/agent-client-protocol](https://github.com/agentclientprotocol/agent-client-protocol) (the issue text cites the former `zed-industries/agent-client-protocol` home; GitHub redirects there — fetched) | stable schema [`schema-v1.34.1`](https://github.com/agentclientprotocol/agent-client-protocol/releases/tag/schema-v1.34.1) (2026-11-21, `17747b9`); Preview schema [`schema-v2.0.0-beta.3`](https://github.com/agentclientprotocol/agent-client-protocol/releases/tag/schema-v2.0.0-beta.3) (2026-11-21, `94824f1`) | Apache-2.0 (contribution policy, fetched) | Reference artifact (schemas + Rust schema/data-model crate); neither client nor agent | v1 stable; v2 Preview | none (data artifacts; versioned `.json` attached to `schema-v*` releases) | v2 is not frozen; remote transports and prompt steering/queueing are not in the Preview; consumers must not infer wire compatibility from schema release version alone — the negotiated `protocolVersion` decides |
| [agentclientprotocol/acp-tck](https://github.com/agentclientprotocol/acp-tck) (Test Compatibility Kit) | unverified — not fetched (existence and experimental status verified via the official [Testing page](https://agentclientprotocol.com/libraries/testing.md), fetched) | unverified — not fetched | Test harness (drives an agent as a stdio subprocess) | has an opt-in v2 suite per the official page | unverified — not fetched | Experimental; "a passing run is not an official statement of ACP conformance"; coverage, options, and report format may change |
| Official SDKs | [Rust](https://crates.io/crates/agent-client-protocol), [TypeScript](https://github.com/agentclientprotocol/typescript-sdk), [Kotlin](https://github.com/agentclientprotocol/kotlin-sdk), [Java](https://github.com/agentclientprotocol/java-sdk), [Python](https://github.com/agentclientprotocol/python-sdk) (official list fetched from the ACP README; Rust and TypeScript reached 1.0 per the official announcement, fetched) | unverified — per-repo, not fetched | Client and agent runtimes | v1; v2 APIs in Rust (unstable feature), TypeScript (experimental namespace), Kotlin and Python (fetched: in progress toward latest schema) | language runtimes | **No official Swift SDK** — verified against both the official library list and the [community libraries page](https://agentclientprotocol.com/libraries/community.md), fetched |

### 2.2 Swift ACP client libraries (the three the community page lists, fetched)

| Library | Exact revision / date | License | Role | ACP versions | Runtime requirements | Capability gaps / notes |
| --- | --- | --- | --- | --- | --- | --- |
| [aptove/swift-sdk](https://github.com/aptove/swift-sdk) | [v0.2.3](https://github.com/aptove/swift-sdk/releases/tag/v0.2.3) (released 2026-11-01, tag commit `f4eaa34`; fetched) | Apache-2.0 (README, fetched) | Client **and** agent | v1 high-level `Agent`/`Client` connections; v2 via the lower-level `ACPProtocol` directly, with a protocol-negotiation sample (tries v2, falls back to v1) | Swift 6.0+, macOS 12+/iOS 15+/tvOS/watchOS, Xcode 16+, SPM (README, fetched) | Pre-1.0. v2 has no high-level wrappers yet (README, fetched). Session `resume`/`fork`/`load` marked unstable (README, fetched). Current-schema v2 parity unproven (initial audit 2026-11-22; not re-verified here). Swift port of the official Kotlin SDK v0.33.0 (README, fetched); Aptove iOS cited as a production integration (README, fetched). Initial audit reports dependencies limited to `swift-log` and `swift-collections` (not re-verified here) |
| [wiedymi/swift-acp](https://github.com/wiedymi/swift-acp) | [v0.1.0](https://github.com/wiedymi/swift-acp/releases/tag/v0.1.0) (tag fetched; release date shown in the initial audit as 2026-07-04, not displayed on the fetched tag page) | MIT (README, fetched) | Client **and** agent | v1 only; v0.1.0 release notes explicitly defer "full protocol v2 namespace" as draft-only (fetched) | Swift 5.9+, macOS 12+/iOS 15+; process spawning (stdio) macOS-only (README, fetched) | Single release; built for Aizen (README, fetched); the initial audit notes the README install snippet `from: "1.0.0"` does not match available tags (not re-verified here) |
| [rebornix/acp-swift-sdk](https://github.com/rebornix/acp-swift-sdk) | unverified — not fetched (no release tag date in this pass; initial audit reports no matching release tags) | MIT (README, fetched) | Client-side method surface (README lists client→agent methods only; the initial audit reports authentication, permission, filesystem, and terminal callbacks unimplemented — not re-verified here) | v1; draft-RFD methods flagged "API may change" (README, fetched) | Swift 6.0+, macOS 13+/iOS 16+/watchOS 9+/tvOS 16+/visionOS 1+ (README, fetched) | No documented agent→client permission/filesystem/terminal handling in the README — not a drop-in for Pine's one-shot approval flow |

### 2.3 Official adapters (agent role)

| Adapter | Exact revision / date | License | Role | ACP versions | Runtime requirements | Capability gaps / notes |
| --- | --- | --- | --- | --- | --- | --- |
| [claude-agent-acp](https://github.com/agentclientprotocol/claude-agent-acp) | [v0.109.1](https://github.com/agentclientprotocol/claude-agent-acp/releases/tag/v0.109.1) (released 2026-11-21; changelog fetched) | Apache-2.0 (contribution policy, fetched) | Agent (wraps the Claude Agent SDK) | v1 and v2 Preview per connection: a client asking for protocol ≥ 2 in `initialize` gets v2, every other client gets v1; `CLAUDE_AGENT_ACP_PROTOCOL` pins `v1`/`v2`/`auto` (README, fetched) | Standalone release archives for macOS x64/arm64 (plus Linux, Windows) holding `claude-agent-acp` and the `claude` CLI it runs; **no Node.js install required** (README, fetched); `CLAUDE_CODE_EXECUTABLE` to substitute a local CLI | v2 is not frozen; on v2 the adapter serves the session baseline including `session/resume` replay ended by `replay_complete`, `session/prompt` with `idempotencyKey` (retry returns the original `messageId`; the key is retained as long as Claude Code stores the message, also after a restart), subagents, plans, notices, compaction; steering is v1-only for now; v2 stdio MCP `command` must be absolute (README, fetched) |
| [codex-acp](https://github.com/agentclientprotocol/codex-acp) | [v2.9.0](https://github.com/agentclientprotocol/codex-acp/releases/tag/v2.9.0) (released 2026-11-21; changelog fetched: Codex 0.171.0, ACP SDK 2.9.1, `auth/status` on v1 and v2) | Apache-2.0 (license note, fetched) | Agent (stdio ACP server; starts the Codex App Server and translates) | v1 and v2 (v2: `background` list, subagent sessions; v1 clients opt in with `clientCapabilities.subagents`) (README, fetched) | npm route (`npx @agentclientprotocol/codex-acp` or global install; bundles `@openai/codex`); `CODEX_PATH` to run a different Codex binary (README, fetched). Standalone binaries exist only via the dev bundle script (`npm run bundle:all`); the initial audit inspected the release and found no standalone binary assets (not re-verified here) | v2 Preview not frozen; ACP auth methods (ChatGPT login, API key, custom gateway) with `auth/status` query (README, fetched) |

### 2.4 Competitor integrations (behavioral references, fetched)

- **Zed** — client; ACP origin and home of the ACP lead maintainer (v2 Preview announcement, fetched). External agents run as separate processes over ACP with per-agent `agent_servers` configuration (`command`/`args`/`env`), ACP Registry install, MCP forwarding, and ACP log inspection ([external agents docs](https://zed.dev/docs/ai/external-agents), fetched). Registry launched 2026-01-28 ([Zed blog](https://zed.dev/blog/acp-registry), fetched). The Zed repository carries a GPL-3.0 license file (`LICENSE-GPL`, existence fetched); the initial audit classifies its `agent_servers`/`acp_thread` client stack as GPL-3.0-or-later and coupled to GPUI/Zed application state (not re-verified here). The official Rust crates `agent-client-protocol` (runtime) and `agent-client-protocol-schema` (data model) are published to crates.io (ACP README, fetched). Embedding any Zed Rust stack would add Rust/Tokio/FFI to a native macOS app and is not a Pine dependency route.
- **JetBrains** — client (AI Assistant, IDE 2025.3+); closed source. ACP agents install from the registry or are configured manually via `~/.jetbrains/acp.json` (`agent_servers` with `command`/`args`/`env`); the IDE downloads agent files and a Node.js or Python runtime when required; MCP settings (custom and the IntelliJ MCP server) are exposed to agents; ACP logs collectible; WSL unsupported ([ACP docs](https://www.jetbrains.com/help/ai-assistant/acp.html), fetched). [JetBrains blog 2026-08-12](https://blog.jetbrains.com/idea/2026/08/how-to-use-ai-agents-in-intellij-idea-with-acp/), fetched: ACP "originated from a collaboration between JetBrains and Zed"; local agents are subprocesses over JSON-RPC stdio with version and capability negotiation at initialization. Behavioral reference only — no source to reuse.
- **T3 (pingdotgg/t3code)** — client. MIT license (LICENSE fetched, © 2026 T3 Tools Inc.). The shared ACP adapter lives in its own package `packages/provider-acp` (package-extraction PR merged 2026-10-09, [PR #17354](https://github.com/pingdotgg/t3code/pull/17354), fetched): an `AcpAdapterV2` translating orchestration turns, elicitation, tool-call state merging, and subagent tracking over a Node/Effect runtime with a child-process spawner, coupled to T3's application bridges (fetched). Reuse its permission/cancellation/recovery/provider-difference **scenarios and test shapes**, not its runtime (initial audit 2026-11-22; consistent with the fetched source layout).
- **ACP Registry** (launched 2026-01-28, Zed + JetBrains, fetched) — the distribution layer for ACP agents. Out of scope for Pine per #1846 (no marketplace/registry UI in 3.0).

## 3. Decision record (per integration plane)

Route vocabulary: **direct dependency adoption** | **external official adapter
process reuse** | **shared Pine-owned ACP primitives** | **native fallback**.

| Plane | Chosen route | Rationale (one line) | Evidence pointer |
| --- | --- | --- | --- |
| Framing / transport | **Shared Pine-owned ACP primitives** (retain `CodexAppServerFramer`/`CodexAppServerStdioChannel`; ACP strictness through the existing `requireJSONRPCVersion` seam; v2 wire strictness — no batches, non-null string/integer IDs, required error codes — is expressible on the same envelope) | The merged OpenCode adapter runs on this channel in production with fail-closed bounds, and the merged Kimi adapter exercises the same channel through its test-owned transport (production launch not yet wired); an external SDK transport would add a pre-1.0 runtime surface with no demonstrated benefit. | Section 1.1; [aptove v0.2.3](https://github.com/aptove/swift-sdk/releases/tag/v0.2.3); v2 Preview announcement (fetched) |
| Request correlation | **Shared Pine-owned ACP primitives** (`CodexAppServerRequestID` + the one-shot/replay discipline already shared by Codex, Kimi, and OpenCode) | Exact-UTF-8 string/integer IDs match both ACP v1 and the stricter v2 rule, and the shared wire contract is already test-owned. | `PineTests/ACPSharedWireContractTests.swift`; v2 Preview announcement (fetched) |
| Session lifecycle | **Shared Pine-owned primitives for the generic parts; provider adapters keep their action surfaces and state machines** | Pine binds session identity to durable task ownership (attempt/source namespace, no reattachment, explicit recovery); no external component provides that, and neither merged adapter has a verified defect justifying replacement. | Section 1.2/1.3; [adapter core](agent-adapter-core.md); #1732 (closed), #1811 |
| Capability / version negotiation | **Shared Pine-owned**, exact pin, fail-closed — with the official JSON Schemas as **compatibility fixtures and drift checks, not a codegen runtime** | Per-connection `initialize` with an exact pinned agent version is the existing house norm; the schemas give a versioned, dated reference for drift detection without adding a runtime. | `KimiACPAgentIdentity`, `OpenCodeACPSession.start`; [schema-v1.34.1](https://github.com/agentclientprotocol/agent-client-protocol/releases/tag/schema-v1.34.1), [schema-v2.0.0-beta.3](https://github.com/agentclientprotocol/agent-client-protocol/releases/tag/schema-v2.0.0-beta.3) (fetched) |
| Provider auth / native configuration | **External official adapter process reuse for Claude** (standalone `claude-agent-acp` archive) **before** any separate native Claude control stack; **native fallback retained** for Codex (owned app-server under #1723), Kimi (terminal auth separately owned), and OpenCode (native `opencode acp` agent) | A maintained agent-side process keeps provider auth/configuration owned by the provider (a Pine requirement), and the standalone Claude archive needs no Node runtime; a native transport is justified only by a demonstrated gap. | [claude-agent-acp v0.109.1](https://github.com/agentclientprotocol/claude-agent-acp/releases/tag/v0.109.1) (fetched); [claude stream/control evidence](claude-stream-control-evidence-2026-11-16.md); #1723 (closed), #1727, #1732 (closed) |
| Pine evidence / verification contract | **Native Pine-owned (no external component)** | The task → checked result → evidence → recovery loop is Pine's differentiator; copying a transport stack without it is explicitly not reuse success per the issue. | [ade acceptance matrix](ade-acceptance-matrix.md); section 1.3 settlement semantics |

**Dual-stack v1/v2 route.** ACP v1 remains the interoperability baseline.
Version is negotiated per connection; v2 support, when built, stays **opt-in**
until provider-proven and never weakens the unknown/unverified/Ready
semantics. The v2 surface to map into the Pine contract, all verified against
the fetched v2 Preview materials: prompt acceptance (`session/prompt`
response carrying `messageId`; response ⇒ inserted, error ⇒ not),
`state_update` (including an idle update with `stopReason: error`), the
`background` work list, `replay_complete` after `session/resume` replay, and
`idempotencyKey` prompt retry. Hypothesis (not verified): the shared framer
and request-ID type can host the v2 wire with only strictness additions, since
v2 keeps single-object JSON lines and string/integer non-null IDs; this must
be confirmed against `schema-v2.0.0-beta.3` before any code.

## 4. PR #1843 disposition and the deferred v2 probe

- **PR #1843 (OpenCode V2 ACP composition) is recommended to be
  *incrementally consolidated*, not reused unchanged and not revised.** It is
  merged and verified per its record (OpenCode contract/native-bridge/
  production-path tests plus the UI test passed, and a real OpenCode 2.3.2
  prepare/start/stop smoke passed without a model prompt — per the PR body,
  fetched; not re-run in this slice). Its wire layer already reuses the shared
  framer and correlation types; "reuse unchanged" would leave the concrete
  duplication named in section 1.4 in place, while "revised" (a rewrite) would
  discard verified behavior without replacement evidence, which the issue
  forbids. The consolidation is a narrow follow-up: share the mandatory-`jsonrpc`
  encode and validation helpers, and the correlation/replay state machine,
  behind the existing seams, keeping every exact pin, the `_meta`
  child-session contract, and the fail-closed settlement semantics.
- **The opt-in ACP v2 probe code is landed in the #1846 code slice** (this
  record's follow-up). The recorded dependency, **PR #1848**, merged to main
  as `a2a5a7355` (2026-11-24), unblocking the deferral. The probe
  (`PineTests/ACPv2ProbeTests.swift`) exercises the first maintained v2 peer
  shape — the standalone `claude-agent-acp` v0.109.1 artifact — with an
  opt-in real-binary `initialize` handshake (env-gated like the other
  real-binary probes, never run by default in CI) plus the always-on
  deterministic v2 wire-strictness and surface-mapping tests; unsupported
  peer behavior stays explicit. Outcomes: section 7.
- **Direct dependency adoption is not chosen now.** `aptove/swift-sdk`
  v0.2.3 remains the best first **probe candidate** for a native Swift ACP
  client behind the existing adapter boundary (no Node/Rust/Electron;
  client+agent roles; v1 high-level plus v2 `ACPProtocol`), conditional on
  exact pinning, license/dependency review, and passing Pine's Kimi/OpenCode
  fixtures first; it is pre-1.0 and its v2 schema parity is unproven, so
  adoption stays a probe outcome, not a decision.

## 5. Linked issues

- [#1729](https://github.com/batonogov/pine/issues/1729) — epic: Pine 3.0,
  outcome-first ADE (parent).
- [#1811](https://github.com/batonogov/pine/issues/1811) — OpenCode V2 as the
  first structured ADE adapter; subject of the PR #1843 disposition above.
- [#1765](https://github.com/batonogov/pine/issues/1765) — task execution
  settings with truthful CLI capabilities; owns the capability/configuration
  evidence this record's negotiation decision relies on.
- [#1723](https://github.com/batonogov/pine/issues/1723) — Codex app-server
  integration (closed/merged); the shared framer's original owner and the
  native fallback for Codex.
- [#1727](https://github.com/batonogov/pine/issues/1727) — Claude Code as the
  fourth structured ADE adapter; the external-adapter-reuse decision for
  Claude targets its requirements.
- [#1732](https://github.com/batonogov/pine/issues/1732) — Kimi Code CLI
  integration (closed/merged); the merged Kimi ACP client inventoried above.

## 6. Acceptance-criteria coverage (this documentation slice)

| Criterion (#1846) | Status in this record |
| --- | --- |
| Dated comparison with exact revisions, licenses, runtimes, protocol versions, capability gaps | Satisfied — section 2 |
| Per-plane decision (dependency / adapter reuse / shared primitives / native fallback), no runtime or dependency added | Satisfied — section 3; this record adds none |
| Chosen approach preserves routing, one-shot permissions, cancellation, uncertain delivery, recovery, native config ownership, Pine-observed checks | Satisfied as a recorded boundary — section 3; execution proof stays with the probes |
| Shared contract probe covering OpenCode and Kimi; evaluate official Codex/Claude adapters against #1723/#1727 | Performed in the #1846 code slice: `PineTests/ACPSharedContractProbeTests.swift` drives the same scenario table through both transports with real outcomes; per-transport results and the real-binary run results: section 7. The official Codex/Claude adapter evaluations remain the section 2.3 rows plus the consumed #1852 decision (Claude) and the v2 probe's real-binary result (section 7) |
| Record whether #1811/PR #1843 is reused unchanged / incrementally consolidated / revised | Satisfied — section 4 |
| Opt-in ACP v2 probe code against a maintained v2 adapter | Landed in the #1846 code slice: opt-in real-binary v2 `initialize` probe plus always-on deterministic v2 wire/surface tests — `PineTests/ACPv2ProbeTests.swift`; run results: section 7 |
| ACP v1 stays the interoperability baseline; v2 opt-in, prepared in parallel, semantics not weakened | Satisfied — section 3 dual-stack route |
| Findings linked back to #1729, #1811, #1765 and affected provider issues | Satisfied — section 5 |

## 7. Probe outcomes (2026-11-24/25, #1846 code slice)

Evidence for this section only: local runs on macOS 27.2.1 (26B131),
Xcode 27.2 (27B52), SDK 27.2 (26B118), worktree base `34244744c`, branch
`feat/1846-acp-v2-probes-2`. Sections 1–6 keep their original evidence
limits. The probe code lives in `PineTests/ACPSharedContractProbeTests.swift`
and `PineTests/ACPv2ProbeTests.swift`.

### 7.1 Shared contract probe (OpenCode + Kimi)

`ACPSharedContractProbeTests` drives the same `AgentProviderContractSuite`
scenario table through both ACP v1 transports — real wire codec, connection
bookkeeping, and session actors for each. The OpenCode fixture machinery was
moved out of `OpenCodeACPTests.swift` into shared
`PineTests/OpenCodeACPTestSupport.swift` (private typealiases keep the
merged #1843 suite's call sites intact) so both merged suites and the probe
drive one fixture, not copies. Real outcomes, 2026-11-24 23:20 run:

| Scenario | OpenCode | Kimi |
| --- | --- | --- |
| question | pass | pass |
| approval | pass | pass |
| continuation | pass | pass |
| cancellation | pass | pass |
| malformed-duplicate-stale | pass | pass |
| reconnect | unsupported — ACP v1 transport loss has no ordered replay; exact explicit load is a new attempt and never restores pending delivery | unsupported — same reason |
| relaunch | pass | pass |
| evidence-fencing | pass | pass |
| backpressure | pass | pass |
| secret-bearing-payloads | pass | pass |

The test asserts cross-transport parity: both ACP v1 transports classify
every scenario identically (pass/unsupported). Result:
`Test run with 5 tests in 2 suites passed` (log `/tmp/pine-1846-focused6.log`).

Real-binary slice (the existing per-provider opt-in smokes): **not run** —
installed versions differ from the exact pins (the smokes' first gate):
`opencode v2.4.0` vs pin `2.3.2`; `kimi 2.7.2` vs pin `2.6.2`; re-pinning
goes through a fresh dated observation. The opt-in runs themselves were
additionally blocked on this host: the XCTest control session timed out
(120 s) while five or more concurrent `xcodebuild test` sessions from other
work owned the desktop test runner — a canary run of the pre-existing,
unchanged `PineTests/GoToLineTests` hung identically (2026-11-25 00:10;
result bundles in the derived-data Logs/Test). Full `PineTests` was not run
locally for the same reason; it remains the CI cross-runtime gate.
`codex-cli 0.172.0` is installed but Codex is the native app-server plane
(#1723), not an ACP v1 transport of this probe.

### 7.2 Opt-in ACP v2 probe

`ACPv2ProbeTests`. Spec basis cited exactly: ACP Preview schema
**v2.0.0-beta.3** (release commit `94824f1`, 2026-11-21) plus the official
v2 protocol pages (overview, initialization, session-setup, prompt-lifecycle)
fetched 2026-11-24 ([S17]).

- **Deterministic part (always runs, no binary): passed 3/3** (2026-11-24
  23:20, same log). It confirms the section-3 hypothesis by code: the shared
  framer and request-ID type host the v2 wire with strictness only — batches
  are fenced, explicit null IDs fenced, missing error fields fenced, and the
  v2 `initialize` negotiation frames (`protocolVersion` 2, `capabilities`/
  `info` shape, -32022 code retained — the error `data` object is dropped by
  the Pine envelope by design) and the section-3 surfaces (`messageId`
  acceptance, `state_update` with `stopReason` and the `background` list,
  `replay_complete`, `idempotencyKey`, `replayFrom`) all round-trip the
  shared envelope.
- **Real-binary part (opt-in `PINE_RUN_ACP_V2_SMOKE=1`): skipped by
  default; not run on this host.** No v2-capable ACP agent binary is
  present: `claude-agent-acp` and `claude` are not installed (search paths
  `/opt/homebrew/bin`, `/usr/local/bin` checked 2026-11-24). Requires the
  standalone `claude-agent-acp` v0.109.1 artifact (or an equivalent
  maintained v2 agent) for the first v2 peer run; `codex-acp` v2.9.0 is not
  run either (requires an authorized npm runtime). The in-test opt-in run is
  additionally blocked by the test-host control-session timeout above.
  Unsupported peer behavior (v1-only or -32022 answers) is recorded by the
  probe as an explicit failure, never a silent skip.
- **No new dependencies.** The probe uses only Pine's own shared wire;
  Aptove v0.2.3 remains the recorded probe candidate, not an adopted
  dependency (section 4).

## Source appendix

Fetched **2026-11-23** unless noted:

- [S1] ACP protocol repository (redirect from zed-industries home): <https://github.com/agentclientprotocol/agent-client-protocol>
- [S2] ACP schema releases: [schema-v1.34.1](https://github.com/agentclientprotocol/agent-client-protocol/releases/tag/schema-v1.34.1), [schema-v2.0.0-beta.3](https://github.com/agentclientprotocol/agent-client-protocol/releases/tag/schema-v2.0.0-beta.3)
- [S3] ACP documentation index: <https://agentclientprotocol.com/llms.txt>
- [S4] "ACP v2 is available in Preview" (published 2026-11-20): <https://agentclientprotocol.com/announcements/acp-v2-preview.md>
- [S5] Community libraries (Swift section): <https://agentclientprotocol.com/libraries/community.md>
- [S6] Testing / TCK page: <https://agentclientprotocol.com/libraries/testing.md>
- [S7] aptove/swift-sdk: [README](https://github.com/aptove/swift-sdk), [v0.2.3 release](https://github.com/aptove/swift-sdk/releases/tag/v0.2.3)
- [S8] wiedymi/swift-acp: [README](https://github.com/wiedymi/swift-acp), [v0.1.0 release](https://github.com/wiedymi/swift-acp/releases/tag/v0.1.0)
- [S9] rebornix/acp-swift-sdk: [README](https://github.com/rebornix/acp-swift-sdk)
- [S10] claude-agent-acp: [README](https://github.com/agentclientprotocol/claude-agent-acp), [v0.109.1 release](https://github.com/agentclientprotocol/claude-agent-acp/releases/tag/v0.109.1)
- [S11] codex-acp: [README](https://github.com/agentclientprotocol/codex-acp), [v2.9.0 release](https://github.com/agentclientprotocol/codex-acp/releases/tag/v2.9.0)
- [S12] Zed external agents docs: <https://zed.dev/docs/ai/external-agents>; [ACP Registry blog](https://zed.dev/blog/acp-registry) (2026-01-28); [LICENSE-GPL](https://github.com/zed-industries/zed/blob/main/LICENSE-GPL)
- [S13] JetBrains ACP docs: <https://www.jetbrains.com/help/ai-assistant/acp.html>; [IntelliJ IDEA ACP blog](https://blog.jetbrains.com/idea/2026/08/how-to-use-ai-agents-in-intellij-idea-with-acp/) (2026-08-12); [registry blog](https://blog.jetbrains.com/ai/2026/01/acp-agent-registry/) (2026-01-28)
- [S14] T3: [t3code LICENSE](https://raw.githubusercontent.com/pingdotgg/t3code/main/LICENSE) (MIT); [provider-acp package PR #17354](https://github.com/pingdotgg/t3code/pull/17354) (merged 2026-10-09)
- [S15] PR records (fetched 2026-11-23): [PR #1843](https://github.com/batonogov/pine/pull/1843) (merged 2026-11-22), [PR #1848](https://github.com/batonogov/pine/pull/1848) (open)
- [S16] #1846 initial reuse audit (issue comment, 2026-11-22): <https://github.com/batonogov/pine/issues/1846>
- [S17] ACP v2 protocol pages (fetched 2026-11-24, cited by section 7.2): [Overview](https://agentclientprotocol.com/protocol/v2/overview), [Initialization](https://agentclientprotocol.com/protocol/v2/initialization), [Session Setup](https://agentclientprotocol.com/protocol/v2/session-setup), [Prompt Lifecycle](https://agentclientprotocol.com/protocol/v2/prompt-lifecycle); pinned schema revision: [schema-v2.0.0-beta.3](https://github.com/agentclientprotocol/agent-client-protocol/releases/tag/schema-v2.0.0-beta.3) (commit `94824f1`)
