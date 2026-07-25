//
//  UserCommandInvocationRouterTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("Registered command invocation router")
@MainActor
struct UserCommandInvocationRouterTests {
    @Test("Application command dispatches exactly one notification")
    func openFolderDispatch() {
        let center = NotificationCenter()
        let probe = NotificationProbe()
        let token = center.addObserver(
            forName: .openFolder,
            object: nil,
            queue: nil
        ) { _ in
            probe.record("openFolder")
        }
        defer { center.removeObserver(token) }

        UserCommandInvocationRouter.dispatch(
            .openFolder,
            projectManager: nil,
            notificationCenter: center
        )

        #expect(probe.values == ["openFolder"])
    }

    @Test("Structured fold command preserves its action payload")
    func foldDispatchPayload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pine-command-router-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("main.swift")
        try Data("func main() {}".utf8).write(to: file)

        let projectManager = ProjectManager()
        projectManager.activeTabManager.openTab(url: file)
        let center = NotificationCenter()
        let probe = NotificationProbe()
        let token = center.addObserver(
            forName: .foldCode,
            object: nil,
            queue: nil
        ) { notification in
            probe.record(notification.userInfo?["action"] as? String ?? "")
        }
        defer { center.removeObserver(token) }

        UserCommandInvocationRouter.dispatch(
            .unfoldAll,
            projectManager: projectManager,
            notificationCenter: center
        )

        #expect(probe.values == ["unfoldAll"])
    }

    @Test("Unavailable command does not dispatch")
    func unavailableCommandIsIgnored() {
        let center = NotificationCenter()
        let probe = NotificationProbe()
        let token = center.addObserver(
            forName: .findInFile,
            object: nil,
            queue: nil
        ) { _ in
            probe.record("find")
        }
        defer { center.removeObserver(token) }

        UserCommandInvocationRouter.dispatch(
            .findInFile,
            projectManager: nil,
            notificationCenter: center
        )

        #expect(probe.values.isEmpty)
    }

    @Test("Targeted palette requests only match their owning project")
    func commandPaletteTargeting() {
        let currentProject = ProjectManager()
        let otherProject = ProjectManager()

        #expect(ContentView.shouldHandleTargetedCommand(
            notificationObject: currentProject,
            currentProject: currentProject,
            isKeyWindow: false
        ))
        #expect(!ContentView.shouldHandleTargetedCommand(
            notificationObject: otherProject,
            currentProject: currentProject,
            isKeyWindow: true
        ))
        #expect(ContentView.shouldHandleTargetedCommand(
            notificationObject: nil,
            currentProject: currentProject,
            isKeyWindow: true
        ))
        #expect(!ContentView.shouldHandleTargetedCommand(
            notificationObject: nil,
            currentProject: currentProject,
            isKeyWindow: false
        ))
    }
}

nonisolated private final class NotificationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func record(_ value: String) {
        lock.withLock {
            storage.append(value)
        }
    }
}
