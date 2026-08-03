# Pine 2.0 release notes

Pine 2.0 makes CLI-agent workflows a first-class part of the native editor
while preserving explicit trust and privacy boundaries.

## Agent compatibility foundation

- Recognizes Pi, Codex, Claude Code, OpenCode, GitHub Copilot CLI, Aider,
  Gemini CLI, Amp, Cursor Agent, Goose, Qwen Code, and Crush by exact
  executable aliases.
- Keeps unsupported and lookalike executables on the generic terminal path.
- Separates presentation metadata from capability negotiation so detection
  cannot silently grant structured access.
- Ships sanitized, versioned compatibility fixtures and documents notification,
  launch, resume, and lifecycle limitations.
- Keeps reviewed Amp/Cursor/Goose/Qwen/Crush structured interfaces disabled
  until Pine can authenticate and bind each Pine-launched transport.

See the [CLI agent compatibility matrix](agent-compatibility.md) for verified
versions, support tiers, signal sources, trust levels, and current limitations,
and the [Pine 2.0 agent release matrix](pine-2.0-agent-release-matrix.md) for the
automated gates and manual OS/renderer checklist.

## One Inbox across projects

- Tracks durable agent tasks independently of transient process identifiers.
- Aggregates waiting, failed, unread-completed, working, and historical tasks
  from every open project in one keyboard-accessible window.
- Routes back only to the exact live task generation; stale or historical
  routes fail closed instead of focusing an unrelated terminal.

## Actionable, private notifications

- Delivers low-noise waiting, failure, and completion notifications with
  per-event, per-agent, per-project, and per-task controls.
- Reuses the Inbox routing authority, coalesces duplicates, and never embeds
  prompts, terminal output, tokens, absolute paths, or vendor identifiers.
- Distinguishes verified events from process-only exit detection in both the
  UI and notification copy.

## Recovery and verified review

- Restores durable task metadata across project-window and application
  relaunch without pretending that metadata restoration resumed a vendor
  session.
- Builds completion briefs that separate verified changes, test evidence,
  inference, ambiguity, and agent-reported narrative.
- Preserves unrelated work and staging state during checked undo, checkpoint,
  comparison, and handoff operations, or refuses the operation safely.

## Isolated worktree workflows

- Creates explicit, repository-contained worktrees for parallel tasks without
  silently moving the user's current checkout.
- Supports deterministic comparison and bounded cross-agent handoff while
  retaining Pine's existing Git and provenance safety rules.
- Requires a deliberate user action for agent launch and destructive cleanup.

## Compatibility and release validation

- Keeps the macOS 26.0 deployment target and checks source compatibility with
  the current macOS 27 beta SDK.
- Adds shared offline adapter conformance, hostile-input fuzzing, multi-project
  routing coverage, performance budgets, accessibility logic, and balanced UI
  shards without requiring paid accounts or live model output.
- Documents the required manual macOS 26/27 and Metal/CoreGraphics release
  pass. A `Pending` row in the release matrix remains a release blocker and
  must not be converted to `Pass` from automated evidence alone.

Pine remains a native editor and terminal-first control plane: it does not
embed a vendor chat, parse terminal presentation as trusted lifecycle data,
upload transcripts, or autonomously schedule agents.
