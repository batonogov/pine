import AppKit
import SwiftUI
import Testing

@testable import Pine

@Suite("Inbox Welcome navigation composition", .serialized)
@MainActor
struct AgentInboxWelcomeCompositionTests {
    @Test("the Welcome anchor hides Welcome and cancels its delayed ensure only on success",
          arguments: [AgentInboxActionOutcome.dismiss, .keepVisible(.routeUnavailable)])
    func welcomeNavigationComposition(outcome: AgentInboxActionOutcome) async throws {
        let suite = "InboxWelcomeComposition.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ProjectRegistry(
            defaults: defaults, agentTasks: AgentTaskRegistry(),
            agentDetectionPollInterval: 3_600, agentDetectionInitialPollDelay: 3_600
        )
        let appDelegate = AppDelegate()
        appDelegate.registry = registry
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(suite)
        appDelegate.welcomeWindow = window
        window.orderFront(nil)
        defer { appDelegate.hideWelcome(); window.orderOut(nil) }
        #expect(window.isVisible)

        let gate = EnsureGate()
        defer { gate.release() }
        appDelegate.showWelcome(waitBeforeEnsure: { await gate.wait() }, ensureVisible: {
            gate.ensureCalls += 1
            window.orderFront(nil)
        })
        #expect(await waitUntilMainActor { gate.continuation != nil })

        // Use the very configuration rendered by WelcomeView, not a closure
        // injected directly into the coordinator. Only the AppKit handle is fake.
        let welcome = WelcomeView(registry: registry, appDelegate: appDelegate)
        var configuration = welcome.agentInboxAnchor
        let content = Content()
        let popover = Popover()
        configuration.makePopover = { _, context in
            content.dismiss = context.onDismiss
            return popover
        }
        let coordinator = configuration.makeCoordinator()
        let anchor = AgentInboxPopoverAnchorView()
        window.contentView?.addSubview(anchor)
        coordinator.attach(to: anchor)
        defer { coordinator.detach() }
        coordinator.presentAgentInbox()
        let dismiss = try #require(content.dismiss)
        let inbox = AgentInboxView(
            registry: registry, onDismiss: dismiss, onAccessibilityAnnouncement: { _ in }
        )
        inbox.apply(outcome)
        let succeeded = outcome == .dismiss
        #expect(window.isVisible == !succeeded)
        gate.release()
        #expect(await waitUntilMainActor { gate.finishedWait })
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(gate.ensureCalls == (succeeded ? 0 : 1))
        #expect(window.isVisible == !succeeded)
    }

    private final class EnsureGate {
        var continuation: CheckedContinuation<Void, Never>?
        var ensureCalls = 0
        var finishedWait = false
        func wait() async {
            await withCheckedContinuation { continuation = $0 }
            finishedWait = true
        }
        func release() {
            continuation?.resume()
            continuation = nil
        }
    }
    private final class Content { var dismiss: (@MainActor () -> Void)? }
    private final class Popover: AgentInboxPopoverHandle {
        var isPopoverVisible = false
        func showPopover(from anchor: NSView) { isPopoverVisible = true }
        func closePopover() { isPopoverVisible = false }
    }
}
