import Foundation

/// Authoritative branch inspection must not inherit GIT_DIR, GIT_WORK_TREE,
/// GIT_INDEX_FILE, injected config, or Git tracing from Pine's environment.
/// The sealed system env executable supplies a literal argv environment reset;
/// no shell or project-suggested command is involved. This reads metadata only.
nonisolated enum AgentTaskGitInspection {
    static func branch(at root: URL) -> GitCommandResult {
        GitCommand.runExecutable(
            URL(fileURLWithPath: "/usr/bin/env"),
            arguments: arguments(environment: ProcessInfo.processInfo.environment),
            at: root, timeout: 5, captureLimit: 4_096
        )
    }

    static func arguments(environment: [String: String]) -> [String] {
        var values = [
            "-i", "PATH=/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM=1",
            "GIT_CONFIG_GLOBAL=/dev/null", "GIT_OPTIONAL_LOCKS=0", "GIT_TERMINAL_PROMPT=0"
        ]
        // Preserve only the host's explicit Xcode selection for /usr/bin/git's
        // xcrun shim. No Git- or project-controlled environment is carried over.
        if let developerDirectory = environment["DEVELOPER_DIR"], developerDirectory.hasPrefix("/"),
           developerDirectory.utf8.count <= 4_096,
           !developerDirectory.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            values.append("DEVELOPER_DIR=\(developerDirectory)")
        }
        return values + ["/usr/bin/git", "symbolic-ref", "--quiet", "--short", "HEAD"]
    }
}
