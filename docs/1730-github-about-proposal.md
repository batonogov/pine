# GitHub About — prepared copy for #1730

Status: **prepared, not applied.** Repository metadata changes are external
actions; run the command below only after the maintainer authorizes it.
Verify with the check command afterwards, as
[.agents/rules/marketing-surfaces.md](../.agents/rules/marketing-surfaces.md)
requires.

The final copy is the landing page's `meta.description`
(static tag in `docs/index.html`, mirrored in `docs/i18n/en.json`), which keeps
Pine 2.x capabilities described as shipped and identifies the ADE as the Pine 3.0 direction.

## Current live state (read 2026-11-16 via `gh api repos/batonogov/pine`)

- **Description (170 chars):**
  `A native macOS code editor for CLI-agent workflows. Split editor and terminal panes, a cross-project Agent Inbox, private notifications, LSP, Git context — zero Electron.`
- **Homepage:** `https://batonogov.github.io/pine`
- **Topics (19):** `ai-agents`, `appkit`, `cli`, `code-editor`,
  `code-intelligence`, `coding-agents`, `developer-productivity`,
  `developer-tools`, `git`, `liquid-glass`, `local-first`, `lsp`, `macos`,
  `macos-app`, `native`, `swift`, `swiftui`, `terminal-emulator`, `text-editor`.

## Proposed state

### Description

Primary — the landing `meta.description` verbatim (220 chars), so the About
section and the landing page say one thing:

```text
A native macOS editor for CLI-agent workflows — agent in the terminal, code in view. Pine 3.0 is heading toward an outcome-first ADE with durable tasks, verified results, and attention in the current project's task list.
```

Fallback, if the maintainer prefers the current ~170-char length (165 chars):

```text
A native macOS editor for CLI-agent workflows. Pine 3.0: an outcome-first ADE with durable tasks, verified results, and attention in the current project's task list.
```

Both keep durable wording: no agent counts, adapter totals, or release dates.
The "heading toward" phrasing keeps the ADE labeled as Pine 3.0 direction,
matching the README, landing, and in-app Help.

### Homepage

Unchanged: `https://batonogov.github.io/pine`. Keep the existing GitHub Pages
deployment; no new hosting target.

### Topics

Add one topic to the existing 19 (total 20, within GitHub's 20-topic limit;
all names lowercase and ≤ 50 chars):

- `ade` — the product category the Pine 3.0 milestone owns. It is a direction
  label, consistent with the description's "heading toward" wording; it is not
  a claim that ADE functionality ships today.

No topics are removed; all 19 current topics remain accurate for the shipped
Pine 2.x product.

## Command to run after authorization

Use the primary description; swap in the fallback string if preferred.

```sh
gh repo edit batonogov/pine \
  --description "A native macOS editor for CLI-agent workflows — agent in the terminal, code in view. Pine 3.0 is heading toward an outcome-first ADE with durable tasks, verified results, and attention in the current project's task list." \
  --homepage "https://batonogov.github.io/pine" \
  --add-topic ade
```

## Verification after the update

```sh
gh repo view batonogov/pine --json description,homepageUrl,repositoryTopics
```

Expected: the description matches the string above, the homepage is unchanged,
and `repositoryTopics` contains the 20 names (the 19 existing plus `ade`).

## Canonical install command

No change. The Homebrew command remains
`brew install --cask batonogov/tap/pine-editor` everywhere unless #1733
approves and implements a safe migration.
