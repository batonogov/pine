---
name: agent-swarm
description: Use when distributing a backlog or milestone across subagents in this repository — "распредели issues по агентам", "orchestrate this milestone", "run a swarm", or any handoff where one worker owns one issue in its own worktree. Carries the issue-by-issue authorization flow, the independent fresh-context review gate every candidate must clear before its first push, and the narrow rules governing who may merge.
---

# Maintainer-directed issue swarm

These three sections used to sit in `CLAUDE.md`. They are a procedure rather
than standing context, so they load when a swarm is actually being run.

When the maintainer asks the parent agent to distribute a backlog across
subagents, use this stricter issue-by-issue flow:

1. **The issue is the unit of authorization.** Never start implementation
   without an existing issue. One worker owns exactly one issue at a time in
   one isolated worktree and short-lived branch. Do not mix opportunistic fixes
   from another issue into its diff. If the maintainer names a required first
   wave, schedule those issues before optional work.
2. **Start from current `origin/main`.** Fetch before creating a worktree and
   record the exact base SHA. When `main` advances, especially after a sibling
   or release merge, preserve the complete local diff with
   `git stash push --include-untracked -m <unique-issue-and-base>`, record and
   verify the resulting stash commit OID, update the uncommitted branch only
   with `git merge --ff-only origin/main`, and restore with
   `git stash apply <OID>`. Never pop or drop the backup until the moved diff is
   validated; never use `reset --hard`, forced checkout, or `clean`. Stop on a
   non-fast-forward or conflict. Prove that merged commits occur exactly once,
   re-review overlapping files, and rerun the affected tests after the move.
3. **Review before spending CI.** Risky or cross-cutting work first reports a
   design and test plan, then a production-diff checkpoint. Every
   implementation, regardless of risk, reports the complete diff after local
   verification and passes the independent review gate below before commit,
   push, or PR. The parent/orchestrator requests polishing before expensive
   macOS or UI runners test the candidate.
4. **Keep concurrent Xcode work isolated.** Give every issue a unique
   `-derivedDataPath` under `/private/tmp`; never share DerivedData between
   workers. Record the exact macOS, Xcode, SDK version, commands, test counts,
   and result-bundle path. A code failure gets diagnosed and reviewed before a
   bounded retry; do not hide a failure with repeated blind reruns.
5. **Verification is evidence, not a summary.** Always run `git diff --check`.
   Run every applicable targeted check and state each non-applicable check with
   a reason: SwiftLint for Swift/code changes, targeted tests for behavioral
   changes, and the existing full pre-PR build for code PRs. Add broader suites,
   UI tests, security/race tests, or renderer checks when the issue requires
   them. Report unrelated failures separately, but never call a PR merge-ready
   until every required GitHub check is green.
6. **Publish in dependency order.** Only after the parent review clears may the
   worker make a Conventional Commit. The parent then performs a final commit
   review, pushes, opens the issue-linked PR, states the merge order, and watches
   CI. A worker subagent never merges its own PR.
7. **Merge authorization is narrow.** By default only the maintainer merges.
   If the maintainer explicitly authorizes the parent/orchestrator to merge
   working PRs, the authorization must identify the exact PR numbers and
   current head SHAs; a batch is an immutable enumeration of those exact
   `(PR number, head SHA)` pairs. Revalidate them immediately before merge.
   Only non-release PRs that remain mergeable, have a clean review gate, and
   have every required check green may merge. Red or pending PRs are never
   merged. Release actions require separate, exact authorization covering each
   requested operation: Release Please PR merge; tag create, update, delete,
   or push; and release-workflow edit, dispatch, rerun, or cancellation. After
   any authorized Release Please PR merge, regardless of actor, treat the
   resulting release commit as the new mandatory base for all active issue
   branches.

## Independent review gate

Every implementation must pass an independent, fresh-context review before
its first push and before a PR is opened. This keeps expensive macOS and UI
runners from testing a candidate that has not cleared adversarial review.
Green CI remains necessary, but it does not replace that review.

1. **Review the local candidate diff before push.** Once implementation and
   regression tests are stable, review the complete local diff against its
   intended base (`main...HEAD`, plus any staged or unstaged changes). Keep the
   original worktree path as the single mutable copy, include
   `git status --short`, and represent every untracked file explicitly with a
   manifest plus a `git diff --no-index /dev/null <file>` patch (or an
   equivalent content-complete artifact). Review and fix workers must use that
   same worktree until commit. Run at least three read-only reviewer subagents
   with distinct lenses: (a)
   correctness and architecture, (b) concurrency, security, and lifecycle
   races, and (c) tests, UX, localization, and OS compatibility. Reviewers
   must read the issue acceptance criteria and must not edit files.
