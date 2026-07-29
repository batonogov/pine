//
//  CommandOverlayRouterTests.swift
//  PineTests
//

import AppKit
import Foundation
import Testing

@testable import Pine

@Suite("Command overlay router", .serialized)
@MainActor
struct CommandOverlayRouterTests {

    @Test("Presenting a new flow replaces the active flow")
    func replacementIsDeterministic() {
        let router = makeRouterWithoutResponderHost()

        router.present(.quickOpen)
        router.present(.commandPalette)

        #expect(router.activePresentation == .commandPalette)
        #expect(router.isPresented)
    }

    @Test("An obsolete flow cannot dismiss its replacement")
    func staleDismissIsIgnored() {
        let router = makeRouterWithoutResponderHost()
        router.present(.quickOpen)
        router.present(.symbolNavigator)

        router.dismiss(ifMatching: .quickOpen)

        #expect(router.activePresentation == .symbolNavigator)
        router.dismiss(ifMatching: .symbolNavigator)
        #expect(!router.isPresented)
    }

    @Test("Independent project routers do not dismiss each other")
    func routersAreIndependent() {
        let first = makeRouterWithoutResponderHost()
        let second = makeRouterWithoutResponderHost()
        first.present(.quickOpen)
        second.present(.goToLine)

        first.dismiss()

        #expect(!first.isPresented)
        #expect(second.activePresentation == .goToLine)
    }

    @Test("Replacement restores an arbitrary original AppKit responder")
    func replacementPreservesOriginalResponder() async throws {
        let original = NSResponder()
        let intermediate = NSResponder()
        let host = CommandOverlayResponderHostSpy(firstResponder: original)
        let router = CommandOverlayRouter(responderHostProvider: { host })

        router.present(.quickOpen)
        #expect(router.capturedResponder === original)

        host.firstResponder = intermediate
        router.present(.commandPalette)
        #expect(router.capturedResponder === original)

        router.dismiss()
        let wasRestored = await waitUntil {
            host.firstResponder === original
        }
        try #require(
            wasRestored,
            "Timed out waiting for the original responder to be restored"
        )

