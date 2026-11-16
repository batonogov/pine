# Project check recipes — implemented boundary

`AgentProjectCheckRecipe` is an ephemeral, versioned **check-only** recipe
suggestion. It reuses `AgentTaskCheckCommand`; there is no second command or grant
model and no `tasks.json` importer.

The explicit `AgentTaskCheckPlan.selectRecipe` consumer validates the recipe
against the canonical origin project and returns the existing selected-plan
contract. A local override takes precedence over the project suggestion. An
invalid override fails closed rather than running the project's different
commands. Unknown schemas are rejected; no migration is currently implemented.

The recipe identifies the origin project, not a task worktree. Two isolated
tasks can select the same recipe, but cannot share a task-scoped command grant.
Command order, required status, arguments, deadlines, capture declarations and
configuration paths contribute to plan identity. Changed selection content
therefore cannot match a grant for the old plan. Configuration **file contents**
and executable bytes still require the existing
[content-identity capture](ade-content-identities.md) and environment validation;
declarations alone are not proof of the current environment.

Selection neither grants authority nor starts a process. Import, project open
and restoration do not call this explicit selection operation automatically.
Consumers must retain the returned plan and use the existing grant and
pre-spawn validation contracts before owned execution.

This slice does **not** implement a selection UI, durable recipe storage,
prerequisite discovery, preparation, result actions, servers, ports, or the
required-check executor. In particular, setup/result commands must not masquerade
as required checks to obtain authority. Complete preparation → verified result
→ explicit launch remains an integration requirement of #1757, not a capability
established by this projection.
