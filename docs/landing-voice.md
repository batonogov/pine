# Landing copy — #1799

Voice rule: explain the work first, use short confident sentences, and let a
little irony clarify openness or the difference between a claim and evidence.
Never joke about permissions, errors, privacy, or data loss.

## Directions considered

- **Calm confidence (selected):** “Run the agent. Review the changes. Your call.”
  Concrete today, lightly skeptical about “done” in the future section.
- **Open-source invitation:** “Read the code. Make it yours.” Useful in the footer,
  too narrow to explain the whole product.
- **Evidence first:** “A confident ‘done’ is still a claim.” Relevant to Pine 3,
  but misleading as the lead for the downloadable editor.

## Small before/after set

| Before | After | Why |
| --- | --- | --- |
| One continuous loop. From agent command to code review. | Run the agent. Review the changes. Your call. | Make the workflow and the user's role concrete. |
| …so you always know what the agent is doing… | See agent activity and review the changes without switching workspaces. | Remove omniscience; describe the visible benefit. |
| …not a browser pretending to be one. | Familiar Mac controls, no browser runtime. | Explain the native implementation without mocking other tools. |
| The terminal stays open. Evidence stays attached. You stay in control. | The Pine 3 goal: “done” should come with evidence, not just confidence. | Put restrained irony in explicitly future-facing copy. |
| Install Pine in 10 seconds. | Install Pine. Get back to your project. | Remove an unmeasured installation-time claim. |
| Pine is open source and built for macOS developers… | Open source. Yes, you can change it. Use, modify, and share Pine under MIT; keep the copyright and license notices. | Invite participation while preserving the license condition. |

Replaced eight existing strings in the HTML fallback and all nine landing
catalogs; added no landing sections, controls, styles, or dependencies. Locales
adapt the meaning rather than English wordplay.

## Claim boundaries

The hero still explains the downloadable native editor and real terminal.
Pine-observed checks, independent review, and Ready results stay future Pine 3
direction; the revised quote says so itself. The interactive concept remains a
Russian-language simulation, not the downloadable app.

The [README](../README.md), SEO/social descriptions, and in-app Help do not need
the same jokes: no new product capability or positioning is introduced here.
The landing's agent-feature description and matching README feature bullet
also narrow the old “verified events” wording: current-source detected-agent
notifications report process termination, not input waiting, success, or checked
results. Released binaries may differ; inspecting current source is not evidence
of historical behavior in the v2.12.4 download. This describes the catalog's
`processTerminationOnly` accuracy policy, not Pine-observed checks, independent
review, or Ready. It does not change the legacy verified undo-preview contract.
MIT wording follows the [license](../LICENSE), including retained notices, and
does not replace its full terms or third-party licenses. The canonical Homebrew
command, release links, macOS requirements, and existing demo limitations are
unchanged. Help, its indexes, README build commands, and GitHub About are outside
this candidate. Broader public-claim auditing remains with
[#1730](https://github.com/batonogov/pine/issues/1730).
