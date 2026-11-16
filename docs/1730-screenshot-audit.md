# Screenshot audit — #1730 (2026-11-16)

Scope: visual audit of `assets/screenshot-*.png` against the UI being
described on the README, the landing page, and the in-app Help, plus a check
for credentials, private paths, user data, temporary/UUID paths, and
test-only wording. **No new captures:** the ADE UI is not shipped, so no
ADE screen may be mocked; refreshes happen through
`scripts/update-screenshots.sh` (fixtures in `PineUITests/ScreenshotTests.swift`,
forced dark appearance via `--ui-test-dark-appearance`) only when the
corresponding user-visible UI change lands.

## Per-capture result

| Capture | Shows | Claim it supports | Verdict |
| --- | --- | --- | --- |
| `screenshot-terminal.png` | `Pine Demo` project, `WorkspaceRouter.swift` tab, terminal with `git diff --stat` and `swift test` output, generic `pine@mac` host | built-in terminal, agent workflow, Git context | OK — released 2.x UI, relative paths only, no secrets |
| `screenshot-editor.png` | `Pine Demo` project, `GreetingService.swift`, file-tree sidebar, minimap | code editor with syntax highlighting and minimap | OK — released 2.x UI |
| `screenshot-markdown.png` | `Pine Demo` README split view: source + rendered preview | Markdown preview in split mode | OK, one fragile claim (below) |
| `screenshot-minimap.png` | `Pine Demo` project, synthetic `Calculator.swift`, minimap with viewport | minimap overview | OK — released 2.x UI |
| `screenshot-sidebar.png` | `Pine Demo` file tree, `No File Selected` empty state | sidebar with the project file tree | OK — released 2.x UI |
| `screenshot-welcome.png` | Welcome window: Pine mark, tagline, `Open Folder…`, `Agent Inbox` button, `No Recent Projects` | Welcome screen, Agent Inbox entry point | OK — released 2.x UI |
| `screenshot-agent-inbox.png` | Agent Inbox popover with seeded marketing tasks (Claude Code, OpenCode, Gemini CLI, Codex) and `Pine Demo` / `Launch Site` / `Documentation` fixture projects | cross-project Agent Inbox with task routing | OK with two flagged observations (below) |

All seven captures use the stable fixture project name `Pine Demo` (plus
generic fixture folder names), contain no credentials, tokens, private user
paths, temporary/UUID paths, or real session data, and all use the dark
appearance that matches the dark landing page. The `screenshot-agent-inbox`
capture is produced with the established `--ui-test-agent-inbox-marketing`
launch flag, which seeds scripted demo tasks; the seeded agent names are all
members of the current first-party detected catalog.

## Findings (no capture changes made in this slice)

1. **`screenshot-markdown.png` — fragile language count.** The fixture README
   in the capture says "Syntax highlighting for 37 languages". That number is
   accurate today (`Pine/Grammars/` contains exactly 37 bundled grammar
   files), but it is a hard-coded count inside a static image: it goes stale
   silently when a grammar is added or removed. At the next refresh, prefer
   durable fixture wording (for example "Syntax highlighting for many
   languages") or re-verify the count from the repository before capturing.
   No README/landing text repeats this number.
2. **`screenshot-agent-inbox.png` — status wording to re-check when the Inbox
   presentation changes.** The capture shows a `Terminated` task in the
   `Completed · Unread` section with a green check, and `Last verified …`
   timestamps on process-observed statuses. Under the process-only
   compatibility model (see
   [agent-compatibility.md](agent-compatibility.md)), process exit is not
   verified success. The capture faithfully shows the shipped 2.x Inbox, so
   it is not misleading today's released UI, but before this screenshot is
   reused in any context that implies verified outcomes (for example, future
   ADE marketing), the Inbox completion presentation and the `Last verified`
   label should be reviewed against that model. Flagged for product decision;
   nothing changed here.
3. **No mismatch between captures and the described UI.** Every feature shown
   is a shipped Pine 2.x capability; no unimplemented ADE screen is mocked.
   When ADE UI ships, these captures must be re-audited and refreshed through
   the established process in the same PR that lands the user-visible change.

## Link and consistency notes

- References in `README.md` and `docs/index.html` (lightbox gallery, Open
  Graph `og:image`/`twitter:image`) resolve to these files; no capture was
  added, removed, or renamed in this slice.
- Install instructions are unaffected; the canonical command remains
  `brew install --cask batonogov/tap/pine-editor` unless #1733 approves a
  migration.
