# Workspace composition study

Part of [#1735](https://github.com/batonogov/pine/issues/1735). This is an **unapproved interaction study**, not shipped Pine functionality or final design sign-off. It explores the [Pine 3 product vision](../../../pine-3.0-product-vision.md).

Serve this directory with a local static server and open [the prototype](index.html) in a browser. For example, run `python3 -m http.server 8765 --bind 127.0.0.1 --directory docs/design/pine-3/workspace-study` from the repository root, then visit `http://127.0.0.1:8765/`. It has no external dependencies, API calls, provider connections, persistence, or command execution. A real page reload resets the sample; **Simulate relaunch** demonstrates the intended metadata/evidence distinction in memory.

## The choice

| Composition | Spatial model | Strength to validate | Tradeoff to validate |
| --- | --- | --- | --- |
| A — Focus workspace | Persistent compact project/task navigation beside one selected task canvas. | Fast task switching and a stable sense of place; results own the remaining width. | Navigation competes with a result in compact windows; the hierarchy can resemble an editor unless task names and context lead. |
| B — Project table | Project navigation above a full-width work table; a task opens as a focused sheet in the same canvas. | Project context is the starting point, with more width for questions and results and no permanent file-tree rail. | Returning between task and project adds a navigation step; task-switch discoverability needs careful keyboard testing. |

These are different compositions of one interaction model. Changing A/B retains the task, selected view, and unsaved sample draft. Neither direction requires a terminal grid, fleet dashboard, provider topology, or Pine-owned agent loop.

The maintainer must choose a direction, or request another composition, before production implementation and final visual sign-off. These examples do not select a final icon or supersede the earlier issue concepts.

## Walkthrough

1. Open a project. Create a task with the remembered illustrative agent, or open a named existing task.
2. Use **Show a question**, answer once, and inspect the task's working state. Intermediate activity stays inside the task; the Inbox button opens an attention item rather than a fleet view.
3. Use **Show checked result** to substitute illustrative check/reviewer evidence. This is a prototype control outside the app surface, not an agent action or verification implementation.
4. Inspect **Checks passed · Independent review · Limitations**. Viewing does not accept or execute. The sample evidence names the candidate, environment, pre/post identity relationship, separate reviewer, and limitations.
5. Compare Atlas (**Open preview**), Canvas (**Run application**), Trail CLI (**Run example**), and Field Notes (**Open document**). The first three actions show a confirmation describing intended side effects and immediate binding/grant revalidation. **Continue in prototype** only announces a simulated outcome. **Open document** directly displays the sample document without execution or an execution-permission dialog. Acceptance remains separate.
6. Open **Files**, edit the sample, switch composition, return to the project, and reopen the task. The draft and view remain; checks/review/acceptance become stale immediately. Earlier reviewed/accepted revision metadata stays in Task details.
7. Give feedback from a settled, actionable task. It creates an illustrated unchecked revision. Active-turn input is disabled in this provider example; attachments are explicitly unsupported here rather than silently simulated.
8. Use **Simulate relaunch**. Every task across all projects retains its goal, draft, feedback reference, and history in memory; all live evidence becomes stale and old questions cannot be answered. Only **Resume explicitly** simulates a new attempt. No agent or correction loop starts.
9. Inspect cancelled, unknown, unverified, failed-check, and unavailable-environment fixtures. None expose a result-execution or acceptance action.

## Verification and limits

Run from this directory:

```sh
node --check study.js
node smoke.cjs
```

The eleven interaction-contract checks cover one-shot question answers, viewing versus acceptance, stale evidence after editing/feedback, historical acceptance across repeated edit/check/accept cycles, app-wide restoration across projects, task/view/draft continuity across compositions/navigation, restore barriers, all four project types, unavailable-state action refusal, and escaping entered task text. Static checks cover local links, unique HTML IDs, external-resource absence, explicit form labels, dialog labels, and script syntax.

The prototype uses native HTML buttons, forms, disclosures, and modal dialog semantics; an announced status region; visible focus; a skip link; semantic landmarks; compact-width styles; and reduced-motion/forced-color rules. They are design provisions, **not verified VoiceOver or native macOS accessibility acceptance**.

Browser visual/interaction QA was unavailable in the authoring environment: the Browser skill requires its supplied JavaScript execution tool, which was not exposed. No screenshots or visual-accuracy claims are included. Compact CSS permits long unbroken goals and multi-line statuses, stacks task metadata at narrow widths, and does not clip the window contents. These are static provisions; inspect both compositions at 320px with a 180-character unbroken goal before design sign-off. Keyboard focus, modal behavior, compact layout, high contrast, and VoiceOver must be exercised in a real browser before choosing the composition. The app build and XCUITest suites are not applicable to this isolated documentation prototype.

Production work remains: real provider and task routing, exact evidence/grant display, file/diff/terminal integration, durable recovery, per-task focus/layout restoration, every app locale, native controls/window behavior, keyboard/VoiceOver announcements, compact windows, and approved visual artifacts. English-only study copy does not change canonical public product claims.
