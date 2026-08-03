# Pine 2.0 release notes

Pine 2.0 makes CLI-agent workflows a first-class part of the native editor
while preserving explicit trust and privacy boundaries.

## Agent compatibility foundation

- Recognizes Pi, Codex, Claude Code, OpenCode, GitHub Copilot CLI, Aider, and
  Gemini CLI by exact executable aliases.
- Keeps unsupported and lookalike executables on the generic terminal path.
- Separates presentation metadata from capability negotiation so detection
  cannot silently grant structured access.
- Ships sanitized, versioned compatibility fixtures and documents notification,
  launch, resume, and lifecycle limitations.

See the [CLI agent compatibility matrix](agent-compatibility.md) for verified
versions, support tiers, signal sources, trust levels, and current limitations.

This document is a release-candidate draft. The final notes will also include
the Agent Inbox, actionable notifications, durable resume, completion briefs,
isolated worktrees, and the final compatibility/security gate results after
those release blockers land.