2. **Demand actionable findings.** Each finding includes severity, exact
   file/line references, a concrete failure sequence or reproduction, and the
   smallest safe fix. A clean review explicitly lists the invariants checked;
   a summary that merely restates the diff does not count.
3. **Synthesize and verify.** The parent agent deduplicates findings, validates
   them against the code, and adds a regression test before or with each fix.
   All confirmed P0, P1, and P2 findings must be resolved before merge. Record
   low-risk coverage gaps or P3 findings in the PR or a follow-up issue when
   they are intentionally deferred.
4. **Fix on the same local branch.** In the maintainer-directed flow, keep the
   candidate uncommitted until review clears. If the candidate was already
   committed under a different flow, add follow-up commits; never amend or
   force-push. Repeat the independent review/fix loop until reviewers return no
   unresolved P0-P2 findings, then rerun the relevant local checks.
5. **Push and open the PR only after review clears.** Summarize reviewer
   angles, findings, dispositions, and local verification in the PR body.
   Run the full required CI once the PR exists. An agent with explicit merge
   authorization must not invoke merge until the pre-push review gate remains
   clean and every required CI check is green.
6. **Recover visibly from a premature merge.** If review was skipped before
   merge, or a post-merge review finds a P0-P2 defect, reopen the source issue,
   create a short-lived follow-up branch from current `main`, add regression
   tests and fixes, repeat review plus CI, and close the issue only after the
   follow-up PR is green and merged.

## Milestone orchestration with subagents

For a milestone with multiple issues, the maintainer (or a parent agent) orchestrates implementation across subagents instead of doing all the work in one session. Used for parallelizable issues, large features, or when strict adversarial review is wanted. The full loop runs inside the agent; the maintainer merges by default, or may explicitly authorize the parent/orchestrator to merge under the narrow gate above.

Flow:
1. **Scope first.** Read every issue in the milestone end-to-end, identify shared files, and note dependencies (`blocked-by`, or an explicit "depends on #X" in the body). Order implementation and merge accordingly.
2. **One issue = one worker = one candidate branch.** Delegate each issue to a worker subagent in an isolated worktree (`worktree: true`). Each worker creates its own local branch, implements the candidate, runs local verification, and reports the complete working diff for review without committing, pushing, or opening a PR. Pass each worker explicit permissions in the task and an `acceptance` contract with `verify` commands and `stopRules` (notably: never commit before review clears, never push, never open a PR, never merge, never force-push, never amend).
3. **Respect cross-issue boundaries.** Tell each worker exactly which files/branches it may touch so sibling PRs stay mergeable (e.g. add a dedicated accumulator field per branch instead of repurposing a shared one). When an issue depends on siblings not yet merged, wait for them to land or have the parent create a separately reviewed integration base with a recorded SHA and exactly-once proof. Workers do not merge or cherry-pick sibling branches into an uncommitted candidate.
4. **Strict review from fresh context before push.** Run fresh-context `reviewer` subagents with distinct angles against each complete local candidate diff. Reviewers are read-only — they must not edit.
5. **Fix before opening the PR.** Synthesize reviewer findings and hand them to a fix-worker that uses the **existing local candidate branch** and working diff. Keep fixes uncommitted until the review gate is clean. Never amend, force-push, or open a new branch for fixes. Repeat the review/fix loop until reviewers return a clean verdict (typically ~2 rounds), then create the Conventional Commit.
6. **Publish and verify after review.** Only now does the parent/orchestrator push each reviewed branch and open its PR. Confirm every PR is `MERGEABLE` and **fully green** — every required CI check passing, no exceptions. Pending checks must be explicitly noted. There is no "red but mergeable" state: branch protection blocks the merge button on any failing check, so a red PR is not ready regardless of why it failed. State the merge order.
7. **Workers never publish or merge.** After review clears, the
   parent/orchestrator opens and reports the PR. It merges only when the
   maintainer has explicitly delegated that authority and all review,
   dependency-order, and green-CI requirements above are satisfied; otherwise
   the maintainer merges.

Operational notes:
- Worktree isolation requires a clean main tree — remove stray artifacts (e.g. a `reviews/` folder written by reviewers) before launching new worktree runs.
- "needs attention" control signals from a finished run are stale noise; trust `gh pr checks` / `gh pr view` as ground truth.
- Acceptance-gate / parse-report errors in the subagent harness do not mean the work failed — check the PR and CI; the code usually landed.
