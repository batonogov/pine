//
//  SettingsWindowMetricsTests.swift
//  PineTests
//
//  Issue #1531: the Settings window was pinned to 720 pt in five files. Five
//  localized tab titles have to share that width, and neither SwiftUI's macOS
//  `TabView` nor AppKit reports the tab strip as part of the view's intrinsic
//  size — an overlong strip is truncated with no overflow signal at all. These
//  tests pin the arithmetic that replaces the constant, and then pin the real
//  `PineSettingsView` to the size that arithmetic demands.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("Settings window metrics", .serialized)
@MainActor
struct SettingsWindowMetricsTests {
    /// The width every Settings surface was pinned to before #1531.
    private static let legacyPinnedWidth: CGFloat = 720

    /// The nine shipped localizations, per `AGENTS.md`.
    private static let shippedLocales = [
        "en", "de", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans",
    ]

    /// SF Symbols the five `.tabItem` labels draw, in catalog order.
    private static let tabSymbols = [
        "gearshape", "terminal", "server.rack", "lock.shield", "keyboard",
    ]

    // MARK: - Catalog input

    @Test("Tab titles resolve per locale instead of falling back to English")
    func tabTitlesResolvePerLocale() {
        #expect(
            titles("en") == [
                "General",
                "Terminal",
                "Language Servers",
                "Agent Handoff",
                "Key Bindings & Tasks",
            ]
        )
        #expect(
            titles("ru") == [
                "Основные",
                "Терминал",
                "Языковые серверы",
                "Передача контекста",
                "Сочетания клавиш и задачи",
            ]
        )
        #expect(
            titles("de") == [
                "Allgemein",
                "Terminal",
                "Sprachserver",
                "Agent-Übergabe",
                "Tastenkürzel & Aufgaben",
            ]
        )
        for identifier in Self.shippedLocales {
            #expect(
                titles(identifier).count == 5,
                "\(identifier) must translate all five Settings tabs"
            )
            #expect(titles(identifier).allSatisfy { !$0.isEmpty })
        }
    }

    // MARK: - The defect, stated as arithmetic

    @Test("German and Russian tab strips overflow the legacy 720 pt window")
    func wideLocalesOverflowLegacyWidth() {
        for identifier in ["de", "ru"] {
            let strip = SettingsWindowMetrics.tabStripWidth(
                forTabTitles: titles(identifier)
            )
            #expect(
                strip > Self.legacyPinnedWidth,
                """
                \(identifier) needs \(strip) pt of tab strip, which is why the \
                720 pt pin truncated it
                """
            )
        }
    }

    @Test("Every shipped locale gets a floor wide enough for its own strip")
    func floorCoversEveryShippedLocale() {
        for identifier in Self.shippedLocales {
            let localized = titles(identifier)
            let strip = SettingsWindowMetrics.tabStripWidth(
                forTabTitles: localized
            )
            let floor = SettingsWindowMetrics.minimumWidth(
                forTabTitles: localized
            )
            #expect(
                floor >= strip,
                "\(identifier) would truncate: floor \(floor) < strip \(strip)"
            )
        }
    }

    @Test("English keeps the historical 720 pt width")
    func englishKeepsTheBaselineWidth() {
        #expect(
            SettingsWindowMetrics.minimumWidth(forTabTitles: titles("en"))
                == SettingsWindowMetrics.baselineWidth
        )
        #expect(SettingsWindowMetrics.baselineWidth == Self.legacyPinnedWidth)
    }

    @Test("The floor is monotonic in title length")
    func floorGrowsWithTitleLength() {
        let narrow = SettingsWindowMetrics.tabStripWidth(
            forTabTitles: titles("en")
        )
        let wide = SettingsWindowMetrics.tabStripWidth(
            forTabTitles: titles("ru")
        )
        #expect(wide > narrow)
        #expect(
            SettingsWindowMetrics.minimumWidth(forTabTitles: titles("ru"))
                > SettingsWindowMetrics.minimumWidth(forTabTitles: titles("en"))
        )
    }

    @Test("An empty strip still yields the baseline floor")
    func emptyTitlesFallBackToBaseline() {
        #expect(SettingsWindowMetrics.tabStripWidth(forTabTitles: []) == 0)
        #expect(
            SettingsWindowMetrics.minimumWidth(forTabTitles: [])
                == SettingsWindowMetrics.baselineWidth
        )
    }

    // MARK: - The estimate, pinned to what SwiftUI actually draws

    @Test("The symbol allowance covers the icon SwiftUI renders in a Label")
    func symbolAllowanceCoversRenderedLabels() {
        for identifier in Self.shippedLocales {
            for (title, symbol) in zip(titles(identifier), Self.tabSymbols) {
                let text = hostedWidth(Text(verbatim: title))
                let label = hostedWidth(Label(title, systemImage: symbol))
                #expect(
                    label - text <= SettingsWindowMetrics.tabItemSymbolAllowance,
                    """
                    \(identifier)/\(symbol) spends \(label - text) pt on its \
                    icon, above the \(SettingsWindowMetrics
                        .tabItemSymbolAllowance) pt allowance
                    """
                )
            }
        }
    }

    @Test("A measured tab item is at least as wide as its rendered Label")
    func tabItemWidthCoversRenderedLabel() {
        for identifier in Self.shippedLocales {
            for (title, symbol) in zip(titles(identifier), Self.tabSymbols) {
                #expect(
                    SettingsWindowMetrics.tabItemWidth(for: title)
                        >= hostedWidth(Label(title, systemImage: symbol)),
                    "\(identifier)/\(symbol) measures narrower than it draws"
                )
            }
        }
    }

    // MARK: - The real window

    @Test("Settings grows past 720 pt for the locales that need it")
    func settingsWindowAdoptsTheLocalizedFloor() throws {
        for identifier in ["de", "ru"] {
            let expected = SettingsWindowMetrics.minimumWidth(
                forTabTitles: titles(identifier)
            )
            let rendered = try hostedSettingsWidth(locale: identifier)
            #expect(
                rendered >= expected,
                """
                Settings renders \(rendered) pt wide in \(identifier) but its \
                tab strip needs \(expected) pt
                """
            )
            #expect(
                rendered > Self.legacyPinnedWidth,
                "Settings is still pinned to \(Self.legacyPinnedWidth) pt"
            )
        }
    }

    @Test("Settings still opens at exactly 720 pt in English")
    func settingsWindowKeepsBaselineInEnglish() throws {
        #expect(
            try hostedSettingsWidth(locale: "en")
                == SettingsWindowMetrics.baselineWidth
        )
    }

    @Test("Settings height is a floor, not a pin")
    func settingsWindowHeightIsAFloor() throws {
        let host = try hostedSettings(locale: "en")
        #expect(host.fittingSize.height == SettingsWindowMetrics.baselineHeight)

        let offered = NSSize(
            width: SettingsWindowMetrics.baselineWidth + 180,
            height: SettingsWindowMetrics.baselineHeight + 180
        )
        let grown = NSHostingController(
            rootView: AnyView(try makeSettingsView(locale: "en"))
        )
        .sizeThatFits(in: offered)
        #expect(
            grown.height == offered.height,
            """
            Settings reports \(grown.height) pt inside a \(offered.height) pt \
            window — its height is still pinned
            """
        )
    }

    @Test("Every pane fills a window wider than the baseline")
    func panesFillAWiderWindow() throws {
        let offered = NSSize(
            width: SettingsWindowMetrics.baselineWidth + 180,
            height: SettingsWindowMetrics.paneMinimumHeight
        )
        let defaults = try isolatedDefaults()

        let panes: [(String, any View)] = [
            (
                "General",
                GeneralSettingsView(
                    editor: EditorSettings(defaults: defaults),
                    fontSizeSettings: FontSizeSettings(defaults: defaults),
                    defaults: defaults
                )
            ),
            (
                "Terminal",
                TerminalSettingsView(
                    shell: ShellSettings(
                        defaults: defaults,
                        defaultShellPath: "/bin/zsh"
                    ),
                    theme: TerminalThemeSettings(defaults: defaults),
                    cursor: TerminalCursorSettings(defaults: defaults),
                    quickTerminal: QuickTerminalSettings(defaults: defaults)
                )
            ),
            (
                "Language Servers",
                LSPSettingsView(settings: LSPSettings(defaults: defaults))
            ),
            ("Key Bindings & Tasks", KeyBindingsTasksSettingsView()),
        ]

        for (name, pane) in panes {
            let width = paneWidth(pane, offered: offered)
            #expect(
                width == offered.width,
                """
                The \(name) pane reports \(width) pt inside a \
                \(offered.width) pt window — it is still pinning its own width
                """
            )
        }
    }

    // MARK: - Helpers

    private func paneWidth(_ pane: any View, offered: NSSize) -> CGFloat {
        NSHostingController(rootView: AnyView(pane))
            .sizeThatFits(in: offered)
            .width
    }

    private func titles(_ identifier: String) -> [String] {
        Strings.settingsTabTitles(locale: Locale(identifier: identifier))
    }

    private func hostedWidth(_ view: some View) -> CGFloat {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    private func hostedSettingsWidth(locale identifier: String) throws
        -> CGFloat {
        try hostedSettings(locale: identifier).fittingSize.width
    }

    private func hostedSettings(locale identifier: String) throws
        -> NSHostingView<some View> {
        let host = NSHostingView(
            rootView: try makeSettingsView(locale: identifier)
        )
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func makeSettingsView(locale identifier: String) throws
        -> some View {
        let defaults = try isolatedDefaults()
        let registry = AgentTaskRegistry()
        return PineSettingsView(
            lspSettings: LSPSettings(defaults: defaults),
            handoffSettings: AgentHandoffSettings(defaults: defaults),
            notificationController: AgentNotificationController(
                registry: registry,
                settings: AgentNotificationSettings(defaults: defaults),
                delivery: InertNotificationDelivery(),
                isPresented: { _ in false },
                openTask: { _ in }
            ),
            agentTasks: registry,
            shellSettings: ShellSettings(
                defaults: defaults,
                defaultShellPath: "/bin/zsh"
            ),
            editorSettings: EditorSettings(defaults: defaults),
            terminalThemeSettings: TerminalThemeSettings(defaults: defaults),
            terminalCursorSettings: TerminalCursorSettings(defaults: defaults),
            quickTerminalSettings: QuickTerminalSettings(defaults: defaults)
        )
        .environment(\.locale, Locale(identifier: identifier))
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suiteName = "SettingsWindowMetricsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

/// Never touches `UNUserNotificationCenter`; the metrics suite only needs the
/// Agents pane to build a view tree.
@MainActor
private final class InertNotificationDelivery: AgentNotificationDelivering {
    var responseHandler: ((AgentNotificationResponseAction) -> Void)?

    func registerActions() {}

    func authorizationStatus() async -> AgentNotificationAuthorizationStatus {
        .denied
    }

    func requestAuthorization() async throws -> Bool { false }

    func deliver(_ request: AgentNotificationRequest) async throws {}
}
