import Foundation
import Testing
@testable import Pine

@Suite("OpenCode UI dispatch integration", .serialized)
@MainActor
struct OpenCodeTaskRequestIntegrationTests {
    @Test func requestQuestionResultAndFeedbackUseProductionTaskPreparation() async throws {
        let fixture = try await runOnBackground { try OpenCodeRequestFixture() }
        defer { fixture.remove() }
        let tasks = AgentTaskRegistry(persistence: OpenCodeRequestTaskStore())
        let projects = ProjectRegistry(agentTasks: tasks)
        let taskID = try await projects.startOpenCodeTask(
            instruction: "Choose a color",
            project: fixture.identity,
            executable: fixture.binary,
            managedRoot: fixture.managedRoot
        )
        let runtime = try #require(projects.openCodeRuntime(for: taskID))
        try #require(await waitUntilMainActor { runtime.snapshot?.questions.count == 1 })
        let question = try #require(runtime.snapshot?.questions.first)
        _ = try await runtime.answerQuestion(question, answers: ["color": ["blue"]])
        try #require(await waitUntilMainActor { runtime.snapshot?.state == .unverified })
        #expect(runtime.snapshot?.result == "first-result")
        #expect(runtime.snapshot?.ready == false)
        #expect(tasks.task(for: taskID)?.worktreeSetup?.phase == .populated)
        #expect(tasks.task(for: taskID)?.runs.last?.outcome == nil)

        _ = try await runtime.submit("Revise it")
        try #require(await waitUntilMainActor { runtime.snapshot?.result == "feedback-result" })
        #expect(runtime.snapshot?.nativeSession?.rawValue == "ses_ui")
        #expect(fixture.promptCount() == 2)
        #expect(fixture.worktreeHasTrackedFile())
        await runtime.stop(deadline: .now.advanced(by: .seconds(5)))
    }

    @Test func blankRequestCreatesNeitherTaskNorProcess() async throws {
        let fixture = try await runOnBackground { try OpenCodeRequestFixture() }
        defer { fixture.remove() }
        let tasks = AgentTaskRegistry(persistence: OpenCodeRequestTaskStore())
        let projects = ProjectRegistry(agentTasks: tasks)
        await #expect(throws: OpenCodeACPError.invalidState) {
            _ = try await projects.startOpenCodeTask(
                instruction: " \n ", project: fixture.identity,
                executable: fixture.binary, managedRoot: fixture.managedRoot
            )
        }
        #expect(tasks.tasks.isEmpty)
        #expect(fixture.promptCount() == 0)
    }
}

private actor OpenCodeRequestTaskStore: AgentTaskPersisting {
    private var data = Data("[]".utf8)
    func load(project: AgentTaskProjectIdentity) async -> AgentTaskMetadataLoadResult {
        AgentTaskMetadataLoadResult(
            status: .loaded,
            tasks: (try? JSONDecoder().decode([AgentTask].self, from: data)) ?? [],
            revision: nil, requiresMigration: false, envelope: .empty
        )
    }
    func save(
        tasks: [AgentTask], project: AgentTaskProjectIdentity,
        authorization: AgentTaskPublicationAuthorization?
    ) async -> AgentTaskMetadataSaveResult {
        guard let encoded = try? JSONEncoder().encode(tasks) else {
            return .rejected(.invalidMetadata)
        }
        data = encoded
        return .saved(taskCount: tasks.count)
    }
}

