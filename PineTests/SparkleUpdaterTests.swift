//
//  SparkleUpdaterTests.swift
//  PineTests
//

import Testing
import Foundation
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

    // MARK: - AppDelegate Sparkle configuration

    @Test func configuredFeedURLMatchesAppcastURL() {
        #expect(
            AppDelegate.configuredFeedURLString
                == SparkleConstants.appcastURLString
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
        let testSourceRoot = repositoryRoot.appendingPathComponent("PineTests")
        let productionSource = try swiftSource(in: sourceRoot)
        let testSource = try swiftSource(
            in: testSourceRoot,
            excluding: URL(fileURLWithPath: #filePath)
        )
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
            productionSource.components(
                separatedBy: "SPUStandardUpdaterController("
            ).count - 1 == 1
        )
        #expect(!productionSource.contains("SPU" + "Updater("))
        #expect(!testSource.contains("SPU" + "Updater("))
        #expect(!testSource.contains("SPU" + "StandardUpdaterController("))
        #expect(!testSource.contains(".updater" + "Controller"))
        #expect(!testSource.contains(
            ".checkForUpdates" + "ViewModel"
        ))
        #expect(appSource.contains(
            "lazy var updaterController = SPUStandardUpdaterController("
        ))
        #expect(appSource.contains("startingUpdater: true"))
        #expect(appSource.contains("updaterDelegate: self"))
        #expect(appSource.contains("userDriverDelegate: nil"))
        #expect(appSource.contains(
            "lazy var checkForUpdatesViewModel = CheckForUpdatesViewModel("
        ))
        #expect(appSource.contains("updater: updaterController.updater"))
        #expect(menuSource.contains(
            "CheckForUpdatesView("
                + "viewModel: checkForUpdatesViewModel"
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

    private func swiftSource(
        in sourceRoot: URL,
        excluding excludedFile: URL? = nil
    ) throws -> String {
        // An empty scan would make every "the source does not contain X"
        // assertion below trivially true, so the scan throws instead (#1508).
        let sourceURLs = try ProductionSourceScan.swiftFileURLs(
            under: sourceRoot
        )

        var source = ""
        for fileURL in sourceURLs {
            guard fileURL.standardizedFileURL
                != excludedFile?.standardizedFileURL else {
                continue
            }
            source += try String(contentsOf: fileURL, encoding: .utf8)
        }
        return source
    }
}

@MainActor
private final class UpdateCheckProbe {
    private(set) var requestCount = 0

    func record() {
        requestCount += 1
    }
}
