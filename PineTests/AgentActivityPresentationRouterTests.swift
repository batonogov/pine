//
//  AgentActivityPresentationRouterTests.swift
//  PineTests
//
//  Multi-window routing coverage for Agent Activity presentation.
//

import Foundation
import Testing

@testable import Pine

@MainActor
@Suite("Agent Activity Presentation Routing")
struct AgentActivityPresentationRouterTests {
    @Test("Menu request carries the exact owning project")
    func postRequestTargetsOwningProject() {
        let center = NotificationCenter()
        let probe = AgentActivityNotificationProbe()
        let token = center.addObserver(
            forName: .showAgentActivity,
            object: nil,
            queue: nil
        ) { notification in
            probe.record(notification.object)
        }
        defer { center.removeObserver(token) }

        let project = ProjectManager()

        #expect(AgentActivityPresentationRouter.postRequest(
            for: project,
            notificationCenter: center
        ))
        #expect(probe.count == 1)
        #expect(probe.lastObject === project)
    }

    @Test("Missing focused project fails closed without broadcasting")
    func nilProjectDoesNotPost() {
        let center = NotificationCenter()
        let probe = AgentActivityNotificationProbe()
        let token = center.addObserver(
            forName: .showAgentActivity,
            object: nil,
            queue: nil
        ) { notification in
            probe.record(notification.object)
        }
        defer { center.removeObserver(token) }

        #expect(!AgentActivityPresentationRouter.postRequest(
            for: nil,
            notificationCenter: center
        ))
        #expect(probe.isEmpty)
        #expect(probe.lastObject == nil)
    }

    @Test("Only the targeted project consumes project-scoped requests")
    func targetedRequestMatchesOnlyOwner() {
        let owner = ProjectManager()
        let other = ProjectManager()

        #expect(AgentActivityPresentationRouter.shouldPresent(
            notificationObject: owner,
            currentProject: owner,
            isKeyWindow: false
        ))
        #expect(!AgentActivityPresentationRouter.shouldPresent(
            notificationObject: owner,
            currentProject: other,
            isKeyWindow: true
        ))
        #expect(!AgentActivityPresentationRouter.shouldPresent(
            notificationObject: NSObject(),
            currentProject: owner,
            isKeyWindow: true
        ))
    }

    @Test("Legacy nil requests are consumed by the key window only")
    func nilRequestUsesKeyWindowFallback() {
        let project = ProjectManager()

        #expect(AgentActivityPresentationRouter.shouldPresent(
            notificationObject: nil,
            currentProject: project,
            isKeyWindow: true
        ))
        #expect(!AgentActivityPresentationRouter.shouldPresent(
            notificationObject: nil,
            currentProject: project,
            isKeyWindow: false
        ))
    }
}

nonisolated private final class AgentActivityNotificationProbe:
    @unchecked Sendable {
    private let lock = NSLock()
    private var objects: [AnyObject?] = []

    var count: Int {
        lock.withLock { objects.count }
    }

    var isEmpty: Bool {
        lock.withLock { objects.isEmpty }
    }

    var lastObject: AnyObject? {
        lock.withLock { objects.last ?? nil }
    }

    func record(_ object: Any?) {
        lock.withLock {
            objects.append(object as AnyObject?)
        }
    }
}
