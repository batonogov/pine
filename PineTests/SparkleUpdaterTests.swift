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
}
