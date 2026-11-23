# Project recipes — implemented boundary

#1757's recipe contract extends the
[check-only recipe](ade-project-check-recipes.md) with environment
prerequisites, setup actions, and named result actions, plus the task-side
preparation and result-action lifecycle models. Like the check-only kind,
these are value contracts: importing, opening, restoring, proposing, or
selecting a recipe executes nothing and grants nothing. Setup and result
commands reuse the shared `AgentTaskCheckCommand`/`AgentTaskCheckPlan`
contract (#1753/#1754); there is no second command or execution policy.

## Contract (`AgentProjectRecipe`, scheme 1)

- Project identity (`canonicalProjectPath`), supported environment
  prerequisites (canonical tool executable references, never version claims),
  setup actions, the embedded check contract, named result actions, and
  secret **references** keyed by command id. A `AgentProjectSecretReference`
  carries an environment variable name only; values are resolved at launch
  time by the environment owner (#1723) and never enter a recipe, plan,
  grant, or log.
- Origin is not recipe content. Selection distinguishes checked-in
  suggestions, agent proposals, and locally selected configuration by tier:
  **local selection, then agent proposal, then checked-in suggestion**. A
  chosen recipe that is invalid, an unsupported scheme, or for another
  project fails closed and never falls back to a different tier's commands.
  A locally approved agent proposal is remembered by storing the same
  content in the local tier; persistence is the metadata store's concern.
- The fingerprint is content identity (scheme, kind, project, prerequisites,
  setup command fingerprints, embedded check fingerprint, result
  fingerprints, secret references), independent of origin and tier. Unknown
  future schemes are rejected; **no automatic migration is implemented**.
- The check plan derives from the specific selected recipe version through
  the existing `AgentTaskCheckPlan.selectRecipe` consumer, so a changed
  recipe fingerprint cannot match a grant for the old plan. Configuration
  contents and executable bytes still require the existing
  [content-identity capture](ade-content-identities.md) and environment
  validation.

## Preparation (`AgentProjectPreparation`)

States: `preparing`, `usable`, `failed`, `unavailable`, `cancelled`. Partial
setup never appears usable: `usable` requires every setup action complete
and every prerequisite resolved in the environment. Setup is all-or-nothing
(every setup action is required). A failed setup action and an unavailable
prerequisite are explained by named reasons. Retries are bounded
(3 re-runs); recovery resumes at the first failure — successful setup stays
completed, and the executor must not assume a re-run failed action is
idempotent. An unavailable prerequisite is not retried: the user must
install or reselect the tool, which is a fresh environment. A changed recipe
fingerprint invalidates any prior preparation for the new version.

## Result action lifecycle (`AgentTaskResultActionState`)

A result action is typed: build artifact, owned loopback server endpoint,
one-shot CLI example, or document reference. A suggested URL or path is not
evidence of a running result; readiness requires Pine-observed ownership.

The state binds the action to the current candidate and environment
identity (`AgentVerificationIdentitySnapshot` from #1753's capture
contract), the recipe fingerprint, the named result action, and the owning
task. Two actions for different tasks or snapshots are never interchangeable
even when they share a port, artifact path, or recipe.

Preparation and build are separate from execution: a state starts at
`prepared` and only an explicit launch runs a result. Phases: `prepared`,
`starting`, `ready`, `failed`, `portConflict`, `stopping`, `stopped`,
`cancelled`, `stale`.

- Ownership records the Pine-observed process group; stop and relaunch apply
  only to it. The model has no primitive to affect other processes.
- A port conflict means the endpoint is occupied by a non-owned process:
  the occupant is never killed and the state stays truthful; the user
  resolves it, then the task may relaunch.
- A long-running ready result reuses its live process on a new launch
  request; a one-shot CLI ready state re-runs the example on request.
- Cancellation and stops release ownership but preserve the binding and
  code state. An unexpected termination of an owned process is a truthful
  failure, not a stop.
- A candidate or environment change while a result is current makes it
  `stale` (a live development preview mutates without new evidence). A
  stale state is not relaunched against the old snapshot; the executor
  rebinds a fresh state to the new snapshot.
- Verbs map to output kinds: server → Open preview, artifact → Run
  application, CLI → Run example, document → View changes. Non-runnable
  changes keep View changes rather than a fictional launch action;
  localization is the presentation layer's concern (#1725).
- #1725's production controller executes declared preparation and the
  one-shot CLI example through `UserTaskRunner` with literal argv, bounded
  output/supervision and process-group ownership. Selection, preparation and
  launch are separate explicit actions. Launch requires current Ready evidence,
  usable preparation for the same recipe, a current matching runtime grant,
  and recaptured code/tool/environment identity with the exact child
  environment immediately before spawn. Server and artifact execution remain
  extension points; their model states do not pretend to run.

## Implemented kind vs extension points

Implemented vertical slice — `swiftPackage` (model and test level):
recognition of `Package.swift` plus exactly one `Sources/<target>/main.swift`
executable target; setup `swift package resolve`; required check
`swift build` plus optional `swift test` when a `Tests/` directory exists;
named result action `run-example` (`swift run <target>`, one-shot CLI).
Ambiguous, library-only, or manifest-less trees are not recognized. The
second isolated task selects the same origin recipe and derives identical
setup, check, and result commands without reconstruction; task-scoped grants
still do not transfer.

Extension points (lifecycle model exists, recipe kinds not implemented):
static web/server previews (owned loopback endpoint, port-conflict rules),
native application artifacts, document references, and the Go/Python/DevOps
scenarios from the CLI capability audit. In particular, Python venv recipes
are blocked by the shared command contract's absolute-executable requirement
(worktree-relative `.venv` executables); extending the command contract is
#1754's, not this slice's.

## Not implemented here

No verification-check executor, worktree creator, universal build discovery,
durable recipe storage, version migration, or remote environments is added here.
Verification checks follow #1754's executor against #1723's environment binding;
#1725 adds bounded recipe setup, the explicit one-shot CLI result driver, and
its task-local presentation through the existing Agent Inbox.
