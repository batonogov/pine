# CLI capability evidence — 2026-11-14

Scope: [#1767](https://github.com/batonogov/pine/issues/1767), based on the
[19-entry audit](https://github.com/batonogov/pine/issues/1761#issuecomment-6865025294)
at `421a54a3258583c396d52f977fd8206ceff2c5a3`. This record accompanies
[#1766](https://github.com/batonogov/pine/issues/1766)'s Empry⊙ retirement;
18 entries remain active in the integrated catalog. It changes documentation, not
executable recognition, version metadata, or adapter authority. The
[compatibility catalog](agent-compatibility.md) is the shipped support table;
[Pine 2.0's release matrix](pine-2.0-agent-release-matrix.md) retains historical
Pending observations. Neither is a Pine 3.0 acceptance pass.

## Evidence meanings and limits

- **Release-source / documented:** official published material describes a
  release or interface. Reading current documentation does not establish that
  an older fixture-labeled binary implements it.
- **Fixture:** checked-in synthetic command shapes or protocol examples.
  `process-v1.json`'s fixture date is 2026-11-12; per-entry capture environments
  are not encoded. Its version labels are retained unchanged. These tests do
  not execute installed CLIs or negotiate a provider protocol.
- **Version/help:** an explicitly bounded executable observation. It does not
  establish authentication, usable models, a protocol handshake, approval,
  cancellation, restore, or completion. Launchers can mutate state even for
  `--version`.
- **Handshake:** successful negotiation on a pinned binary and transport;
  it proves only the negotiated exchange, not the complete task flow.
- **End-to-end:** observed capability scenarios against a pinned binary,
  negotiated protocol, environment and Pine revision, with checks and outcomes.

Every retained entry has fixture evidence and official documentation reviewed
on **2026-11-14** (sources below). Every entry's current Pine tier is
**Detected**; enabled evidence is exact executable identity from process
observation, bound to the observed generation. Launch is manual terminal/new
session only. Provider structured transport, controls and resume are disabled;
termination never proves success. **No handshake or end-to-end result is
recorded for any entry in this audit. Protocol/capability minimum versions are
unknown**, separately from the catalog fixture versions.

No CLI, wrapper, login, model request, installer, updater, native configuration
or shell startup file was executed or evaluated for this refresh. Sources were
read over the web; existing version/help observations were attributed rather
than repeated. A future supported launch must validate package/launcher
identity and bootstrap behavior before probing; passive process observation
must never run discovered commands. Do not infer account, billing, model
availability or effective settings from a name match.

## Per-entry evidence and identity

“Not recorded” means this record has no bounded installed-binary observation;
it does not mean the executable is absent. Identity links identify the official
project/distribution, not authentication of an arbitrary same-named local file.
All aliases below are Pine's existing exact aliases; no generic `agent` alias
is added. Current upstream interface descriptions in the final column remain
**documented candidates**, with no Pine transport enabled.

| Entry / official identity | Pine executable aliases | Catalog fixture version | Binary evidence / platform / date | Documented candidate and limitation (source reviewed 2026-11-14) |
| --- | --- | --- | --- | --- |
| [Pi](https://github.com/badlogic/pi-mono) | `pi` | 0.83.0 | Historical local check, macOS, 2026-08-03; exact command scope not retained here | JSONL RPC (`--mode rpc`). Prompt acknowledgement and `agent_end` do not establish settled work; wait for the appropriate settlement event. Split on LF, not Unicode separators. [S1] |
| [Codex](https://github.com/openai/codex) | `codex` | 0.146.0 | Version/help 0.169.0, macOS, 2026-11-14 audit; precise OS/toolchain not recorded | Owned app-server is the required first adapter (#1723). Dynamic settings/auth and exact provider-bound resume need actual capability results. [S2] |
| [Claude Code](https://github.com/anthropics/claude-code) | `claude` | 2.1.220 | Version/help 2.1.311, macOS, 2026-11-14 audit; precise OS/toolchain not recorded | Stream-json/control candidate, required third adapter (#1727). Help is not a bidirectional permission exchange. Auth/customization inheritance and resume prompt snapshots need pinned control evidence. [S3] |
| [OpenCode](https://github.com/anomalyco/opencode) | `opencode` | 1.18.10 | Version/help 2.3.0 including `acp --help`, macOS, 2026-11-14 audit | V2 `opencode acp` owns stdio/private server. It is separate from experimental HTTP and the V1 fixture. Questions need client form support, forwarded MCP is directory-scoped, restore requires original cwd; children may outlive parent generation. Optional, not a fourth required adapter. [S4] |
| [GitHub Copilot CLI](https://github.com/github/copilot-cli) | `github-copilot-cli`, `copilot` | 1.0.77 | Not recorded | ACP public preview (`copilot --acp`); launch settings seed sessions. BYOK can operate without GitHub login, and unknown slash commands may reach the model. [S5] |
| [Aider](https://github.com/Aider-AI/aider) | `aider` | 0.86.0 | Not recorded | One-shot scripting can edit and auto-commit, including dirty changes. The Python API has no stability promise. A dry-run or single message is not approval/recovery parity. [S6] |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli) | `gemini` | 0.53.1 | Not recorded | Headless JSON and ACP documentation are separate candidates. Preserve `gemini` identity and account/session distinctions from `agy`; migration notice disposition below. [S7] |
| [Amp](https://ampcode.com/docs/cli/execute-mode) | `amp` | 0.0.1785747753-g51f676 | Not recorded | Execute/streaming JSON candidate. Noninteractive threads default to Standard, unlike remembered interactive Fast mode. Orb and runner launches can exit while remote work continues; process exit proves no remote outcome. [S8] |
| [Cursor Agent](https://cursor.com/docs/cli/installation) | `cursor-agent` | 2026.07.23-e383d2b | Not recorded | Current distribution docs use `agent` and describe `agent acp` as well as print output. Name alone cannot distinguish a generic `agent` program. Print mode can modify files without `--force` when approval is unnecessary; approval-requiring actions are rejected. No alias expansion. [S9] |
| [Goose](https://github.com/block/goose) | `goose` | 1.45.0 | Not recorded | `goose acp` stdio and `goose serve` ACP transports are documented. Permission callbacks do not create a sandbox; configured tools/mode and negotiated restore capabilities matter. [S10] |
| [Qwen Code](https://github.com/QwenLM/qwen-code) | `qwen` | 0.21.4 | Not recorded | Official Zed integration documents `qwen --acp`. “Full ACP” is not a promise of every method, version or daemon/stdio parity. [S11] |
| [Crush](https://github.com/charmbracelet/crush) | `crush` | 0.88.0 | Not recorded | Workspace/SSE remains experimental for Pine. Configuration supports executable expansion; loading it is not passive discovery. Clients sharing a cwd share backend state; first-client `--yolo`/`--debug` flags win. Separate sessions do not prove isolation. [S12] |
| [Kimi Code](https://www.kimi.com/code/docs/en/kimi-code-cli/reference/kimi-acp.html) | `kimi`, `kimi-code` | 2.1.1 | Version/help 2.6.0 including `acp --help`, macOS, 2026-11-14 audit; precise OS/toolchain not recorded | `kimi acp` required second adapter (#1732). New-session directories, fork behavior, client callbacks and media drops need exact contract coverage; no generic provider/account API is implied. `kimi-code` covers the rewritten process title. [S13] |
| [Antigravity](https://antigravity.google/docs/cli/headless) | `agy` | 1.5.6 | Release-source 2026-11-12; binary not observed | Headless JSON/stream input and separate `agy acp`. Headless soft-denied operations can exit 0; stream input does not accept arbitrary control/non-text messages. Gemini configuration migration does not establish session or account equivalence. [S14] |
| [Droid](https://docs.factory.com/droid-cli/cli-reference) / npm `droid` | `droid` | 1.9.0 | Release-source 2026-11-12; binary not observed | Exec JSON/JSON-RPC and ACP candidates. Interactive `droid -r` is resume; `droid exec -r` is reasoning effort. Older stream-json differs from stream-jsonrpc. Standalone installs auto-update by default; npm binaries disable auto-updates at build time. Native worktree lifetime needs verification. [S15] |
| [Cline](https://github.com/cline/cline) / npm `cline` | `cline` | 3.0.74 | Release-source 2026-11-12; binary not observed | JSON, ACP (`--acp`), hooks. Generic CLI docs list auto-approve default true; ACP docs require file/command permissions by default. Treat these as transport-specific claims needing pinned verification. `CLINE_PROVIDER` can disable switching. [S16] |
| [Grok Build](https://github.com/xai-org/grok-build) | `grok` | 1.0.77 | Release-source 2026-11-12; binary not observed | Headless JSON streams are output-only; bidirectional approvals use ACP (`grok agent`). `-s` creates a new UUID session; resume uses `-r`. Messages-shaped output grants no Claude identity; emitted UUIDs and zero-valued unknown usage are not trustworthy dedup/accounting evidence. [S17] |
| [Kilo Code](https://github.com/Kilo-Org/kilocode) / npm `@kilocode/cli` | `kilo`, `kilocode` | 7.8.27 | Release-source 2026-11-12; binary not observed | `kilo acp`, serve and run JSON candidates. Fork lineage establishes neither OpenCode V2 schema parity nor alias identity. Global permission changes can affect other sessions; autonomous questions cannot replace user answers. [S18] |

All rows also carry synthetic fixture evidence. The five release-source rows
retain the 2026-11-12 source-verification history from the previous catalog;
this refresh did not reinstall them or certify latest releases. Other old
release-label provenance is not sufficiently detailed to assign a new capture
date/platform. The older Pi/Codex/OpenCode local checks (2026-08-03) and Kimi
2.1.1 local check (2026-09-28) are historical command checks, not protocol
certification. The newer four version/help observations come from
[#1765's limited discovery](https://github.com/batonogov/pine/issues/1765#issuecomment-6864822512),
which resolved them under `/opt/homebrew/bin`; no authentication, generation,
handshake or recovery was exercised. Exact original OS/SDK logs are unavailable
in that report. Do not synthesize a tested macOS 26/27 matrix from it.

## Explicit identity and retirement dispositions

**Cursor:** retain only `cursor-agent` detection. The current official installer
uses `agent`, but this refresh does not validate installed package identity or
collision handling. Unknown `agent`, agent helpers and arbitrary wrappers stay
generic. A future alias change needs a reproduced detection requirement,
identity policy, negative fixtures and synchronized catalog/Help updates.

**Gemini / Antigravity:** the dated #1761 audit reports a migration notice for
unpaid/Google One users. That exact eligibility notice was not reproduced in
this refresh's retrieved Gemini homepage/headless pages; account eligibility
remains unverified. The current official Antigravity migration guide describes
configuration conversion and first-launch onboarding. Neither source justifies
rewriting `gemini` to `agy`, migrating credentials automatically in Pine,
resuming across products, or declaring every Gemini installation obsolete.
Keep executable, account eligibility, configuration and session evidence
separate. [S7] [S14]

**Empry⊙ (19th audited entry, retired):** #1766 removes active recognition and
presentation, preserves bounded generic history/tasks and manual terminal use,
and reserves retired identity against impersonation. The earlier 3.12.2-beta
fixture and version/help record are historical. The later 3.12.8-beta version
probe ran a bootstrap wrapper that reported replacing the runtime; state
preservation was not independently established. It is not a passive probe or
structured compatibility result. Do not execute it again for catalog discovery,
uninstall it, or delete user `.empryo` data. No structured adapter is planned.
The integrated active catalog and all nine Help pages reflect this retirement.
Retired remembered defaults require a new explicit agent choice; historical
release records remain unchanged.

## Verification handoff

Required structured delivery remains Codex #1723 → Kimi #1732 → Claude #1727.
Each owner must feed actual pinned capability results to
[#1761](https://github.com/batonogov/pine/issues/1761), using its C1–C11 gates:
discovery/launch; auth/effective settings; questions/permissions;
sessions/recovery; enforced read-only review; parallel/shared-state ownership;
context/media; environments/actions; candidate-bound evidence; result-first UX;
and public compatibility. Required unavailable core capabilities remain blockers.
Optional agents stay detected-only/deferred until separately selected and
implemented. Generic protocol documentation is not a floor for a specific CLI.

Shared identity coverage is split by purpose:

| Evidence | Checked boundary |
| --- | --- |
| `FirstPartyAgentCompatibilityTests.unknownAndLookalikeCommandsStayGeneric` | Existing product-name, prefix/suffix and helper negatives. |
| `FirstPartyAgentCompatibilityTests.newDetectedAgentsResolveAndPersistWithoutClaimingStructuredEvents` and `.kiloCodeDoesNotShareOpenCodeExecutableIdentity` | Existing #1726 identities and Kilo/OpenCode fork separation. |
| `AgentReleaseGateTests.firstPartyConformanceAndFallback` | Every catalog alias and its `-helper` lookalike. |
| `AgentCatalogIdentityFixtureTests` + `identity-boundaries-v1.json` | New shared 64-case corpus: all 21 exact aliases of the 18 retained entries, each alias-helper negative, generic `agent`/path/Node-wrapper collisions, arbitrary-wrapper arguments, and explicit OpenCode/Kilo plus Gemini/Antigravity identity boundaries. |
| #1766 retirement tests | Retired `empryo` command shapes, persisted records and tombstone/default handling; owned separately from the retained catalog fixture. |

The new consumer checks corpus coverage against the active catalog, then
runs every case through actual executable extraction, presentation resolution
and `AgentType` classification. It also injects the complete synthetic snapshot
into `AgentDetector`, requiring no sessions for negative cases and the exact
identity for positive cases. Command strings are data and are never executed.
This is process-parser coverage, not upstream JSON/protocol or binary evidence.
A bounded standalone probe compiled the production extraction and identity
source with the 64-case corpus and reported 64 cases / 0 failures on
2026-11-14. This checks parsing/classification only; it does not substitute for
the new Swift Testing consumer or injected-snapshot run. Focused target tests
and parent integration review/verification must pass before delivery.

The original `process-v1.json` remains positive synthetic command-shape data;
the separate versioned identity corpus supplies shared negative examples without
changing production recognition or inventing an `agent` alias. #1766's retirement
implementation is the dependency for the catalog-completeness assertion.
The integrated active catalog and every Help locale contain the same retained
set. Required parent review and local/CI verification remain separate gates. Remaining unknowns include binary/protocol floors,
account eligibility, enforced reviewer controls, session isolation and actual
end-to-end scenarios. No Pending historical row becomes Pass through this audit.

## Official source appendix

All links below were read **2026-11-14**. They are mutable upstream documents,
not immutable release attestations or binary observations. Repository links in
the identity table name the upstream distribution; an executable path/name
alone is not package authentication.

[S1]: https://raw.githubusercontent.com/badlogic/pi-mono/main/packages/coding-agent/docs/rpc.md
[S2]: https://developers.openai.com/codex/app-server
[S3]: https://code.claude.com/docs/en/cli-reference
[S4]: https://opencode.ai/docs/cli/acp/
[S5]: https://docs.github.com/en/enterprise-cloud@latest/copilot/reference/copilot-cli-reference/acp-server
[S6]: https://aider.chat/docs/scripting.html
[S7]: https://geminicli.com/docs/cli/headless/
[S8]: https://ampcode.com/docs/cli/execute-mode
[S9]: https://cursor.com/docs/cli/headless
[S10]: https://raw.githubusercontent.com/block/goose/main/documentation/docs/gdk/acp/index.md
[S11]: https://qwenlm.github.io/qwen-code-docs/en/users/integration-zed/
[S12]: https://raw.githubusercontent.com/charmbracelet/crush/main/README.md
[S13]: https://www.kimi.com/code/docs/en/kimi-code-cli/reference/kimi-acp.html
[S14]: https://antigravity.google/docs/cli/headless
[S15]: https://docs.factory.com/droid-cli/cli-reference
[S16]: https://docs.cline.bot/usage/cli-overview
[S17]: https://raw.githubusercontent.com/xai-org/grok-build/main/crates/codegen/xai-grok-pager/docs/user-guide/14-headless-mode.md
[S18]: https://kilo.ai/docs/code-with-ai/platforms/cli

Additional mode/identity-specific official references:

- [Gemini ACP](https://geminicli.com/docs/cli/acp-mode/).
- [Antigravity ACP](https://antigravity.google/docs/cli/acp/) and
  [Gemini configuration migration](https://antigravity.google/docs/cli/gcli-migration/).
- [Cursor distribution](https://cursor.com/docs/cli/installation) and
  [Cursor ACP](https://cursor.com/docs/cli/acp).
- [Cline ACP permission defaults](https://docs.cline.bot/usage/acp.md).
- [Amp remote orb execution](https://ampcode.com/docs/cli/spawning-orbs).
