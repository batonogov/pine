//
//  HelpBookTests.swift
//  PineTests
//

import Foundation
import Testing
@testable import Pine

@MainActor
struct HelpBookTests {
    private let helpBookName = "io.github.batonogov.pine.help"
    private let localizations = ["en", "de", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans"]

    @Test func appRegistersNativeHelpBook() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleHelpBookFolder") as? String == "Pine.help")
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleHelpBookName") as? String == helpBookName)
    }

    @Test func helpBookIsPackagedWithTheApplication() throws {
        let helpURL = try #require(Bundle.main.url(forResource: "Pine", withExtension: "help"))
        let helpBundle = try #require(Bundle(url: helpURL))

        #expect(helpBundle.bundleIdentifier == helpBookName)
        #expect(helpBundle.object(forInfoDictionaryKey: "HPDBookAccessPath") as? String == "index.html")
        #expect(helpBundle.object(forInfoDictionaryKey: "HPDBookIndexPath") as? String == "Pine.cshelpindex")
    }

    @Test func everySupportedLocalizationHasContentAndSearchIndex() throws {
        let helpURL = try #require(Bundle.main.url(forResource: "Pine", withExtension: "help"))
        let resourcesURL = helpURL.appending(path: "Contents/Resources", directoryHint: .isDirectory)

        for localization in localizations {
            let localizationURL = resourcesURL.appending(
                path: "\(localization).lproj",
                directoryHint: .isDirectory
            )
            let htmlURL = localizationURL.appending(path: "index.html")
            let stringsURL = localizationURL.appending(path: "InfoPlist.strings")
            let indexURL = localizationURL.appending(path: "Pine.cshelpindex")

            let html = try String(contentsOf: htmlURL, encoding: .utf8)
            #expect(html.contains("name=\"AppleTitle\" content=\"\(helpBookName)\""))
            #expect(html.contains("id=\"getting-started\""))
            #expect(html.contains("id=\"workspace\""))
            #expect(html.contains("id=\"terminal\""))
            #expect(html.contains("id=\"git\""))
            #expect(html.contains("id=\"lsp\""))
            #expect(html.contains("id=\"agents\""))
            #expect(html.contains("id=\"settings\""))
            #expect(html.contains("id=\"shortcuts\""))
            #expect(html.contains("id=\"troubleshooting\""))
            #expect(html.contains("id=\"support\""))
            #expect(html.contains("href=\"../style.css\""))
            #expect(!html.contains("<script"))

            let stringsData = try Data(contentsOf: stringsURL)
            let strings = try #require(
                try PropertyListSerialization.propertyList(from: stringsData, format: nil) as? [String: String]
            )
            #expect(!(strings["HPDBookTitle"] ?? "").isEmpty)

            let attributes = try FileManager.default.attributesOfItem(atPath: indexURL.path)
            let indexSize = try #require(attributes[.size] as? NSNumber)
            #expect(indexSize.intValue > 0)
        }
    }
}
