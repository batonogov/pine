import Foundation
import Testing
@testable import Pine

struct AgentTaskGitInspectionTests {
    @Test func metadataInspectionResetsGitEnvironmentAndUsesLiteralArguments() {
        let arguments = AgentTaskGitInspection.arguments(environment: [
            "GIT_DIR": "/private/unrelated", "GIT_WORK_TREE": "/private/elsewhere",
            "GIT_INDEX_FILE": "/private/index", "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "core.worktree", "GIT_CONFIG_VALUE_0": "/private/other",
            "GIT_TRACE": "SECRET-TRACE-FIXTURE", "PATH": "/untrusted/bin",
            "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"
        ])
        #expect(arguments.first == "-i")
        #expect(arguments.contains("DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer"))
        #expect(Array(arguments.suffix(5)) == ["/usr/bin/git", "symbolic-ref", "--quiet", "--short", "HEAD"])
        #expect(!arguments.contains { $0.contains("unrelated") || $0.contains("elsewhere") || $0.contains("SECRET") })
        #expect(!arguments.contains { $0.hasPrefix("GIT_DIR=") || $0.hasPrefix("GIT_INDEX_FILE=") })
    }
}