        #expect(router.capturedResponder == nil)
        #expect(host.restoreCallCount == 1)
        #expect(host.lastRestoredResponder === original)
    }

    @Test("Dismissal restores a valid session without a first responder")
    func dismissalRestoresSessionWithoutResponder() async throws {
        let host = CommandOverlayResponderHostSpy(firstResponder: nil)
        let router = CommandOverlayRouter(responderHostProvider: { host })

        router.present(.quickOpen)
        router.dismiss()

        let didRestore = await waitUntil {
            host.restoreCallCount == 1
        }
        try #require(
            didRestore,
            "Timed out waiting for the responder host to be restored"
        )
        #expect(host.lastRestoredResponder == nil)
    }

    @Test("Palette overlay command replaces the panel in the same session")
    func paletteOverlayCommandReplacesInPlace() {
        let router = makeRouterWithoutResponderHost()
        router.present(.commandPalette)

        let didReplace = CommandPaletteInvocationRouter
            .replaceOverlayIfNeeded(
            for: .quickOpen,
            overlayRouter: router
        )

        #expect(didReplace)
        #expect(router.activePresentation == .quickOpen)
    }

    @Test("Non-overlay palette commands leave replacement routing untouched")
    func nonOverlayCommandDoesNotReplaceInPlace() {
        let router = makeRouterWithoutResponderHost()
        router.present(.commandPalette)

        let didReplace = CommandPaletteInvocationRouter
            .replaceOverlayIfNeeded(
                for: .findInProject,
                overlayRouter: router
            )

        #expect(!didReplace)
        #expect(router.activePresentation == .commandPalette)
    }

    @Test("Attachment view reports window lifecycle changes")
    func attachmentViewReportsLifecycleChanges() {
        let view = CommandOverlayAttachmentView(frame: .zero)
        var callbacks = 0
        view.onWindowChange = { window in
            #expect(window == nil)
            callbacks += 1
        }

        view.viewDidMoveToWindow()
        #expect(callbacks == 1)

        // `dismantleNSView` clears this callback so a late AppKit detach
        // cannot resurrect a stale coordinator or panel.
        view.onWindowChange = nil
        view.viewDidMoveToWindow()
        #expect(callbacks == 1)
    }

    @Test("Palette document command is targeted after dismissal")
    func paletteDocumentCommandDismissesThenDispatches() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pine-command-overlay-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let projectManager = ProjectManager()
        // This test only needs project availability. Starting a real workspace
        // load would launch an unrelated detached file-tree/git task that can
        // outlive the test and race temporary-directory cleanup.
        projectManager.workspace.rootURL = directory
        let router = makeRouterWithoutResponderHost()
        router.present(.commandPalette)

        let center = NotificationCenter()
        let probe = CommandOverlayNotificationProbe()
        let projectIdentifier = ObjectIdentifier(projectManager)
        let token = center.addObserver(
            forName: .showProjectSearch,
            object: nil,
            queue: nil
        ) { notification in
            probe.record(notification.object as AnyObject?)
        }
        defer { center.removeObserver(token) }

        CommandPaletteInvocationRouter.invoke(
            paletteItem(for: .findInProject),
            projectManager: projectManager,
            overlayRouter: router,
            notificationCenter: center
        )

        #expect(router.activePresentation == nil)
        #expect(probe.values.isEmpty)

        let wasDelivered = await waitUntil {
            !probe.values.isEmpty
        }
        try #require(
            wasDelivered,
            "Timed out waiting for post-dismiss command delivery"
        )

        let target = try #require(probe.values.first)
        #expect(target == projectIdentifier)
        #expect(probe.values.count == 1)
    }

    @Test("Command panel is key-capable and document scoped")
    func panelConfiguration() {
        let configuration = CommandOverlayPanelConfiguration.overlay

        #expect(configuration.canBecomeKey)
        #expect(!configuration.canBecomeMain)
        #expect(configuration.styleMask.contains(.titled))
        #expect(configuration.styleMask.contains(.nonactivatingPanel))
        #expect(
            !configuration.collectionBehavior.contains(.canJoinAllSpaces)
        )
        #expect(configuration.collectionBehavior.contains(.ignoresCycle))
    }

    @Test("Explicit document owner wins over the transient parent")
    func panelResolvesDocumentOwner() {
        let explicitOwner = 17
        let parent = 29

        let resolved = CommandOverlayOwnerResolver.preferredDocumentOwner(
            explicitOwner: explicitOwner,
            parent: parent
        )
        #expect(resolved == explicitOwner)

        let fallback = CommandOverlayOwnerResolver.preferredDocumentOwner(
            explicitOwner: Optional<Int>.none,
            parent: parent
        )
        #expect(fallback == parent)

        let missing = CommandOverlayOwnerResolver.preferredDocumentOwner(
            explicitOwner: Optional<Int>.none,
            parent: nil
        )
        #expect(missing == nil)
    }

    private func makeRouterWithoutResponderHost() -> CommandOverlayRouter {
        CommandOverlayRouter(responderHostProvider: { nil })
    }

    private func paletteItem(
        for command: UserCommand
    ) -> CommandPaletteItem {
        CommandPaletteItem(
            id: .builtIn(command),
            title: command.localizedTitle,
            subtitle: command.category.localizedTitle,
            searchTerms: [],
            iconName: command.iconName,
            shortcut: CommandShortcutPresentation(
                chord: nil,
                state: .none
            ),
            isEnabled: true
        )
    }

    /// Waits without blocking the main actor so the router's deliberately
    /// deferred AppKit restoration and command delivery can complete.
    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}

@MainActor
private final class CommandOverlayResponderHostSpy:
    CommandOverlayResponderHost {
    var firstResponder: NSResponder?
    private(set) var restoreCallCount = 0
    private(set) weak var lastRestoredResponder: NSResponder?

    var commandOverlayFirstResponder: NSResponder? {
        firstResponder
    }

    init(firstResponder: NSResponder?) {
        self.firstResponder = firstResponder
    }

    func restoreCommandOverlayResponder(_ responder: NSResponder?) {
        firstResponder = responder
        lastRestoredResponder = responder
        restoreCallCount += 1
    }
}

nonisolated private final class CommandOverlayNotificationProbe:
    @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ObjectIdentifier?] = []

    var values: [ObjectIdentifier?] {
        lock.withLock { storage }
    }

    func record(_ value: AnyObject?) {
        lock.withLock {
            storage.append(value.map(ObjectIdentifier.init))
        }
    }
}
