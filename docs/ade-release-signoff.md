# Pine 3.0 ADE experience and craft sign-off (placeholders)

Sign-off placeholders for the #1761 integrated acceptance record, per the
issue's "Experience and craft sign-off" section. Nothing here is signed off;
each placeholder names its owner, status in the base `5cd4707b`
(2026-11-16), and what must be true before it can be recorded as passed.
Static mockups, an attractive icon, decorative glass, and passing functional
tests alone do not establish design sign-off.

## 1. Comparative experience validation (#1762)

- **Owner:** #1762 / `work/20261116-issue-1762`.
- **Status in this base:** protocol merged (`docs/ade-boundary-ux-acceptance.md`
  from #1810); scenario seed shipped
  (`docs/validation/1762/revenue/`); **no comparative trial has run; no score
  is claimed**.
- **Required before sign-off:** the #1762 scorecard for boundary cards B1–B6
  with one evidence row per observation (the header format from the
  protocol), matched task requirements, recorded confounds, and the
  pre-registered provisional targets checked against actual measurements.
  Documented competitor features are not hands-on measurements, and
  provisional product targets are not achieved performance claims.
- **Feed-forward rule:** observed boundary defects go to their existing
  owners; the corrected candidate plus rerun is linked from #1761.

## 2. Subtraction / merge ledger (#1760)

- **Owner:** #1760 / `work/20261116-issue-1760`.
- **Status in this base:** workspace scope confirmed 2026-11-16 (one current
  project, task-local results/output, explicit Request/Command); the concrete
  subtraction/merge ledger is in flight.
- **Required before sign-off:** every removal/merge decision has a
  keep/change/remove/defer disposition with evidence, and the implemented
  candidate actually matches the ledger (no new permanent panel or repeated
  setup step per evidence/context/action type).

## 3. Prototype-vs-implementation discrepancy table

Record every discrepancy between the approved prototype
(`docs/design/pine-3/`) and the implemented candidate. One row per
discrepancy, no silent deferrals:

| # | Prototype element (asset/section) | Implemented behavior | Discrepancy type (match / deviation / missing / added) | Owner | Disposition (keep / change / remove / defer) | Disposition evidence |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | — | — | — | — | — | — |

The table is completed when the ADE workspace (#1735/#1760) lands against
the integrated candidate; until then it is a placeholder, not an empty pass.

## 4. Keyboard / VoiceOver / appearance verification checklist

Mapped to the automated coverage in this base. A check is "verified" only
when the automated lane is green on the candidate **and** the manual pass
(`docs/accessibility-release-checklist.md`) is recorded for the implemented
ADE surfaces.

| Check | Automated coverage in this base | Manual pass | Status in this base |
| --- | --- | --- | --- |
| Keyboard-only navigation (physical and on-screen) | `AccessibilityLocalizationSmokeTests.testKeyboardOnlyCriticalJourney`, `AgentAttentionKeyboardUITests` | Physical-keyboard journey from the checklist | Legacy surfaces only; ADE surfaces pending |
| VoiceOver announcements (roles, values, focus order, rotors, splitter adjust) | AX-tree captures in `AccessibilityLocalizationSmokeTests`; `AccessibilityTreeProbe.swift` | Checklist items 1–9 (Welcome, Settings, terminal, popovers, split panes, quick pick, status bar, Problems, alert surfaces) | Legacy surfaces only; ADE surfaces pending |
| Reduce Motion (immediate transitions, no re-centring) | `AccessibilityLocalizationSmokeTests` Reduce Motion matrix lane | Checklist item 10 | Legacy surfaces only; ADE surfaces pending |
| Reduce Transparency (opaque fallbacks for Command Palette, completion, Problems, toasts) | **none** (not in the automated matrix) | Checklist item 10 | GAP: manual-only; add to the CI matrix or record as an unresolved blocker |
| Increase Contrast / Differentiate Without Color | Differentiate Without Color matrix lane (status/selection cues must not rely on color alone) | Checklist item 10 | Increase Contrast itself is **manual-only** (gap, as Reduce Transparency) |
| Compact and large windows | `EditorWindowTests`, `MultiWindowTests` (legacy) | Representative-configuration pass | ADE workspace window behavior pending |
| Unsaved work and restoration | `UnsavedChangesUITests`, `SessionRestoreTests` | Checklist item 9 | Legacy surfaces only; ADE task drafts pending |

Known limitation carried from the base: macOS XCUITest accessibility events
bypass Pine's local `NSEvent` monitors for several production shortcuts, so
the physical-keyboard journey remains a short manual check.

## 5. Craft criteria

Apply #1735's explicit craft criteria to the implemented app before any
design sign-off is recorded: type/spacing/material/motion consistency,
actual-size rendering, interaction details, compact/large windows, localized
text, and complete failure/recovery states. The maintainer's
Jony-Ive-level coherence and precision is the ambition, not the current
state; no design sign-off is claimed in this base.

## Sign-off record (filled at candidate time)

| Sign-off | Owner | Candidate SHA | Date | Evidence references | Verdict |
| --- | --- | --- | --- | --- | --- |
| Comparative experience (#1762 scorecard) | #1762 | — | — | — | placeholder |
| Subtraction ledger (#1760) | #1760 | — | — | — | placeholder |
| Prototype discrepancy table | #1735/#1760 | — | — | — | placeholder |
| Keyboard/VoiceOver/appearance checklist | #1761 gate + CI | — | — | — | placeholder |
| Craft criteria | #1735 | — | — | — | placeholder |

Cross-provider handoff remains a ship/defer decision under #1759, not an
automatic release blocker.
