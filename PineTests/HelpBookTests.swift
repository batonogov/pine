//
//  HelpBookTests.swift
//  PineTests
//

import AppKit
import Foundation
import Testing
@testable import Pine

@MainActor
struct HelpBookTests {
    private let helpBookName = "io.github.batonogov.pine.help"
    private let localizations = [
        "en", "de", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans",
    ]
    private let topicSlugs = [
        "getting-started", "workspace", "terminal", "git", "lsp",
        "agents", "settings", "shortcuts", "troubleshooting", "support",
    ]

    @Test func appRegistersNativeHelpBook() {
        #expect(
            Bundle.main.object(
                forInfoDictionaryKey: "CFBundleHelpBookFolder"
            ) as? String == "Pine.help"
        )
        #expect(
            Bundle.main.object(
                forInfoDictionaryKey: "CFBundleHelpBookName"
            ) as? String == helpBookName
        )
        #expect(PineHelp.bookName == helpBookName)
    }

    @Test func helpBookIsPackagedWithTheApplication() throws {
        let helpURL = try #require(
            Bundle.main.url(forResource: "Pine", withExtension: "help")
        )
        let helpBundle = try #require(Bundle(url: helpURL))

        #expect(helpBundle.bundleIdentifier == helpBookName)
        #expect(helpBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "2")
        #expect(
            helpBundle.object(
                forInfoDictionaryKey: "HPDBookAccessPath"
            ) as? String == "index.html"
        )
        #expect(
            helpBundle.object(
                forInfoDictionaryKey: "HPDBookIndexPath"
            ) as? String == "Pine.cshelpindex"
        )
    }

    @Test func everyLocalizationHasTaskTopicsAndSearchIndex() throws {
        let resourcesURL = try helpResourcesURL()

        for localization in localizations {
            let localizationURL = resourcesURL.appending(
                path: "\(localization).lproj",
                directoryHint: .isDirectory
            )
            let indexURL = localizationURL.appending(path: "index.html")
            let indexHTML = try String(
                contentsOf: indexURL,
                encoding: .utf8
            )

            #expect(indexHTML.contains("name=\"ROBOTS\" content=\"ANCHORS\""))
            #expect(indexHTML.contains("name=\"pine-help-home\""))
            #expect(!indexHTML.contains("<script"))

            var localizedTitles = Set<String>()
            for slug in topicSlugs {
                #expect(indexHTML.contains("href=\"\(slug).html\""))

                let topicURL = localizationURL.appending(
                    path: "\(slug).html"
                )
                let topicHTML = try String(
                    contentsOf: topicURL,
                    encoding: .utf8
                )

                #expect(
                    topicHTML.contains(
                        "name=\"AppleTitle\" content=\"\(helpBookName)\""
                    )
                )
                #expect(topicHTML.contains("name=\"description\" content=\""))
                #expect(topicHTML.contains("name=\"KEYWORDS\" content=\""))
                #expect(topicHTML.contains("name=\"pine-\(slug)\""))
                #expect(topicHTML.contains("href=\"index.html\""))
                #expect(!topicHTML.contains("<script"))

                localizedTitles.insert(try title(in: topicHTML))
            }
            #expect(localizedTitles.count == topicSlugs.count)

            let stringsURL = localizationURL.appending(
                path: "InfoPlist.strings"
            )
            let stringsData = try Data(contentsOf: stringsURL)
            let strings = try #require(
                try PropertyListSerialization.propertyList(
                    from: stringsData,
                    format: nil
                ) as? [String: String]
            )
            #expect(!(strings["HPDBookTitle"] ?? "").isEmpty)

            let indexURLForSearch = localizationURL.appending(
                path: "Pine.cshelpindex"
            )
            let attributes = try FileManager.default.attributesOfItem(
                atPath: indexURLForSearch.path
            )
            let indexSize = try #require(attributes[.size] as? NSNumber)
            #expect(indexSize.intValue > 4_000)
        }
    }

    @Test func localizedHelpLinksResolveWithoutNetwork() throws {
        let resourcesURL = try helpResourcesURL()

        for localization in localizations {
            let localizationURL = resourcesURL.appending(
                path: "\(localization).lproj",
                directoryHint: .isDirectory
            )
            let pages = try FileManager.default.contentsOfDirectory(
                at: localizationURL,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "html" }
            #expect(pages.count == topicSlugs.count + 1)

            for page in pages {
                let html = try String(contentsOf: page, encoding: .utf8)
                for link in try links(in: html) {
                    guard !link.hasPrefix("http://"),
                          !link.hasPrefix("https://"),
                          !link.hasPrefix("mailto:") else {
                        continue
                    }
                    let relativePath = link.split(
                        separator: "#",
                        maxSplits: 1
                    ).first.map(String.init) ?? ""
                    guard !relativePath.isEmpty else { continue }

                    let destination = page.deletingLastPathComponent()
                        .appending(path: relativePath)
                    #expect(FileManager.default.fileExists(atPath: destination.path))
                }
            }
        }
    }

    @Test func contextualHelpAnchorsMatchNativeHelpLinks() throws {
        let resourcesURL = try helpResourcesURL()
        let anchors = [
            PineHelp.Anchor.home,
            PineHelp.Anchor.gettingStarted,
            PineHelp.Anchor.workspace,
            PineHelp.Anchor.terminal,
            PineHelp.Anchor.git,
            PineHelp.Anchor.languageServers,
            PineHelp.Anchor.agents,
            PineHelp.Anchor.agentInbox,
            PineHelp.Anchor.agentSettings,
            PineHelp.Anchor.settings,
            PineHelp.Anchor.shortcuts,
            PineHelp.Anchor.troubleshooting,
        ]

        for localization in localizations {
            let localizationURL = resourcesURL.appending(
                path: "\(localization).lproj",
                directoryHint: .isDirectory
            )
            let pages = try FileManager.default.contentsOfDirectory(
                at: localizationURL,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "html" }
            let corpus = try pages.map {
                try String(contentsOf: $0, encoding: .utf8)
            }.joined(separator: "\n")

            for anchor in anchors {
                #expect(corpus.contains("name=\"\(anchor)\""))
            }
        }
    }

    @Test func compactHelpButtonUsesNativeAccessibilityContract() {
        let button = PineNativeHelpButton(
            anchor: PineHelp.Anchor.languageServers,
            book: PineHelp.bookName,
            accessibilityIdentifier: AccessibilityID.problemsHelpButton,
            controlSize: .small
        )

        #expect(button.bezelStyle == .helpButton)
        #expect(button.controlSize == .small)
        #expect(button.isAccessibilityElement())
        #expect(button.accessibilityRole() == .button)
        #expect(
            button.accessibilityIdentifier()
                == AccessibilityID.problemsHelpButton
        )
        #expect(
            button.identifier?.rawValue
                == AccessibilityID.problemsHelpButton
        )
        #expect(button.intrinsicContentSize.width > 0)
        #expect(button.intrinsicContentSize.height > 0)
    }

    private func helpResourcesURL() throws -> URL {
        let helpURL = try #require(
            Bundle.main.url(forResource: "Pine", withExtension: "help")
        )
        return helpURL.appending(
            path: "Contents/Resources",
            directoryHint: .isDirectory
        )
    }

    private func title(in html: String) throws -> String {
        let expression = try NSRegularExpression(
            pattern: #"<title>(.*?)</title>"#
        )
        let range = NSRange(html.startIndex..., in: html)
        let match = try #require(expression.firstMatch(in: html, range: range))
        let titleRange = try #require(Range(match.range(at: 1), in: html))
        return String(html[titleRange])
    }

    private func links(in html: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: #"href="([^"]+)""#)
        let range = NSRange(html.startIndex..., in: html)
        return expression.matches(in: html, range: range).compactMap { match in
            guard let linkRange = Range(match.range(at: 1), in: html) else {
                return nil
            }
            return String(html[linkRange])
        }
    }
}
