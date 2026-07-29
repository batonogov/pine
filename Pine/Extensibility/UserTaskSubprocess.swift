//
//  UserTaskSubprocess.swift
//  Pine
//
//  POSIX process-group wrapper for user tasks. A dedicated process group lets
//  cancellation and timeout terminate the shell together with ordinary
//  descendants, while waitpid always reaps Pine's direct child. Descendants
//  that setsid/double-fork between identity snapshots are a documented
//  best-effort case; no public Darwin API provides an atomic process-tree kill.
//

import Darwin
import Foundation
import os

nonisolated final class UserTaskSubprocess: @unchecked Sendable {
    private static let reaperQueue = DispatchQueue(
        label: "com.pine.user-task-reaper",
        qos: .utility,
        attributes: .concurrent
    )

    let processGroup: UserTaskProcessGroup
    let standardInput: FileHandle
    let standardOutput: FileHandle
    let standardError: FileHandle

    private let processID: pid_t

    init(
        executableURL: URL,
        command: String,
        workingDirectory: URL?
    ) throws {
        let pipes = SpawnPipes(
            stdin: Pipe(),
            stdout: Pipe(),
            stderr: Pipe()
        )
        var childProcessID: pid_t = 0

        do {
            try Self.markAllCloseOnExec(pipes)
            try Self.spawn(
                processID: &childProcessID,
                executableURL: executableURL,
                command: command,
                workingDirectory: workingDirectory,
                pipes: pipes
            )
        } catch {
            Self.closeAll(pipes)
            throw error
        }

        pipes.stdin.fileHandleForReading.closeFile()
        pipes.stdout.fileHandleForWriting.closeFile()
        pipes.stderr.fileHandleForWriting.closeFile()

        processID = childProcessID
        processGroup = UserTaskProcessGroup(identifier: childProcessID)
        standardInput = pipes.stdin.fileHandleForWriting
        standardOutput = pipes.stdout.fileHandleForReading
        standardError = pipes.stderr.fileHandleForReading
    }

    /// Waits for and reaps Pine's direct shell child.
    ///
    /// Signal exits use the signal number, matching Foundation `Process`'s
    /// `terminationStatus` convention.
    func waitForExit() -> Int32 {
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = Darwin.waitpid(processID, &status, 0)
        } while result == -1 && errno == EINTR

        guard result == processID else { return -1 }
        return Self.exitCode(from: status)
    }

    /// Non-blocking wait used by the runner's bounded lifecycle loop.
    ///
    /// `waitid(..., WNOWAIT)` observes a completed child without reaping it.
    /// The caller can therefore take one final process-tree snapshot while the
    /// unreaped PID still reserves its original process-group identifier. Only
    /// after that snapshot do we call `waitpid` to collect the exit status.
    func pollExit(
        beforeReaping: () -> Void = {}
    ) -> UserTaskProcessExitPoll {
        var info = siginfo_t()
        var observationResult: Int32
        repeat {
            observationResult = Darwin.waitid(
                P_PID,
                id_t(processID),
                &info,
                WEXITED | WNOHANG | WNOWAIT
            )
        } while observationResult == -1 && errno == EINTR

        if observationResult == -1 {
            return .waitFailed(errno)
        }
        guard info.si_pid != 0 else {
            return .running
        }

        processGroup.captureKnownMembersBeforeReaping()
        beforeReaping()

        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = Darwin.waitpid(processID, &status, WNOHANG)
        } while result == -1 && errno == EINTR

        if result == processID {
            return .exited(Self.exitCode(from: status))
        }
        if result == 0 {
            return .running
        }
        return .waitFailed(errno)
    }

    /// Transfers a still-running direct child to a dedicated blocking reaper
    /// after the runner's hard lifecycle deadline. No other waiter may touch
    /// this pid after handoff.
    func reapInBackground() {
        let processID = self.processID
        Self.reaperQueue.async {
            var status: Int32 = 0
            var result: pid_t
            repeat {
                result = Darwin.waitpid(processID, &status, 0)
            } while result == -1 && errno == EINTR

            if result == -1, errno != ECHILD {
                Logger.task.error(
                    "Background task reaper failed for pid \(processID): errno \(errno)"
                )
            }
        }
    }

    private static func spawn(
        processID: inout pid_t,
        executableURL: URL,
        command: String,
        workingDirectory: URL?,
        pipes: SpawnPipes
    ) throws {
        var fileActions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let stdinRead = pipes.stdin.fileHandleForReading.fileDescriptor
        let stdinWrite = pipes.stdin.fileHandleForWriting.fileDescriptor
        let stdoutRead = pipes.stdout.fileHandleForReading.fileDescriptor
        let stdoutWrite = pipes.stdout.fileHandleForWriting.fileDescriptor
        let stderrRead = pipes.stderr.fileHandleForReading.fileDescriptor
        let stderrWrite = pipes.stderr.fileHandleForWriting.fileDescriptor

        try check(posix_spawn_file_actions_adddup2(
            &fileActions,
            stdinRead,
            STDIN_FILENO
        ))
        try check(posix_spawn_file_actions_adddup2(
            &fileActions,
            stdoutWrite,
            STDOUT_FILENO
        ))
        try check(posix_spawn_file_actions_adddup2(
            &fileActions,
            stderrWrite,
            STDERR_FILENO
        ))

        for descriptor in [
            stdinRead,
            stdinWrite,
            stdoutRead,
            stdoutWrite,
            stderrRead,
            stderrWrite,
        ] where descriptor > STDERR_FILENO {
            try check(posix_spawn_file_actions_addclose(
                &fileActions,
                descriptor
            ))
        }

        if let workingDirectory {
            try workingDirectory.path.withCString { path in
                try check(posix_spawn_file_actions_addchdir(
                    &fileActions,
                    path
                ))
            }
        }

        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setpgroup(&attributes, 0))

        // Pine may have ignored or blocked signals on another subsystem's
        // thread. The child starts with an empty mask and shell-appropriate
        // defaults instead of inheriting that ambient process state.
        var emptySignalMask = sigset_t()
        try checkErrno(sigemptyset(&emptySignalMask))
        try check(posix_spawnattr_setsigmask(
            &attributes,
            &emptySignalMask
        ))
        var defaultSignals = sigset_t()
        try checkErrno(sigemptyset(&defaultSignals))
        for signalValue in [
            SIGHUP,
            SIGINT,
            SIGQUIT,
            SIGPIPE,
            SIGTERM,
            SIGCHLD,
        ] {
            try checkErrno(sigaddset(&defaultSignals, signalValue))
        }
        try check(posix_spawnattr_setsigdefault(
            &attributes,
            &defaultSignals
        ))

        // CLOEXEC_DEFAULT closes every ambient Pine descriptor in the child.
        // The three dup2 actions above are the complete inheritance allowlist:
        // stdin, stdout, and stderr only.
        let spawnFlags =
            Int16(POSIX_SPAWN_SETPGROUP)
            | Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
            | Int16(POSIX_SPAWN_SETSIGMASK)
            | Int16(POSIX_SPAWN_SETSIGDEF)
        try check(posix_spawnattr_setflags(
            &attributes,
            spawnFlags
        ))

        let executablePath = executableURL.path
        let arguments = [executablePath, "-c", command]
        var argumentPointers: [UnsafeMutablePointer<CChar>?] = []
        defer {
            for pointer in argumentPointers {
                free(pointer)
            }
        }
        for argument in arguments {
            guard let pointer = strdup(argument) else {
                throw posixError(ENOMEM)
            }
            argumentPointers.append(pointer)
        }
        argumentPointers.append(nil)

        let environment = ProcessInfo.processInfo.environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        var environmentPointers: [UnsafeMutablePointer<CChar>?] = []
        defer {
            for pointer in environmentPointers {
                free(pointer)
            }
        }
        for entry in environment {
            guard let pointer = strdup(entry) else {
                throw posixError(ENOMEM)
            }
            environmentPointers.append(pointer)
        }
        environmentPointers.append(nil)

        let spawnResult = argumentPointers.withUnsafeMutableBufferPointer { buffer in
            environmentPointers.withUnsafeMutableBufferPointer { environmentBuffer in
                executablePath.withCString { executablePathPointer in
                    posix_spawn(
                        &processID,
                        executablePathPointer,
                        &fileActions,
                        &attributes,
                        buffer.baseAddress,
                        environmentBuffer.baseAddress
                    )
                }
            }
        }
        try check(spawnResult)
    }

    private static func check(_ result: Int32) throws {
        guard result == 0 else { throw posixError(result) }
    }

    private static func checkErrno(_ result: Int32) throws {
        guard result == 0 else { throw posixError(errno) }
    }

    private static func markAllCloseOnExec(_ pipes: SpawnPipes) throws {
        for descriptor in [
            pipes.stdin.fileHandleForReading.fileDescriptor,
            pipes.stdin.fileHandleForWriting.fileDescriptor,
            pipes.stdout.fileHandleForReading.fileDescriptor,
            pipes.stdout.fileHandleForWriting.fileDescriptor,
            pipes.stderr.fileHandleForReading.fileDescriptor,
            pipes.stderr.fileHandleForWriting.fileDescriptor,
        ] {
            let flags = Darwin.fcntl(descriptor, F_GETFD)
            guard flags != -1 else { throw posixError(errno) }
            guard Darwin.fcntl(
                descriptor,
                F_SETFD,
                flags | FD_CLOEXEC
            ) != -1 else {
                throw posixError(errno)
            }
        }
    }

    private static func exitCode(from status: Int32) -> Int32 {
        let terminatingSignal = status & 0x7f
        if terminatingSignal == 0 {
            return (status >> 8) & 0xff
        }
        return terminatingSignal
    }

    private static func posixError(_ code: Int32) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: nil
        )
    }

    private static func closeAll(_ pipes: SpawnPipes) {
        pipes.stdin.fileHandleForReading.closeFile()
        pipes.stdin.fileHandleForWriting.closeFile()
        pipes.stdout.fileHandleForReading.closeFile()
        pipes.stdout.fileHandleForWriting.closeFile()
        pipes.stderr.fileHandleForReading.closeFile()
        pipes.stderr.fileHandleForWriting.closeFile()
    }

    private struct SpawnPipes {
        let stdin: Pipe
        let stdout: Pipe
        let stderr: Pipe
    }
}

