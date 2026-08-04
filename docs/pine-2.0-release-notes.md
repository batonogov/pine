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

This document is a release-candidate draft. The final notes will also include
the Agent Inbox, actionable notifications, durable resume, completion briefs,
isolated worktrees, and the final compatibility/security gate results after
those release blockers land.
