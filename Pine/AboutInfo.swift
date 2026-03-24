//
//  AboutInfo.swift
//  Pine
//
//  Provides app metadata for the About panel.
//

import AppKit

enum AboutInfo {

    /// App display name from the bundle.
    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? "Pine"
    }

    /// Marketing version (e.g. "1.10.1").
    static var versionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// Build number (e.g. "42").
    static var buildString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    /// Human-readable copyright line.
    static var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "Copyright \u{00A9} 2026 Fedor Batonogov"
    }

    // GitHub repository URL.
    // swiftlint:disable:next force_unwrapping
    static let gitHubURL = URL(string: "https://github.com/batonogov/pine")!

    /// Options dictionary for `orderFrontStandardAboutPanel(options:)`.
    static var aboutPanelOptions: [NSApplication.AboutPanelOptionKey: Any] {
        [
            .credits: creditsAttributedString
        ]
    }

    /// Builds the credits attributed string with acknowledgments and links.
    private static var creditsAttributedString: NSAttributedString {
        let credits = NSMutableAttributedString()

        let bodyFont = NSFont.systemFont(ofSize: 11)
        let linkFont = NSFont.systemFont(ofSize: 11)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.paragraphSpacing = 6

        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle
        ]

        credits.append(NSAttributedString(
            string: "Built with SwiftUI + AppKit\n",
            attributes: bodyAttrs
        ))

        credits.append(NSAttributedString(
            string: "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 4)]
        ))

        // Acknowledgments
        let ackHeader: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
        credits.append(NSAttributedString(string: "Acknowledgments\n", attributes: ackHeader))

        let dependencies = [
            ("SwiftTerm", "https://github.com/migueldeicaza/SwiftTerm"),
            ("Sparkle", "https://github.com/sparkle-project/Sparkle"),
            ("swift-markdown", "https://github.com/swiftlang/swift-markdown")
        ]

        for (name, urlString) in dependencies {
            var linkAttrs = bodyAttrs
            linkAttrs[.link] = URL(string: urlString)
            linkAttrs[.font] = linkFont
            credits.append(NSAttributedString(string: name, attributes: linkAttrs))
            credits.append(NSAttributedString(string: "\n", attributes: bodyAttrs))
        }

        credits.append(NSAttributedString(
            string: "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 4)]
        ))

        // GitHub link
        var ghAttrs = bodyAttrs
        ghAttrs[.link] = gitHubURL
        credits.append(NSAttributedString(string: "github.com/batonogov/pine", attributes: ghAttrs))
        credits.append(NSAttributedString(string: "\n", attributes: bodyAttrs))

        return credits
    }

    /// Shows the standard macOS About panel with custom credits.
    static func showAboutPanel() {
        NSApplication.shared.activate()
        NSApplication.shared.orderFrontStandardAboutPanel(options: aboutPanelOptions)
    }
}