nonisolated enum UserTaskProcessExitPoll: Sendable, Equatable {
    case running
    case exited(Int32)
    case waitFailed(Int32)
}

/// Owns termination of one isolated POSIX process group.
///
/// TERM is followed by a bounded KILL fallback. The completion group lets the
/// runner wait until cleanup finishes before it reports the task as complete.
nonisolated final class UserTaskProcessGroup: @unchecked Sendable {
    private static let lifecycleQueue = DispatchQueue(
        label: "com.pine.user-task-process-group",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private static let termGracePeriod: TimeInterval = 0.25
    private static let killWaitPeriod: TimeInterval = 1.0
    private static let completionWaitPeriod: TimeInterval = 1.5
    private static let pollIntervalMicroseconds: useconds_t = 10_000

    let identifier: pid_t

    private let lock = NSLock()
    private let terminationCompletion = DispatchGroup()
    private let leader: UserTaskProcessIdentity?
    private var knownMembers: [pid_t: UserTaskProcessIdentity] = [:]
    private var terminationRequested = false
    private var terminationFinished = false
    private var terminationSucceeded = true

    init(identifier: pid_t) {
        precondition(identifier > 1)
        self.identifier = identifier
        leader = UserTaskProcessInspector.identity(for: identifier)
        if let leader {
            knownMembers[leader.processID] = leader
        }
        captureKnownMembers()
    }

    var isAlive: Bool {
        Self.isProcessGroupAlive(identifier)
    }

    var terminationWasRequested: Bool {
        lock.withLock { terminationRequested }
    }

    /// Records identity-qualified members while at least one previously known
    /// process still anchors this group. This prevents a reused pgid from
    /// becoming a new signalling target after Pine's original group exits.
    func captureKnownMembers() {
        captureKnownMembers(unreapedLeaderWasObserved: false)
    }

    /// Records the last group snapshot after `waitid(..., WNOWAIT)` has
    /// observed the direct shell's exit but before `waitpid` reaps it.
    ///
    /// Darwin can reject `getpgid` for a zombie, so the usual live-anchor
    /// check is not sufficient here. The still-unreaped pid cannot yet be
    /// reused, which makes its original pgid a safe one-shot enumeration
    /// anchor for retaining live background-member identities.
    fileprivate func captureKnownMembersBeforeReaping() {
        captureKnownMembers(unreapedLeaderWasObserved: true)
    }

    private func captureKnownMembers(
        unreapedLeaderWasObserved: Bool
    ) {
        let anchors = lock.withLock {
            Array(knownMembers.values)
        }
        let hasLiveAnchor =
            unreapedLeaderWasObserved
            || (leader.map { Self.isCurrentGroupMember($0, group: identifier) } ?? false)
            || anchors.contains {
                Self.isCurrentGroupMember($0, group: identifier)
            }
        guard hasLiveAnchor,
              case .known(let processIDs) =
                UserTaskProcessInspector.processIDs(inGroup: identifier) else {
            return
        }

        let identities: [UserTaskProcessIdentity] =
            processIDs.compactMap { processID in
            guard Darwin.getpgid(processID) == identifier else { return nil }
            return UserTaskProcessInspector.identity(for: processID)
        }
        lock.withLock {
            for identity in identities {
                knownMembers[identity.processID] = identity
            }
            knownMembers = knownMembers.filter {
                UserTaskProcessInspector.identity(for: $0.key) == $0.value
            }
        }
    }

    func requestTermination(
        beforeMemberCapture: (@Sendable () -> Void)? = nil
    ) {
        // Publish the request and its pending completion atomically before
        // process inspection. libproc can be slow under system load; a waiter
        // must never mistake that inspection window for "not requested".
        let shouldStart = lock.withLock {
            guard !terminationRequested else { return false }
            terminationRequested = true
            terminationCompletion.enter()
            return true
        }
        guard shouldStart else { return }

        // Capture ordinary children before TERM can turn the direct shell into
        // a zombie that another thread promptly reaps. This preserves an
        // identity-qualified anchor for the later KILL fallback.
        beforeMemberCapture?()
        captureKnownMembers()

        // Deliver the first TERM synchronously. App termination may only have
        // a short shared deadline, so merely enqueueing the first signal would
        // leave a queued task with no cleanup request at all.
        _ = signalIdentitySafeGroup(SIGTERM)

        Self.lifecycleQueue.async {
            let succeeded = self.finishTermination()
            self.lock.withLock {
                self.terminationSucceeded = succeeded
                self.terminationFinished = true
            }
            self.terminationCompletion.leave()
        }
    }

    /// Waits only when termination was requested, returning whether the whole
    /// process group disappeared within the bounded TERM-to-KILL sequence.
    func waitForRequestedTermination() -> Bool {
        waitForRequestedTermination(
            completionTimeout: Self.completionWaitPeriod
        )
    }

    func waitForRequestedTermination(
        completionTimeout: TimeInterval
    ) -> Bool {
        let state = lock.withLock {
            (
                requested: terminationRequested,
                finished: terminationFinished,
                succeeded: terminationSucceeded
            )
        }
        guard state.requested else { return true }
        if state.finished {
            return state.succeeded
        }
        // The direct shell may have exited and been reaped before the
        // asynchronous lifecycle continuation gets scheduled. In that case
        // there is no process group left to clean up, so queue contention
        // must not turn successful termination into a false diagnostic.
        guard Self.isProcessGroupAlive(identifier) else { return true }
        guard terminationCompletion.wait(
            timeout: .now() + max(completionTimeout, 0)
        ) == .success else {
            return !Self.isProcessGroupAlive(identifier)
        }
        return lock.withLock { terminationSucceeded }
    }

    private func finishTermination() -> Bool {
        if Self.isProcessGroupAlive(identifier) {
            Self.waitUntilGone(
                identifier,
                timeout: Self.termGracePeriod
            )
        }

        if Self.isProcessGroupAlive(identifier) {
            captureKnownMembers()
            _ = signalIdentitySafeGroup(SIGKILL)
            Self.waitUntilGone(
                identifier,
                timeout: Self.killWaitPeriod
            )
        }

        // Disappearance is the cleanup contract. A signal syscall can race a
        // natural exit and report a transient failure even though there is no
        // process left to clean up.
        let succeeded = !Self.isProcessGroupAlive(identifier)
        if !succeeded {
            Logger.task.error(
                "Task process group \(self.identifier) survived SIGKILL"
            )
        }
        return succeeded
    }

    /// Signals the negative pgid only while a current identity proves it is
    /// still Pine's original group. When inspection is unknown, signal known
    /// identities individually rather than risking an unrelated reused pgid.
    private func signalIdentitySafeGroup(_ signalValue: Int32) -> Bool {
        let identities = lock.withLock { Array(knownMembers.values) }
        let hasCurrentAnchor = identities.contains {
            Self.isCurrentGroupMember($0, group: identifier)
        }
        guard hasCurrentAnchor else {
            return signalKnownMembers(signalValue, identities: identities)
        }

        if Darwin.kill(-identifier, signalValue) == 0 || errno == ESRCH {
            return true
        }
        Logger.task.error(
            "Failed to signal task process group \(self.identifier): errno \(errno)"
        )
        return false
    }

    private func signalKnownMembers(
        _ signalValue: Int32,
        identities: [UserTaskProcessIdentity]
    ) -> Bool {
        var succeeded = true
        for identity in identities
        where UserTaskProcessInspector.identity(for: identity.processID) == identity {
            if Darwin.kill(identity.processID, signalValue) != 0,
               errno != ESRCH {
                succeeded = false
                Logger.task.error(
                    "Failed to signal known task process \(identity.processID): errno \(errno)"
                )
            }
        }
        return succeeded
    }

    private static func waitUntilGone(
        _ identifier: pid_t,
        timeout: TimeInterval
    ) {
        let deadline = DispatchTime.now() + timeout
        while isProcessGroupAlive(identifier), DispatchTime.now() < deadline {
            Darwin.usleep(pollIntervalMicroseconds)
        }
    }

    private static func isProcessGroupAlive(_ identifier: pid_t) -> Bool {
        if let inspected = inspectedProcessGroupLiveness(identifier) {
            return inspected
        }
        if Darwin.kill(-identifier, 0) == 0 {
            return true
        }
        return errno != ESRCH
    }

    /// `kill(-pgid, 0)` can report a group containing only zombies as alive.
    /// Prefer libproc status when available so already-dead descendants do not
    /// turn bounded cleanup into a false failure.
    private static func inspectedProcessGroupLiveness(
        _ identifier: pid_t
    ) -> Bool? {
        guard case .known(let processIDs) =
                UserTaskProcessInspector.processIDs(inGroup: identifier) else {
            return nil
        }

        var encounteredUnknownProcess = false
        for processID in processIDs where processID > 1 {
            var info = proc_bsdinfo()
            let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            let result = proc_pidinfo(
                processID,
                PROC_PIDTBSDINFO,
                0,
                &info,
                expectedSize
            )
            if result == expectedSize {
                if info.pbi_status != UInt32(SZOMB) {
                    return true
                }
            } else if Darwin.kill(processID, 0) == 0 || errno != ESRCH {
                encounteredUnknownProcess = true
            }
        }
        return encounteredUnknownProcess ? nil : false
    }

    private static func isCurrentGroupMember(
        _ identity: UserTaskProcessIdentity,
        group: pid_t
    ) -> Bool {
        guard UserTaskProcessInspector.identity(
            for: identity.processID,
            includeZombie: true
        ) == identity,
              Darwin.getpgid(identity.processID) == group else {
            return false
        }
        return UserTaskProcessInspector.identity(
            for: identity.processID,
            includeZombie: true
        ) == identity
    }
}

/// Best-effort tracker for descendants that leave the shell's process group.
///
/// Darwin does not provide a public "kill process tree" primitive. The runner
/// therefore combines process-group ownership with bounded libproc snapshots.
/// Start timestamps protect against signalling an unrelated process after PID
/// reuse. A descendant that daemonizes between snapshots can still escape, so
/// callers must also bound pipe draining and direct-child waiting.
nonisolated final class UserTaskDescendantTracker {
    private static let maximumTrackedProcesses = 1_024
    private static let termGracePeriod: TimeInterval = 0.25
    private static let killWaitPeriod: TimeInterval = 1.0
    private static let pollIntervalMicroseconds: useconds_t = 10_000

    private let root: UserTaskProcessIdentity?
    private var descendants: [pid_t: UserTaskProcessIdentity] = [:]

    init(rootProcessID: pid_t) {
        root = Self.identity(for: rootProcessID)
        captureDescendants()
    }

    /// Records the currently visible process tree rooted at the shell and at
    /// every previously observed descendant.
    func captureDescendants() {
        let stillLive = liveDescendants()
        descendants = Dictionary(
            uniqueKeysWithValues: stillLive.map {
                ($0.processID, $0)
            }
        )

        var pending: [UserTaskProcessIdentity] = []
        if let root, Self.identity(for: root.processID) == root {
            pending.append(root)
        }
        pending.append(contentsOf: stillLive)

        var visited: Set<UserTaskProcessIdentity> = []
        while let parent = pending.popLast(),
              descendants.count < Self.maximumTrackedProcesses {
            guard visited.insert(parent).inserted else { continue }
            for childProcessID in Self.childProcessIDs(of: parent.processID) {
                guard descendants.count < Self.maximumTrackedProcesses,
                      let child = UserTaskProcessInspector.identity(
                          for: childProcessID,
                          expectedParent: parent.processID
                      ) else {
                    continue
                }
                descendants[childProcessID] = child
                pending.append(child)
            }
        }
    }

    /// Applies TERM then KILL to every observed descendant, including members
    /// that changed process groups. Returns false when a known identity
    /// survives the bounded cleanup window.
    func terminateTrackedProcesses() -> Bool {
        captureDescendants()
        signalLiveDescendants(SIGTERM)
        waitUntilGone(
            timeout: Self.termGracePeriod,
            repeatingSignal: SIGTERM
        )

        if !liveDescendants().isEmpty {
            signalLiveDescendants(SIGKILL)
            waitUntilGone(
                timeout: Self.killWaitPeriod,
                repeatingSignal: SIGKILL
            )
        }

        let succeeded = liveDescendants().isEmpty
        if !succeeded {
            Logger.task.error(
                "One or more observed task descendants survived SIGKILL"
            )
        }
        return succeeded
    }

    private func waitUntilGone(
        timeout: TimeInterval,
        repeatingSignal signalValue: Int32
    ) {
        let deadline = DispatchTime.now() + timeout
        while DispatchTime.now() < deadline {
            captureDescendants()
            let live = liveDescendants()
            guard !live.isEmpty else { return }
            send(signalValue, to: live)
            Darwin.usleep(Self.pollIntervalMicroseconds)
        }
    }

    private func signalLiveDescendants(_ signalValue: Int32) {
        send(signalValue, to: liveDescendants())
    }

    private func send(
        _ signalValue: Int32,
        to identities: [UserTaskProcessIdentity]
    ) {
        for identity in identities
        where Self.identity(for: identity.processID) == identity {
            if Darwin.kill(identity.processID, signalValue) != 0,
               errno != ESRCH {
                Logger.task.error(
                    "Failed to signal task descendant \(identity.processID): errno \(errno)"
                )
            }
        }
    }

    private func liveDescendants() -> [UserTaskProcessIdentity] {
        descendants.values.filter {
            Self.identity(for: $0.processID) == $0
        }
    }

    private static func childProcessIDs(of parent: pid_t) -> [pid_t] {
        errno = 0
        let requestedCount = proc_listchildpids(parent, nil, 0)
        guard requestedCount > 0 else { return [] }
        let capacity = min(
            max(Int(requestedCount) + 16, 16),
            maximumTrackedProcesses
        )
        var processIDs = [pid_t](repeating: 0, count: capacity)
        errno = 0
        let returnedCount = processIDs.withUnsafeMutableBytes { buffer in
            proc_listchildpids(
                parent,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard returnedCount > 0,
              Int(returnedCount) < processIDs.count else {
            return []
        }
        return Array(
            processIDs
                .prefix(Int(returnedCount))
                .filter { $0 > 1 }
        )
    }

    private static func identity(
        for processID: pid_t
    ) -> UserTaskProcessIdentity? {
        UserTaskProcessInspector.identity(for: processID)
    }
}

nonisolated struct UserTaskProcessIdentity: Hashable, Sendable {
    let processID: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

nonisolated enum UserTaskProcessGroupSnapshot: Sendable {
    case known([pid_t])
    /// libproc reports errors and an empty result with the same sentinel on
    /// some macOS releases. A full buffer is also unknowable because members
    /// may have been omitted. Callers must use a conservative fallback.
    case unknown
}

nonisolated enum UserTaskProcessInspector {
    private static let maximumGroupMembers = 1_024

    static func identity(
        for processID: pid_t,
        includeZombie: Bool = false,
        expectedParent: pid_t? = nil
    ) -> UserTaskProcessIdentity? {
        guard processID > 1 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(
            processID,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expectedSize
        )
        guard result == expectedSize,
              info.pbi_pid == UInt32(processID),
              includeZombie || info.pbi_status != UInt32(SZOMB) else {
            return nil
        }
        if let expectedParent,
           info.pbi_ppid != UInt32(expectedParent) {
            return nil
        }
        return UserTaskProcessIdentity(
            processID: processID,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec
        )
    }

    static func processIDs(
        inGroup identifier: pid_t
    ) -> UserTaskProcessGroupSnapshot {
        errno = 0
        let requestedCount = proc_listpgrppids(identifier, nil, 0)
        guard requestedCount > 0 else { return .unknown }
        let capacity = min(
            max(Int(requestedCount) + 16, 16),
            maximumGroupMembers
        )

        var processIDs = [pid_t](repeating: 0, count: capacity)
        errno = 0
        let returnedCount = processIDs.withUnsafeMutableBytes { buffer in
            proc_listpgrppids(
                identifier,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard groupCountsAreComplete(
            requestedCount: requestedCount,
            returnedCount: returnedCount,
            capacity: processIDs.count
        ) else {
            return .unknown
        }
        return .known(
            Array(
                processIDs
                    .prefix(Int(returnedCount))
                    .filter { $0 > 1 }
            )
        )
    }

    static func groupCountsAreComplete(
        requestedCount: Int32,
        returnedCount: Int32,
        capacity: Int
    ) -> Bool {
        requestedCount > 0
            && returnedCount > 0
            && Int(returnedCount) < capacity
    }
}

/// Coordinates bounded output-reader shutdown without closing a FileHandle
/// from a thread other than the one currently polling and reading it.
nonisolated final class UserTaskIOStopState: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var shouldStop: Bool {
        lock.withLock { stopped }
    }

    func stop() {
        lock.withLock {
            stopped = true
        }
    }
}

/// Tracks entry into every descriptor-owning worker. Waiting happens only on
/// the runner's background execution thread; worker entry itself is a single
/// non-blocking `leave`.
nonisolated final class UserTaskIOStartupBarrier: @unchecked Sendable {
    private let group = DispatchGroup()

    init(workerCount: Int) {
        precondition(workerCount >= 0)
        for _ in 0..<workerCount {
            group.enter()
        }
    }

    func workerDidStart() {
        group.leave()
    }

    func wait(timeout: TimeInterval) -> Bool {
        group.wait(
            timeout: .now() + max(timeout, 0)
        ) == .success
    }
}

/// Gives pipe workers a chance to observe EOF before requesting their bounded
/// fallback shutdown. Stopping first can make a worker that was merely waiting
/// for an executor thread report an incomplete stream even though the child
/// and every observed descendant have already exited.
nonisolated enum UserTaskIOShutdown {
    static func waitForCompletion(
        _ group: DispatchGroup,
        stopState: UserTaskIOStopState,
        naturalTimeout: TimeInterval,
        forcedTimeout: TimeInterval
    ) -> Bool {
        if group.wait(
            timeout: .now() + max(naturalTimeout, 0)
        ) == .success {
            return true
        }

        stopState.stop()
        return group.wait(
            timeout: .now() + max(forcedTimeout, 0)
        ) == .success
    }
}

nonisolated struct UserTaskPipeReadResult: Sendable {
    let data: Data
    let reachedEndOfFile: Bool
    let truncated: Bool

    static let incomplete = UserTaskPipeReadResult(
        data: Data(),
        reachedEndOfFile: false,
        truncated: false
    )
}

nonisolated struct UserTaskOutputSnapshot: Sendable {
    let stdout: UserTaskPipeReadResult
    let stderr: UserTaskPipeReadResult
}

/// Locked publication point for reader-local buffers. If a defensive reader
/// deadline is ever hit, the runner can snapshot safely while that reader
/// still owns its FileHandle.
nonisolated final class UserTaskOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutResult: UserTaskPipeReadResult?
    private var stderrResult: UserTaskPipeReadResult?

    func setStdout(_ result: UserTaskPipeReadResult) {
        lock.withLock {
            stdoutResult = result
        }
    }

    func setStderr(_ result: UserTaskPipeReadResult) {
        lock.withLock {
            stderrResult = result
        }
    }

    func snapshot() -> UserTaskOutputSnapshot {
        lock.withLock {
            UserTaskOutputSnapshot(
                stdout: stdoutResult ?? .incomplete,
                stderr: stderrResult ?? .incomplete
            )
        }
    }
}

nonisolated enum UserTaskPipeReader {
    /// Bounds retained memory while continuing to drain excess bytes so a
    /// verbose child cannot deadlock on a full pipe.
    static let maximumCapturedBytes = 4 * 1_024 * 1_024

    private static let bufferSize = 64 * 1_024
    private static let pollIntervalMilliseconds: Int32 = 20
    private static let maximumDrainReadsAfterStop = 8

    static func read(
        from handle: FileHandle,
        stopState: UserTaskIOStopState
    ) -> UserTaskPipeReadResult {
        defer { handle.closeFile() }

        let fileDescriptor = handle.fileDescriptor
        var data = Data()
        var truncated = false
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var remainingDrainReads = maximumDrainReadsAfterStop

        while true {
            let stopping = stopState.shouldStop
            if stopping {
                guard remainingDrainReads > 0 else {
                    return UserTaskPipeReadResult(
                        data: data,
                        reachedEndOfFile: false,
                        truncated: truncated
                    )
                }
                remainingDrainReads -= 1
            }

            var descriptor = pollfd(
                fd: fileDescriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let pollResult = Darwin.poll(
                &descriptor,
                1,
                stopping ? 0 : pollIntervalMilliseconds
            )
            if pollResult == 0 {
                if stopping {
                    return UserTaskPipeReadResult(
                        data: data,
                        reachedEndOfFile: false,
                        truncated: truncated
                    )
                }
                continue
            }
            if pollResult == -1 {
                if errno == EINTR { continue }
                return UserTaskPipeReadResult(
                    data: data,
                    reachedEndOfFile: false,
                    truncated: truncated
                )
            }

            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    fileDescriptor,
                    bytes.baseAddress,
                    bytes.count
                )
            }
            if bytesRead == 0 {
                return UserTaskPipeReadResult(
                    data: data,
                    reachedEndOfFile: true,
                    truncated: truncated
                )
            }
            if bytesRead == -1 {
                if errno == EINTR || errno == EAGAIN { continue }
                return UserTaskPipeReadResult(
                    data: data,
                    reachedEndOfFile: false,
                    truncated: truncated
                )
            }

            let availableCapacity = max(
                maximumCapturedBytes - data.count,
                0
            )
            let capturedCount = min(bytesRead, availableCapacity)
            if capturedCount > 0 {
                data.append(contentsOf: buffer.prefix(capturedCount))
            }
            if capturedCount < bytesRead {
                truncated = true
            }
        }
    }
}

nonisolated enum UserTaskPipeWriter {
    private static let pollIntervalMilliseconds: Int32 = 20

    /// Writes stdin without ever blocking the runner thread. The writer owns
    /// and closes its FileHandle; `F_SETNOSIGPIPE` prevents a child that exits
    /// early from turning EPIPE into a Pine process crash.
    static func write(
        _ data: Data,
        to handle: FileHandle,
        stopState: UserTaskIOStopState
    ) -> UserTaskPipeWriteResult {
        defer { handle.closeFile() }
        guard !data.isEmpty else { return .complete }

        let fileDescriptor = handle.fileDescriptor
        guard Darwin.fcntl(fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            return .failed(errno)
        }
        let currentFlags = Darwin.fcntl(fileDescriptor, F_GETFL)
        guard currentFlags != -1 else {
            return .failed(errno)
        }
        guard Darwin.fcntl(
            fileDescriptor,
            F_SETFL,
            currentFlags | O_NONBLOCK
        ) != -1 else {
            return .failed(errno)
        }

        var result = UserTaskPipeWriteResult.complete
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                result = .failed(EFAULT)
                return
            }
            var offset = 0
            while offset < bytes.count {
                if stopState.shouldStop {
                    result = .stopped
                    return
                }
                var descriptor = pollfd(
                    fd: fileDescriptor,
                    events: Int16(POLLOUT | POLLHUP | POLLERR),
                    revents: 0
                )
                let pollResult = Darwin.poll(
                    &descriptor,
                    1,
                    pollIntervalMilliseconds
                )
                if pollResult == 0 { continue }
                if pollResult == -1 {
                    if errno == EINTR { continue }
                    result = .failed(errno)
                    return
                }

                let written = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written == -1,
                          errno != EINTR,
                          errno != EAGAIN {
                    result = .failed(errno)
                    return
                }
            }
        }
        return result
    }
}

nonisolated enum UserTaskPipeWriteResult: Sendable, Equatable {
    case complete
    case stopped
    case failed(Int32)
}

/// Locked publication point for the single stdin writer.
nonisolated final class UserTaskInputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var result: UserTaskPipeWriteResult?

    func setResult(_ result: UserTaskPipeWriteResult) {
        lock.withLock {
            self.result = result
        }
    }

    func snapshot() -> UserTaskPipeWriteResult {
        lock.withLock { result ?? .stopped }
    }
}
