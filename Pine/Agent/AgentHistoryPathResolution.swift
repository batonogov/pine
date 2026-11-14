import Foundation

/// Every filesystem-dependent path operation stays on the utility queue,
/// including when the caller inherits MainActor isolation.
nonisolated enum AgentHistoryPathResolution {
    typealias Resolver = @Sendable (URL, [URL]) -> [String]

    static func resolve(root: URL, files: [URL], using resolver: @escaping Resolver) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let paths = autoreleasepool { resolver(root, files) }
                continuation.resume(returning: paths)
            }
        }
    }

    static func relativePaths(root: URL, files: [URL]) -> [String] {
        let rootPath = root.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return files.compactMap { file in
            let path = file.resolvingSymlinksInPath().path
            guard path.hasPrefix(prefix) else { return nil }
            return String(path.dropFirst(prefix.count))
        }
    }
}

/// Value capture prevents later detector mutations from changing a completed
/// run while filesystem resolution is suspended.
nonisolated struct PendingAgentHistoryFinalization: Sendable {
    let generation: UUID
    let root: URL
    let entryID: UUID
    let sessionID: UUID
    let agentTypeRaw: String
    let startedAt: Date
    let endedAt: Date
    let files: [URL]
}
