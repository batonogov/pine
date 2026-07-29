//
//  SparkleUpdaterTests.swift
//  PineTests
//

import Testing
import Foundation
import Sparkle
@testable import Pine

@Suite("Sparkle Updater Tests")
struct SparkleUpdaterTests {

    // MARK: - Appcast URL

    @Test func appcastURLIsValid() {
        let urlString = SparkleConstants.appcastURLString
        #expect(URL(string: urlString) != nil)
    }

    @Test func appcastURLPointsToGitHubReleases() {
        let urlString = SparkleConstants.appcastURLString
        #expect(urlString.hasPrefix("https://github.com/batonogov/pine/releases/"))
        #expect(urlString.hasSuffix("appcast.xml"))
    }

    @Test func appcastURLUsesLatestDownload() {
        let urlString = SparkleConstants.appcastURLString
        #expect(urlString.contains("latest/download"))
    }

    // MARK: - SUPublicEDKey in Info.plist

    @Test func publicEDKeyPresentInBundle() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        #expect(key != nil, "SUPublicEDKey must be present in Info.plist")
    }

    @Test func publicEDKeyIsNonEmpty() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        #expect(key?.isEmpty == false, "SUPublicEDKey must not be empty")
    }

    @Test func publicEDKeyIsValidBase64() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let decoded = Data(base64Encoded: key)
        #expect(decoded != nil, "SUPublicEDKey must be valid base64")
        // Ed25519 public key is 32 bytes
        #expect(decoded?.count == 32, "Ed25519 public key must be 32 bytes")
    }

    // MARK: - AppDelegate SPUUpdaterDelegate

    @MainActor
    @Test func feedURLStringReturnsAppcastURL() {
        let delegate = AppDelegate()
        let feedURL = delegate.feedURLString(for: delegate.updaterController.updater)
        #expect(feedURL == SparkleConstants.appcastURLString)
    }

    @MainActor
    @Test func updaterRuntimeIsAppScoped() {
        let delegate = AppDelegate()

        #expect(delegate.updaterController === delegate.updaterController)
        #expect(
            delegate.checkForUpdatesViewModel
                === delegate.checkForUpdatesViewModel
        )
    }

    @MainActor
    @Test func unavailableUpdaterRejectsCheckRequest() {
        let probe = UpdateCheckProbe()
        let viewModel = CheckForUpdatesViewModel(
            canCheckForUpdates: false,
            checkForUpdatesAction: probe.record
        )

        viewModel.checkForUpdates()

        #expect(probe.requestCount == 0)
        #expect(!viewModel.canCheckForUpdates)
    }

    @MainActor
    @Test func acceptedCheckDisablesDuplicateRequest() {
        let probe = UpdateCheckProbe()
        let viewModel = CheckForUpdatesViewModel(
            canCheckForUpdates: true,
            checkForUpdatesAction: probe.record
        )

        viewModel.checkForUpdates()
        viewModel.checkForUpdates()

        #expect(probe.requestCount == 1)
        #expect(!viewModel.canCheckForUpdates)
    }

    @Test func productionUsesOnlyStandardSparkleController() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = repositoryRoot.appendingPathComponent("Pine")
        let appSource = try String(
            contentsOf: sourceRoot.appendingPathComponent("PineApp.swift"),
            encoding: .utf8
        )
        let menuSource = try String(
            contentsOf: sourceRoot.appendingPathComponent(
                "PineAppMenuCommands.swift"
            ),
            encoding: .utf8
        )

        #expect(
            appSource.components(
                separatedBy: "SPUStandardUpdaterController("
            ).count - 1 == 1
        )
        #expect(appSource.contains("userDriverDelegate: nil"))
        #expect(menuSource.contains(
            "CheckForUpdatesView("
                + "viewModel: appDelegate.checkForUpdatesViewModel"
        ))
        #expect(!FileManager.default.fileExists(
            atPath: sourceRoot
                .appendingPathComponent("UpdateCoordinator.swift")
                .path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: sourceRoot
                .appendingPathComponent("PineUserDriver.swift")
                .path
        ))
    }
}

@MainActor
private final class UpdateCheckProbe {
    private(set) var requestCount = 0

    func record() {
        requestCount += 1
    }
}
