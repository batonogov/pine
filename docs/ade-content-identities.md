# ADE content identities (scheme 2)

This implements the capture primitive for #1753. It does not run project checks,
start an agent, publish Ready, or authorize result execution. Those consumers
must obtain their own current binding and grants. A worktree remains an
ownership/routing boundary, not a security sandbox against the same user.

## Capture contract

`AgentVerificationIdentityCapture` accepts a descriptor-backed validated lease,
a locally selected recipe's capture policy, editor preflight, and explicitly
selected canonical tool/configuration files. Its typed result is current,
changed, cancelled, or unavailable with a bounded reason. It performs filesystem
I/O, hashing, and Git inspection off the main thread. Initialization, project
opening, and restoration execute nothing.

Each capture inspects tools/configuration/environment before and after the code
capture. The code capture inspects Git metadata before and after traversing the
actual tree. Tree capture first inventories every included entry, then reads
all payloads, then validates every retained witness through no-follow traversal.
All initial witnesses precede all payload reads; all final witnesses follow them,
so unchanged observation intervals share a common point. Root leases, path
identities, file kind, size, modification time, and change time fence the complete
capture, including already-read files. Contents are always
hashed; metadata is only a race witness, never a replacement for reading bytes.
Changed/unreadable/unsupported/partial captures cannot return a current result.
A later consumer must capture/revalidate again immediately before its operation
or publication; a previous snapshot is not a perpetual freshness token.

Editor owners supply save-encoded buffer bytes and a thread-safe revision
witness. Unsaved bytes must match the actual disk read, and the revision witness
must remain current. Missing editor coverage, missing buffers on disk, or a
mismatch refuses capture. Capture never saves, discards, or substitutes buffers.

## Canonical encoding

Scheme 2 uses SHA-256. Each field is encoded as an unsigned 64-bit big-endian
UTF-8 byte length, its bytes, another unsigned 64-bit big-endian value length,
and its value bytes. Domain tags separate policy, Git metadata, entries, tracked,
untracked, ignored-input, tool, and configuration hashes. Siblings and declared
sets sort by raw UTF-8 bytes. Traversal is deterministic depth-first with a
directory's entry recorded after its children. Ambiguous equivalent directory
names are unsupported rather than silently collapsed.

A filesystem entry commits to its relative path, full mode/file kind, uid/gid,
and regular-file content hash or symlink target bytes. Names and bytes both
matter: editing an already dirty or already untracked file changes its identity
without requiring a status-category change. Renames, deletions, mode changes,
and empty directories are observable. Timestamps are not identity inputs;
restoring mtime cannot conceal a content edit.

The tracked digest includes the selected policy, the HEAD/index/configuration
metadata digest, tracked path set, and actual tracked entries. The untracked
digest includes the policy, untracked path set, and actual untracked entries.
Remaining entries are conservatively hashed as ignored inputs. An absent
tracked file differs from a present empty file. HEAD supports locally observed
SHA-1 or SHA-256 repositories; `nil` means a confirmed unborn branch.

Initialized contained submodules are inspected recursively: their actual HEAD,
index, effective local configuration, tracked contents and untracked inputs all
contribute. Root/index witnesses detect replacement during capture. Missing or
ambiguous submodules cannot produce partial coverage. Unexpected nested
repositories are unsupported.

## Inputs and disposable outputs

The default policy includes all ignored/generated files. A selected recipe can
declare disposable output paths; only untracked/ignored regular files or
directories may be excluded. The policy itself contributes to both code and
environment identities. Outputs may not overlap tracked inputs or declared
required ignored inputs. Required ignored inputs must exist and be traversed.
An arbitrary project or provider suggestion does not select this policy or
supply execution authority.

This is an explicit input/output contract, not universal dependency discovery.
A project without sufficient declarations remains unverifiable. Build outputs
outside the tree need separately owned artifact/result references; this source
identity does not attest an arbitrary executable artifact's provenance.

