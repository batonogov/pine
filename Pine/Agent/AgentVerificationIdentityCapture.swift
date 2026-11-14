import CryptoKit
import Darwin
import Foundation

nonisolated struct AgentVerificationIdentitySnapshot: Equatable, Sendable {
    let code: AgentTaskCodeStateIdentity
    let environment: AgentTaskEnvironmentIdentity
}

nonisolated enum AgentVerificationIdentityCaptureResult: Sendable {
    enum Reason: String, Sendable {
        case unavailableBinding, incompleteCoverage, unsupportedInput, unreadableInput
        case unsavedEditorChanges, budgetExceeded, captureCapacity, unavailableTool
    }
    case current(AgentVerificationIdentitySnapshot)
    case changed
    case cancelled
    case unavailable(Reason)
}

/// Shared pre/post/revalidation API for checks, reviewers and result actions.
/// The owner supplies locally selected tool/configuration references from the
/// recipe; merely importing a project suggestion grants neither reads outside
/// its authorized scope nor process execution. Tool versions are identified by
/// actual executable bytes, never by an untrusted --version claim.
nonisolated struct AgentVerificationIdentityCapture: Sendable {
    struct Inputs: Sendable {
        let lease: RecentAgentTaskFilesystemValidationLease
        let policy: AgentVerificationCapturePolicy
        let editor: AgentVerificationEditorPreflight
        /// Canonical, explicitly selected executable files. This operation
        /// never follows a symlink or runs a version-probe process.
        let tools: [URL]
        let configurationFiles: [URL]
    }

    private static let slots = DispatchSemaphore(value: 4)
    let inputs: Inputs
    var timeout: TimeInterval = 30
    var maximumObservedBytes = 512 * 1_024 * 1_024
    var filesystemLimits = AgentVerificationFilesystemFingerprint.Limits()
    var environmentValues: @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    let cancellation: GitCommandCancellationToken

    func capture() async -> AgentVerificationIdentityCaptureResult {
        await withTaskCancellationHandler {
            if Task.isCancelled { return .cancelled }
            return await runOnBackground { captureSynchronously() }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Result/check consumers can require equivalence with a previous exact
    /// snapshot without accidentally treating a newly observed state as the
    /// old result's authority. This still executes no project command.
    func revalidate(_ expected: AgentVerificationIdentitySnapshot) async -> AgentVerificationIdentityCaptureResult {
        let observed = await capture()
        if case .current(let current) = observed, current != expected { return .changed }
        return observed
    }

    func captureSynchronously() -> AgentVerificationIdentityCaptureResult {
        precondition(!Thread.isMainThread)
        guard !cancellation.isCancelled else { return .cancelled }
        guard Self.slots.wait(timeout: .now()) == .success else { return .unavailable(.captureCapacity) }
        defer { Self.slots.signal() }
        guard !cancellation.isCancelled else { return .cancelled }
        guard timeout.isFinite, timeout > 0, maximumObservedBytes > 0,
              inputs.lease.revalidate() else { return .unavailable(.unavailableBinding) }
        guard inputs.policy.isValid, !inputs.tools.isEmpty, inputs.tools.count <= 32,
              inputs.configurationFiles.count <= 128,
              Set(inputs.tools.map(\.path)).count == inputs.tools.count,
              Set(inputs.configurationFiles.map(\.path)).count == inputs.configurationFiles.count else {
            return .unavailable(.incompleteCoverage)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        do {
            var remainingObservedBytes = maximumObservedBytes
            let before = try environment(deadline: deadline, remainingBytes: &remainingObservedBytes)
            let inspector = AgentVerificationGitInspector(lease: inputs.lease, cancellation: cancellation, deadline: deadline)
            let remaining = ContinuousClock.now.duration(to: deadline).components
            var limits = filesystemLimits
            limits.timeout = min(limits.timeout, Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18)
            let collector = AgentVerificationFilesystemFingerprint(
                lease: inputs.lease, limits: limits, policy: inputs.policy, editor: inputs.editor,
                cancellation: cancellation, gitSnapshot: { try inspector.capture() }
            )
            let code = try collector.capture()
            let after = try environment(deadline: deadline, remainingBytes: &remainingObservedBytes)
            guard !cancellation.isCancelled else { return .cancelled }
            guard before == after, inputs.lease.revalidate(), ContinuousClock.now < deadline else { return .changed }
            guard case .available(_, let editorIsCurrent) = inputs.editor, editorIsCurrent() else { return .changed }
            return .current(AgentVerificationIdentitySnapshot(code: code, environment: after.identity))
        } catch let error as AgentVerificationFilesystemFingerprint.Failure {
            switch error {
            case .changed: return .changed
            case .cancelled: return .cancelled
            case .budget: return .unavailable(.budgetExceeded)
            case .capacity: return .unavailable(.captureCapacity)
            case .unsavedBuffer: return .unavailable(.unsavedEditorChanges)
            case .editorUnavailable, .missingInput: return .unavailable(.incompleteCoverage)
            case .externalLink, .unsupportedFile, .unsupportedRepository: return .unavailable(.unsupportedInput)
            case .invalidPolicy: return .unavailable(.incompleteCoverage)
            case .unavailable: return .unavailable(.unreadableInput)
            }
        } catch let error as AgentVerificationGitInspector.Failure {
            switch error {
            case .changed: return .changed
            case .cancelled: return .cancelled
            case .budget: return .unavailable(.budgetExceeded)
            case .unavailable: return .unavailable(.incompleteCoverage)
            }
        } catch let error as ObservationError {
            if cancellation.isCancelled { return .cancelled }
            switch error {
            case .budget: return .unavailable(.budgetExceeded)
            case .changed: return .changed
            case .unavailable: return .unavailable(.unavailableTool)
            }
        } catch {
            return cancellation.isCancelled ? .cancelled : .unavailable(.unavailableTool)
        }
    }

    private struct EnvironmentObservation: Equatable {
        let identity: AgentTaskEnvironmentIdentity
        let fileWitnesses: [String: String]
    }

    private func environment(
        deadline: ContinuousClock.Instant, remainingBytes: inout Int
    ) throws -> EnvironmentObservation {
        var fileWitnesses: [String: String] = [:]
        var tools = AgentVerificationCanonicalHasher(domain: "pine.ade.observed-tools.v2")
        var config = AgentVerificationCanonicalHasher(domain: "pine.ade.observed-config.v2")
        config.append("policy", inputs.policy.fingerprint)
        config.append("project", inputs.lease.identity.canonicalProjectPath)
        config.append("worktree", inputs.lease.identity.canonicalWorktreePath)
        var root = stat()
        guard lstat(inputs.lease.canonicalWorktree.path, &root) == 0, root.st_mode & S_IFMT == S_IFDIR else {
            throw ObservationError.unavailable
        }
        // Root timestamps/size are deliberately omitted: declared disposable
        // output creation changes them without changing supported inputs.
        config.append("root-object", "\(root.st_dev):\(root.st_ino):\(root.st_gen):\(root.st_birthtimespec.tv_sec)")
        config.append("root-mode", "\(root.st_mode):\(root.st_uid):\(root.st_gid)")
        for url in inputs.tools.sorted(by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }) {
            fileWitnesses[url.path] = try appendFile(
                url, executable: true, into: &tools, remaining: &remainingBytes, deadline: deadline
            )
        }
        for url in inputs.configurationFiles.sorted(by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }) {
            fileWitnesses[url.path] = try appendFile(
                url, executable: false, into: &config, remaining: &remainingBytes, deadline: deadline
            )
        }
        let variables = environmentValues()
        guard variables.count <= 1_024 else { throw ObservationError.budget }
        for key in variables.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            guard key.utf8.count <= 1_024, let value = variables[key], value.utf8.count <= 65_536 else {
                throw ObservationError.budget
            }
            remainingBytes -= key.utf8.count + value.utf8.count
            guard remainingBytes >= 0 else { throw ObservationError.budget }
            config.append("environment-key", key)
            config.append("environment-value", value)
        }
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1, size <= 65 else {
            throw ObservationError.unavailable
        }
        var bytes = [UInt8](repeating: 0, count: size)
        let status = bytes.withUnsafeMutableBytes { sysctlbyname("kern.osversion", $0.baseAddress, &size, nil, 0) }
        guard status == 0, bytes.last == 0,
              let osBuild = String(bytes: bytes.dropLast(), encoding: .utf8), !osBuild.isEmpty else {
            throw ObservationError.unavailable
        }
        return EnvironmentObservation(
            identity: AgentTaskEnvironmentIdentity(
                osBuild: osBuild, toolchain: tools.finish(), configurationFingerprint: config.finish()
            ), fileWitnesses: fileWitnesses
        )
    }

    private func appendFile(
        _ url: URL, executable: Bool, into aggregate: inout AgentVerificationCanonicalHasher,
        remaining: inout Int, deadline: ContinuousClock.Instant
    ) throws -> String {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0) else { throw ObservationError.unavailable }
        guard let selected = RecentAgentTaskFilesystemValidator.selectedFileLease(for: url), selected.revalidate() else {
            throw ObservationError.unavailable
        }
        let file = selected.descriptor
        var before = stat()
        guard fstat(file, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0,
              !executable || before.st_mode & 0o111 != 0 else { throw ObservationError.unavailable }
        guard before.st_size <= remaining else { throw ObservationError.budget }
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var captured = 0
        while true {
            guard !cancellation.isCancelled, ContinuousClock.now < deadline else { throw ObservationError.budget }
            let count = buffer.withUnsafeMutableBufferPointer { Darwin.read(file, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ObservationError.unavailable }
            if count == 0 { break }
            captured += count
            remaining -= count
            guard remaining >= 0 else { throw ObservationError.budget }
            digest.update(data: Data(buffer.prefix(count)))
        }
        var after = stat()
        guard let reopened = RecentAgentTaskFilesystemValidator.selectedFileLease(for: url) else {
            throw ObservationError.changed
        }
        var live = stat()
        guard selected.revalidate(), reopened.revalidate(),
              fstat(file, &after) == 0, fstat(reopened.descriptor, &live) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              Self.sameTime(before.st_ctimespec, after.st_ctimespec), Self.sameTime(before.st_mtimespec, after.st_mtimespec),
              before.st_size == after.st_size, captured == after.st_size,
              live.st_dev == after.st_dev, live.st_ino == after.st_ino,
              live.st_mode == after.st_mode, Self.sameTime(live.st_ctimespec, after.st_ctimespec) else {
            throw ObservationError.changed
        }
        aggregate.append("path", selected.canonicalURL.path)
        aggregate.append("mode", String(after.st_mode))
        aggregate.append("content", digest.finalize().map { String(format: "%02x", $0) }.joined())
        return AgentVerificationMetadataWitness.signature(after)
    }

    private static func sameTime(_ lhs: timespec, _ rhs: timespec) -> Bool {
        lhs.tv_sec == rhs.tv_sec && lhs.tv_nsec == rhs.tv_nsec
    }

    private enum ObservationError: Error { case unavailable, changed, budget }
}
