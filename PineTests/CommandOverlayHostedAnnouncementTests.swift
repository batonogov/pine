//
//  CommandOverlayHostedAnnouncementTests.swift
//  PineTests
//

import AppKit
import SwiftUI
import Testing

@testable import Pine

@Suite("Hosted command overlay announcements")
@MainActor
struct CommandOverlayHostedAnnouncementTests {
    @Test("Quick Open arrow navigation reaches the announcement sink")
    func quickOpenArrowAnnouncement() async throws {
        let projectManager = ProjectManager()
        let root = URL(fileURLWithPath: "/tmp/quick-open-announcement")
        projectManager.workspace.rootURL = root
        projectManager.workspace.rootNodes = [
            FileNode(url: root.appendingPathComponent("First.swift")),
            FileNode(url: root.appendingPathComponent("Second.swift")),
        ]
        let recorder = HostedOverlayAnnouncementRecorder()
        let hosted = host(
            QuickOpenAnnouncementHarness(
                projectManager: projectManager,
                recorder: recorder
            ),
            size: NSSize(width: 500, height: 360)
        )
        let field = try #require(findTextField(in: hosted))
        let coordinator = try #require(
            field.delegate as? QuickOpenSearchField.Coordinator
        )

        field.stringValue = "swift"
        coordinator.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: field
        ))
        #expect(await waitUntil {
            recorder.messages.contains { $0.hasPrefix("2 results.") }
        })
        recorder.messages.removeAll()

        #expect(coordinator.control(
            field,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.moveDown(_:))
        ))
        #expect(recorder.messages.count == 1)
        #expect(recorder.messages[0].contains(".swift"))
        withExtendedLifetime(hosted) {}
    }

    @Test("Symbol Navigator arrow navigation reaches the announcement sink")
    func symbolNavigatorArrowAnnouncement() async throws {
        let projectManager = ProjectManager()
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/tmp/HostedSymbols.swift"),
            content: "func alpha() {}\nfunc beta() {}\n",
            savedContent: "func alpha() {}\nfunc beta() {}\n"
        )
        projectManager.primaryTabManager.tabs = [tab]
        projectManager.primaryTabManager.activeTabID = tab.id
        let recorder = HostedOverlayAnnouncementRecorder()
        let hosted = host(
            SymbolNavigatorAnnouncementHarness(
                projectManager: projectManager,
                recorder: recorder
            ),
            size: NSSize(width: 500, height: 360)
        )
        let field = try #require(findTextField(in: hosted))
        let coordinator = try #require(
            field.delegate as? QuickOpenSearchField.Coordinator
        )

        #expect(await waitUntil {
            recorder.messages.contains { $0.hasPrefix("2 results.") }
        })
        recorder.messages.removeAll()

        #expect(coordinator.control(
            field,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.moveDown(_:))
        ))
        #expect(recorder.messages.count == 1)
        #expect(recorder.messages[0].contains("beta"))
        withExtendedLifetime(hosted) {}
    }

    private func host<Content: View>(
        _ content: Content,
        size: NSSize
    ) -> NSHostingView<Content> {
        let hosted = NSHostingView(rootView: content)
        hosted.frame = NSRect(origin: .zero, size: size)
        hosted.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        hosted.layoutSubtreeIfNeeded()
        return hosted
    }

    private func findTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField {
            return field
        }
        for subview in view.subviews {
            if let field = findTextField(in: subview) {
                return field
            }
        }
        return nil
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

@MainActor
private final class HostedOverlayAnnouncementRecorder {
    var messages: [String] = []

    func record(_ message: String) -> Bool {
        messages.append(message)
        return true
    }
}

private struct QuickOpenAnnouncementHarness: View {
    let projectManager: ProjectManager
    let recorder: HostedOverlayAnnouncementRecorder

    var body: some View {
        QuickOpenView(
            isPresented: .constant(true),
            onAnnounce: recorder.record
        )
        .environment(projectManager)
        .environment(\.locale, Locale(identifier: "en"))
    }
}

private struct SymbolNavigatorAnnouncementHarness: View {
    let projectManager: ProjectManager
    let recorder: HostedOverlayAnnouncementRecorder

    var body: some View {
        SymbolNavigatorView(
            isPresented: .constant(true),
            onAnnounce: recorder.record
        )
        .environment(projectManager)
        .environment(\.locale, Locale(identifier: "en"))
    }
}