nonisolated private struct OpenCodeRequestFixture: Sendable {
    let root: URL
    let project: URL
    let managedRoot: URL
    let binary: URL
    private let promptMarker: URL

    var identity: AgentTaskProjectIdentity {
        AgentTaskProjectIdentity(
            canonicalProjectPath: project.path, canonicalWorktreePath: project.path
        )
    }

    init() throws {
        let rawRoot = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/pine-opencode-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rawRoot, withIntermediateDirectories: true)
        root = rawRoot.resolvingSymlinksInPath()
        project = root.appendingPathComponent("project")
        managedRoot = root.appendingPathComponent("worktrees")
        binary = root.appendingPathComponent("opencode")
        promptMarker = root.appendingPathComponent("prompt-count")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        try git(["init", "-b", "main"])
        try Data("tracked\n".utf8).write(to: project.appendingPathComponent("tracked.txt"))
        try git(["add", "."])
        try git([
            "-c", "user.name=Pine Test", "-c", "user.email=pine@example.invalid",
            "commit", "-m", "fixture"
        ])
        let source = root.appendingPathComponent("agent.c")
        try Self.agentSource.write(toFile: source.path, atomically: true, encoding: .utf8)
        let marker = promptMarker.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let compiled = GitCommand.runExecutable(
            URL(fileURLWithPath: "/usr/bin/clang"),
            arguments: ["-O0", "-DPROMPT_MARKER=\"\(marker)\"", source.path, "-o", binary.path],
            at: root, timeout: 30
        )
        guard compiled.succeeded else { throw CocoaError(.executableNotLoadable) }
        let signed = GitCommand.runExecutable(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--force", "--sign", "-", binary.path], at: root, timeout: 30
        )
        guard signed.succeeded else { throw CocoaError(.executableNotLoadable) }
    }

    func promptCount() -> Int {
        guard let data = try? Data(contentsOf: promptMarker),
              let text = String(data: data, encoding: .utf8) else { return 0 }
        return text.filter { $0 == "p" }.count
    }

    func worktreeHasTrackedFile() -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: managedRoot, includingPropertiesForKeys: nil
        ), entries.count == 1 else { return false }
        return FileManager.default.fileExists(
            atPath: entries[0].appendingPathComponent("tracked.txt").path
        )
    }

    func git(_ arguments: [String]) throws {
        let result = GitCommand.runExecutable(
            URL(fileURLWithPath: "/usr/bin/env"),
            arguments: AgentTaskReservedWorktreeSetup.arguments(arguments), at: project
        )
        guard result.succeeded else { throw CocoaError(.fileWriteUnknown) }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    private static let agentSource = #"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void send(const char *text) {
    fputs(text, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--version") == 0) {
        puts("opencode v2.4.0");
        return 0;
    }
    char *line = NULL;
    size_t capacity = 0;
    int prompt = 0;
    while (getline(&line, &capacity, stdin) >= 0) {
        if (strstr(line, "\"initialize\"")) {
            send("{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"protocolVersion\":1,"
                 "\"agentInfo\":{\"name\":\"OpenCode\",\"version\":\"2.4.0\"},"
                 "\"agentCapabilities\":{\"loadSession\":true,"
                 "\"_meta\":{\"opencode/child-session-updates\":true}}}}");
        } else if (strstr(line, "\"session\\/new\"")) {
            send("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"sessionId\":\"ses_ui\"}}");
        } else if (strstr(line, "\"session\\/prompt\"")) {
            prompt += 1;
            FILE *marker = fopen(PROMPT_MARKER, "a");
            if (marker) { fputc('p', marker); fclose(marker); }
            if (prompt == 1) {
                send("{\"jsonrpc\":\"2.0\",\"id\":\"ask\",\"method\":\"elicitation/create\","
                     "\"params\":{\"mode\":\"form\",\"sessionId\":\"ses_ui\","
                     "\"toolCallId\":\"question-tool\",\"message\":\"Which color?\","
                     "\"requestedSchema\":{\"type\":\"object\",\"required\":[\"color\"],"
                     "\"properties\":{\"color\":{\"type\":\"string\","
                     "\"oneOf\":[{\"const\":\"blue\"},{\"const\":\"amber\"}]}}}}}");
            } else {
                send("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\","
                     "\"params\":{\"sessionId\":\"ses_ui\",\"update\":{"
                     "\"sessionUpdate\":\"agent_message_chunk\",\"content\":{"
                     "\"type\":\"text\",\"text\":\"feedback-result\"}}}}");
                send("{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"stopReason\":\"end_turn\"}}");
            }
        } else if (strstr(line, "\"id\":\"ask\"")) {
            send("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\","
                 "\"params\":{\"sessionId\":\"ses_ui\",\"update\":{"
                 "\"sessionUpdate\":\"tool_call_update\","
                 "\"toolCallId\":\"question-tool\",\"status\":\"completed\"}}}");
            send("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\","
                 "\"params\":{\"sessionId\":\"ses_ui\",\"update\":{"
                 "\"sessionUpdate\":\"agent_message_chunk\",\"content\":{"
                 "\"type\":\"text\",\"text\":\"first-result\"}}}}");
            send("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"stopReason\":\"end_turn\"}}");
        }
    }
    free(line);
    return 0;
}
"""#
}
