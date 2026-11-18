# #1762 baseline access record — trial machine, 2026-11-16

Scope: which required baselines can run a matched trial on **this** machine
today, and the concrete blocker where they cannot. **No competitor has been
run or measured here; nothing in this record is an observation of competitive
effectiveness.** #1810's entry conditions do not authorize real-provider
execution, model calls or installations for this preparation work, so "not
installed + installation not authorized" is the recorded blocker, not a
substitute test.

## Machine (recorded 2026-11-16)

- macOS 27.2.1 (build 26B131), Apple M4 Pro, 14 cores, 48 GiB RAM
- Python 3.15.2 (offline fixtures run under it; the revenue seed was
  calibrated on 3.9.6 and re-ran clean here on 2026-11-16)
- Homebrew (aarch64). `pytest` is not installed for this Python; the
  documented runners are unittest-based (`python3 -B test_report.py`,
  `python3 -B test_ledger.py`), so nothing here needs pytest.

## Required baselines

| Baseline | Installed? | Exact version | Usable for a matched trial on this machine? | Concrete access blocker |
| --- | --- | --- | --- | --- |
| Zed (required) | No | n/a — no `/Applications/Zed.app`, no `zed` binary, no Homebrew cask | No | Not installed. Only app-support residue of an earlier install exists (last Zed log line 2026-05-25, an auto-update check). Running a matched trial needs installing Zed plus an authenticated agent session (Zed account or external-model config); installation and provider execution are not authorized for this preparation task. |
| herdr (required) | No | n/a — no app, no `herdr` binary, no Homebrew cask | No | Not installed. No herdr runtime exists on this machine; installation not authorized for this preparation task. |
| One result-oriented baseline — Conductor, Orca or Codex desktop per the issue (required) | No | n/a | No | Conductor: no conductor.build app installed. Orca: no app installed. Codex: no desktop app installed — only the `codex` CLI 0.168.0 is present, which is a provider CLI inside Pine's #1811 adapter chain, not a desktop ADE baseline. No paid/authorized account for any of the three is available to the preparation worker. |

## Other market references (recorded for completeness)

Cursor: not installed. Warp: not installed. cmux: not installed.
Paradev/Superset: not installed. Antigravity: not installed.

## Available provider surfaces (Pine-side trial inputs, not baselines)

| Surface | Version | Notes |
| --- | --- | --- |
| opencode | 2.2.7 | Homebrew formula; first in the #1811 delivery order |
| codex (CLI) | 0.168.0 | Homebrew cask `codex` |
| claude-code | 2.1.311 | Homebrew cask |
| kimi-code | 2.5.3 | Homebrew formula; `Kimi.app` also installed |
| LM Studio | 0.4.28 | local model runtime |
| Ollama | 0.40.16 | local model runtime |
| Empryo.app | present | retired from candidates via #1766; not a baseline |

## Consequence for the scorecard

All three required baselines currently carry a **named concrete access
blocker** on the trial machine; the issue's acceptance explicitly allows
"names a concrete access blocker" in place of a measured baseline. Before the
live cohort trial (external, maintainer-run) the maintainer must, per
baseline: (a) install it, establish an authorized working session, record the
exact version here, and re-verify the machine rows, or (b) keep the blocker,
limit that baseline's comparison to documented-claim evidence (labeled
**source**, never **runtime**), and state the resulting confound in #1761.
No competitor measurement is claimed by this record, and none may be derived
from it.