Symlink target bytes are hashed, and target coverage is separately proven by
no-follow descriptor traversal from the held root. Every endpoint and ancestor
must match an included inventory witness. Case aliases absent from that inventory,
skipped Git control paths, excluded outputs, symlink chains, and any raw `..`
component are conservatively unsupported. A dangling target is supported only
when a no-follow lookup proves a missing edge beneath an included directory
whose inventory witness remains unchanged across the payload phase. Creating
that target changes the captured tree identity; an existing case alias cannot
be mistaken for a missing edge. Lexical normalization
never establishes containment. External links and unsupported objects refuse
coverage. Canonical external tool/configuration files
are a separate explicit selection. Their parent-directory aliases are retained
as validated witnesses through the existing descriptor graph; a symlink leaf
is refused, and nonblocking opens prevent a replaced FIFO from trapping capture.

## Git and environment observation

Git inspection launches fixed system binaries with literal arguments through
the existing bounded runner. `/usr/bin/env -i` removes inherited `GIT_DIR`,
`GIT_WORK_TREE`, `GIT_INDEX_FILE`, tracing and configuration injection. Only fixed
PATH/locale/configuration controls and the selected `DEVELOPER_DIR` are passed.
System/global Git configuration is disabled; repository hooks, fsmonitor,
untracked caching, optional locks, and terminal prompting are disabled.
Git's effective `--show-toplevel` must identify the exact descriptor-backed
worktree before and after inspection; a local `core.worktree` redirect cannot
substitute another tree. Truncated, incomplete or invalid-UTF-8 output cannot
establish an identity.
Inspected HEAD/index/configuration control entries must be regular no-follow
entries. Critical Git metadata and the current loose branch ref retain runtime
change-time witnesses across the payload phase, including missing-entry edges.
Git `include`/`includeIf` configuration is unsupported until the selected include
files can be explicitly scoped and witnessed; capture refuses incomplete coverage.
Selected tool/configuration files likewise retain metadata witnesses between
the before/after observations, so changing and restoring bytes still refuses
the shared capture. These runtime signatures are never persisted or hashed into
the content identity.

The environment identity contains the locally observed OS build and hashes of
actual selected executable bytes, selected configuration bytes, the capture
policy, bound project/worktree paths and root object/mode, and the inherited
environment used by the command owner. Root timestamps/size are excluded so
declared output creation does not invalidate a stable source identity. No `--version`
program is run implicitly. The executable digest identifies an exact binary
version; transitive interpreters/toolchains/configuration must be declared by
the supported recipe. Symlink aliases need prior canonical executable
validation by the binding/grant owner. Missing tool/OS/configuration coverage
cannot prove equivalence.

## Bounds, retention and migration

Defaults limit tree traversal to 100,000 entries, 256 MiB total content, 32 MiB
per file, depth 128, and a cooperative 15-second traversal budget. Git inspection
limits recursive submodules to 32 and retained path data to 8 MiB. The shared
capture has a cooperative 30-second total budget and 512 MiB of observed
tool/configuration/environment data. At most four captures enter each capture
boundary concurrently; excess work is refused rather than queued indefinitely.
Cancellation is checked between entries, reads and bounded Git operations.
A blocked kernel filesystem syscall cannot be forcibly interrupted; the capture
never holds MainActor while waiting for it.

Only bounded hash identities are persisted by consumers. Paths, file/buffer
contents, environment values, credentials, raw Git output and diagnostic output
are not logged or persisted by capture. Hashes are local content commitments,
not encrypted or anonymous source data; no automatic export is introduced.
Inputs and intermediate data are released with the capture.

Scheme 1 and bounded hash-shaped unknown schemes remain identifiable historical
metadata, including reviewed/accepted snapshots. They cannot satisfy current
readiness or re-verification. No old identity is relabelled scheme 2. A fresh
capture and new operation evidence are required. Malformed/unbounded metadata
continues to fail closed through the existing store validation.
