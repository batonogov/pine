# ADR 0002: Opt-in read-only editor context handoff

- Status: Accepted
- Date: 2026-07-24
- Epic: #933

## Context

Pine launches CLI agents inside its terminal, while the editor holds useful
context such as the open files and caret position. Agents can benefit from that
context, but a generic "bridge" must not silently create command, write,
navigation, replay, or undo authority.

Pine already exposed `PINE_CONTEXT_FILE` to every embedded terminal and wrote a
small JSON file in Application Support. The mechanism was one-way and contained
no source text, but it was implicit rather than permissioned and its schema did
not identify the project.

## Decision

Pine will keep a one-way JSON snapshot as the first handoff protocol. It is:

- disabled by default and enabled explicitly in Settings;
- exposed only to new child processes launched in Pine terminals;
- project-scoped by a SHA-256 identity of the canonical project root;
- limited to relative open-file paths, the active relative path, and caret
  line/column;
- bounded to 256 open files and 4,096 UTF-8 bytes per path;
- written off the project tree in Pine's Application Support directory;
- atomically replaced through directory-relative file descriptors, with
  `O_NOFOLLOW`, owner/type/link checks, `0700` directory permissions, `0600`
  file permissions, and durable file/directory sync;
- deleted immediately when permission is revoked or the project closes.

The terminal receives:

```text
PINE_CONTEXT_FILE=/.../Pine/contexts/<project-hash>.json
PINE_PROJECT_ROOT=/canonical/project/root
```

`PINE_CONTEXT_FILE` is omitted when permission is disabled. Pine removes any
inherited values for both variables before adding the current terminal's scope,
so a nested Pine launch cannot accidentally inherit another project's handoff.

Schema version 1 is:

```json
{
  "schemaVersion": 1,
  "projectIdentity": "<lowercase SHA-256>",
  "openFiles": ["Sources/App.swift"],
  "currentFile": "Sources/App.swift",
  "cursorLine": 42,
  "cursorColumn": 8
}
```

The snapshot contains metadata only. It never contains file contents, selected
text, terminal transcripts, commands, credentials, diagnostics, or provenance
trust claims. Consumers must treat absent or malformed fields as unavailable
and must verify `schemaVersion` and `projectIdentity`.

## Security boundary

This protocol is not an RPC channel. Reading the snapshot cannot:

- mutate editor buffers or files;
- navigate Pine;
- start a process or send terminal input;
- accept, reject, replay, or revert a change;
- establish verified event provenance.

Any future request channel must be a separate ADR and design. Write or command
capabilities require per-action user authorization, authentication,
project/worktree scoping, rate limits, an audit record, and safe cancellation.
Explicit structured events use the provenance envelope from #1204 and do not
become trusted merely because a process can read this context file.

The file permission boundary protects against other OS users and accidental
path traversal. It does not claim to sandbox a malicious process running as the
same macOS user; that process can already read files the user can read.

## Consequences

- Existing integrations must ask users to enable the setting and start a new
  terminal before reading `PINE_CONTEXT_FILE`.
- Revocation is deterministic: pending writes are cancelled and the published
  snapshot is unlinked.
- The versioned, bounded schema can grow compatibly without creating a
  bidirectional control plane.
- Selection/visible-range metadata may be added in a future schema version
  after Pine has stable pane-scoped editor-state models. Source text remains
  out of scope.
