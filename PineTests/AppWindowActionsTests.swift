//
//  AppWindowActionsTests.swift
//  PineTests
//
//  The app-lifetime host of SwiftUI's window actions (#1760). Its one
//  load-bearing assumption — that the hidden host window reports its routes
//  on the hand-driven first layout/display pass — is what every
//  AppDelegate-only open (Open panel, Open Recent, notification
//  presentation) stands on. This suite exercises exactly that first pass.
//

import AppKit
import Foundation
import Testing
@testable import Pine

@Suite("App window actions host", .serialized)
@MainActor
struct AppWindowActionsTests {
    private func makeFixture() throws -> WindowActionsFixture {
        try WindowActionsFixture()
    }

    @Test("installing the host reports routes through the first layout pass")
    func installReportsRoutesImmediately() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let delegate = AppDelegate()
        delegate.registry = fixture.registry

        delegate.installWindowActionHost()

        // The hand-driven layout/display pass inside install() is what makes
        // this pass without any visible window. If it ever stops holding,
        // every AppDelegate-only open fails closed while UI tests (which
        // route through Welcome) keep passing — this assertion is the tripwire.
        #expect(delegate.windowActions.projectOpener != nil)
    }

    @Test("an AppDelegate-only open through the host records the explicit-open intent")
    func openProjectSceneRecordsIntent() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let delegate = AppDelegate()
        delegate.registry = fixture.registry
        delegate.installWindowActionHost()

        let url = fixture.projectURL
        #expect(delegate.openProjectScene(url), "the host route, not the absent seam, opens")
        #expect(
            fixture.registry.consumeExplicitProjectOpenRequest(for: url),
            "the funnel recorded the intent before the scene opened (#1543)"
        )
    }

    @Test("openNamedScene falls through to the host without the unit-test seam")
    func openNamedSceneUsesHost() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let delegate = AppDelegate()
        delegate.registry = fixture.registry
        delegate.installWindowActionHost()

        #expect(delegate.openNamedWindow == nil)
        #expect(
            delegate.openNamedScene("welcome"),
            "the host route serves the named scene with no window alive"
        )
    }

    @Test("install is idempotent: a second call keeps the working host")
    func installIsIdempotent() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let delegate = AppDelegate()
        delegate.registry = fixture.registry

        delegate.installWindowActionHost()
        delegate.installWindowActionHost()

        // The second install must not have replaced the reporting host with
        // a second one whose routes never get a display pass.
        let secondURL = fixture.projectURL.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)
        #expect(delegate.openProjectScene(secondURL))
        #expect(fixture.registry.consumeExplicitProjectOpenRequest(for: secondURL))
    }
}

@MainActor
private final class WindowActionsFixture {
    let registry: ProjectRegistry
    let projectURL: URL
    private let suiteName: String
    private let defaults: UserDefaults

    init() throws {
        projectURL = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("PineWindowActions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        suiteName = "AppWindowActionsTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        registry = ProjectRegistry(
            defaults: defaults,
            agentTasks: AgentTaskRegistry(
                accuracyPolicy: AgentLifecycleAccuracyPolicy { _ in
                    .verifiedLifecycleTransitions
                }
            ),
            agentDetectionProcessRunner: { _, _, _, _ in
                ProcessRunResult(stdout: "", stderr: "", exitCode: 0, timedOut: false)
            },
            agentDetectionPollInterval: 3_600,
            agentDetectionInitialPollDelay: 3_600
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: projectURL)
    }
}
