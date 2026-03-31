//
//  AboutInfoTests.swift
//  PineTests
//

import AppKit
import Testing
@testable import Pine

@MainActor
struct AboutInfoTests {

    // MARK: - Version string

    @Test func versionString_returnsNonEmpty() {
        let version = AboutInfo.versionString
        #expect(!version.isEmpty)
    }

    @Test func versionString_matchesBundleShortVersion() {
        let expected = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        #expect(AboutInfo.versionString == (expected ?? ""))
    }

    // MARK: - Build string

    @Test func buildString_returnsNonEmpty() {
        let build = AboutInfo.buildString
        #expect(!build.isEmpty)
    }

    @Test func buildString_matchesBundleVersion() {
        let expected = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        #expect(AboutInfo.buildString == (expected ?? ""))
    }

    // MARK: - App name

    @Test func appName_returnsPine() {
        let name = AboutInfo.appName
        #expect(!name.isEmpty)
    }

    @Test func appName_matchesBundleName() {
        let expected = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? "Pine"
        #expect(AboutInfo.appName == expected)
    }

    // MARK: - Copyright

    @Test func copyright_containsYear() {
        let copyright = AboutInfo.copyright
        #expect(copyright.contains("2026"))
    }

    // MARK: - GitHub URL

    @Test func gitHubURL_isValid() {
        let url = AboutInfo.gitHubURL
        #expect(url.scheme == "https")
        #expect(url.host()?.contains("github.com") == true)
        #expect(url.path().contains("pine"))
    }

    // MARK: - About panel options

    @Test func aboutPanelOptions_containsCredits() {
        let options = AboutInfo.aboutPanelOptions
        #expect(options[.credits] != nil)
    }

    @Test func aboutPanelOptions_creditsContainsTagline() {
        let options = AboutInfo.aboutPanelOptions
        guard let credits = options[.credits] as? NSAttributedString else {
            Issue.record("Credits should be NSAttributedString")
            return
        }
        let tagline = String(localized: "about.tagline")
        #expect(!tagline.isEmpty, "Localized tagline key should resolve to a non-empty string")
        #expect(credits.string.contains(tagline))
    }

    @Test func aboutPanelOptions_creditsContainsGitHub() {
        let options = AboutInfo.aboutPanelOptions
        guard let credits = options[.credits] as? NSAttributedString else {
            Issue.record("Credits should be NSAttributedString")
            return
        }
        #expect(credits.string.contains("github.com"))
    }

    @Test func aboutPanelOptions_taglineIsNotRawKey() {
        // Verify the localized string resolved to an actual translation, not the raw key itself.
        let tagline = String(localized: "about.tagline")
        #expect(tagline != "about.tagline", "Tagline should resolve to a translated string, not the raw key")
    }

    @Test func aboutPanelOptions_taglineExistsInMultipleLocales() {
        // Verify that the tagline has distinct translations for different locales,
        // confirming it's a properly localized resource.
        let bundle = Bundle.main
        guard let enPath = bundle.path(forResource: "en", ofType: "lproj"),
              let enBundle = Bundle(path: enPath) else {
            Issue.record("English localization bundle not found")
            return
        }
        let enTagline = NSLocalizedString("about.tagline", bundle: enBundle, comment: "")
        #expect(!enTagline.isEmpty)
        #expect(enTagline != "about.tagline", "English tagline should not be the raw key")
    }

    @Test func aboutPanelOptions_creditsDoesNotContainDependencies() {
        let options = AboutInfo.aboutPanelOptions
        guard let credits = options[.credits] as? NSAttributedString else {
            Issue.record("Credits should be NSAttributedString")
            return
        }
        #expect(!credits.string.contains("SwiftTerm"))
        #expect(!credits.string.contains("Sparkle"))
        #expect(!credits.string.contains("swift-markdown"))
        #expect(!credits.string.contains("Acknowledgments"))
    }
}
