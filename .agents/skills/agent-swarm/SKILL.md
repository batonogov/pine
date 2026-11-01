---
name: agent-swarm
description: Use when distributing a backlog or milestone across subagents. Defines isolated issue worktrees, local-first verification, independent pre-push review, dependency ordering, and parent-owned delivery under AGENTS.md merge/release gates.
---

# Autonomous issue swarm

Read the root `AGENTS.md` first. Its scope, safety, verification, and merge/release gates apply here. A request to distribute a milestone authorizes work on that milestone, not an unrelated backlog or release. Tool/session permissions still take precedence.

## Plan and isolate

1. Read every assigned issue and its comments. Identify acceptance criteria, shared files, dependencies, and required checks. Respect a maintainer-specified first wave; otherwise schedule by dependency and priority. Choose a reasonable plan without waiting for routine approval.
2. One issue = one worker = one dedicated Git worktree and short-lived branch. Fetch current `origin/main`, record the base SHA, and give each worker its exact worktree path and owned scope. A dirty parent checkout is not a reason to delete artifacts or discard another agent's work.
3. Pass an explicit acceptance contract: expected behavior, verification commands, allowed files, dependencies, and stop rules. Workers may investigate, edit, and run local checks. They must not commit before review, publish, merge, force-push, bypass hooks, or modify sibling worktrees.
4. Keep one mutable candidate copy. Reviewers are read-only; fixes return to the same worker/worktree. Never apply a sibling patch twice or cherry-pick a dependency into an uncommitted candidate. Wait for dependencies or use a separately reviewed integration base with an exact recorded SHA.
5. Use a unique absolute `-derivedDataPath` per worker. Serialize UI automation on a shared desktop. Coordinate expensive local runs so contention does not masquerade as a product failure.

## Verify locally, then review

1. Complete the root local verification gate before publishing. For behavior changes, demonstrate regression tests failing against the base and passing with the candidate, and run local lint, build, unit, and UI suites. Documentation-only work uses link, migration, syntax, and diff checks instead of unnecessary app runs. The root’s narrow CI-owned snapshot-bootstrap exception applies when new per-OS references do not yet exist; all other runnable local checks and independent review still precede publishing.
2. Record commands, environment, base/candidate revisions, test counts, and failure artifacts. Compare suspected unrelated failures against the base in an isolated equivalent environment. Diagnose before a bounded retry; repeated blind reruns are not verification.
3. Review the complete candidate diff against its intended base, including staged/unstaged changes and an explicit manifest/content for untracked files. Do not send reviewers only a commit diff while omitting working-tree changes.
4. Run at least three independent fresh-context, read-only reviewers with distinct lenses: (a) correctness and architecture, (b) safety, concurrency, and lifecycle, (c) verification, UX, localization, and OS compatibility. Adapt the questions to the change; documentation still needs policy, safety, and consistency review.
5. Findings must include severity, exact file/line references, a concrete failure sequence or contradiction, and the smallest safe fix. A clean verdict lists checked invariants; restating the diff does not count as review.
6. The parent validates and deduplicates findings. Fix every confirmed P0–P2 issue, add regression coverage where applicable, and repeat review of the revised candidate until clean, within the root’s three-round/no-progress limit for the same unresolved finding. On exhaustion, report a concrete blocker; never waive the review or merge gate. Record intentionally deferred P3 items and reasons. Do not use self-review as independent approval.
7. If reviewers or a required environment are genuinely unavailable, exhaust safe alternatives, state the limitation, and preserve the candidate. Do not pretend the independent review or merge gate has passed.

## Publish and own CI

1. Only after local verification and independent review clears may the parent authorize a Conventional Commit. Review the exact resulting commit before the first push. Keep authorization and the review evidence tied to its head SHA; code changes after review require renewed review and affected checks.
2. The parent pushes and opens an issue-linked PR with verification evidence, review findings/dispositions, and dependency/merge order. Batch local corrections before publishing; avoid making scarce macOS CI runners the first debugger or reviewer.
3. Monitor required checks through completion on the current head. Diagnose failures, fix in scope, and rerun only the affected failed jobs when appropriate. Do not dispatch redundant full workflows, silently skip required CI, or call queued checks complete.
4. Workers never publish or merge. The parent may squash merge an ordinary non-release PR only under the standing authorization and full gate in `AGENTS.md`: current-head independent review, all required CI green, mergeable status, dependencies satisfied, and no hold or narrower user restriction.
5. Release PRs, tags, release publication, and release-workflow actions require separate explicit authorization. Infrastructure/permission changes also require their applicable authorization. A broad milestone assignment is not release permission.
6. After each merge, verify the merged state and reassess dependent branches. Do not automatically rebuild, rebase, or rerun every sibling merely because `main` advanced. Update a candidate when dependencies, conflicts, or branch protection require it; re-review overlapping changes and rerun affected checks. Never amend or force-push to make an update easier.

## Completion and recovery

- Report merged PRs, remaining blockers, verification limits, and follow-up issues. Do not hand the maintainer routine check-running, CI watching, or ordinary eligible merges that the parent is authorized to perform.
- If a post-merge defect is confirmed, reopen or create a linked issue, implement a focused follow-up in a new worktree from current `origin/main`, and repeat local verification, independent review, CI, and the merge gate. Never conceal a skipped gate with a retrospective clean summary.
- Trust current repository and GitHub evidence (`git status`, exact SHAs, `gh pr checks`, `gh pr view`), not a stale worker completion message. A harness parse error is neither proof of failure nor proof that code landed.
- Do not delete worktrees, branches, logs, or review artifacts without the applicable permission. Preserve unrelated work and useful failure evidence.
