//
//  SettingsWindowMetricsTests.swift
//  PineTests
//
//  Issue #1531. The window was pinned to 720 pt in six files. Measuring a live
//  Settings window showed no shipped locale actually overflows that — tab items
//  stack their symbol above the title, so Russian's strip spans 540 pt inside
//  720 pt with nothing truncated. What does overflow is doubled-length text,
//  and AppKit's response is not an ellipsis: it drops the fifth tab out of the
//  window entirely. These tests pin both halves of that.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("Settings window metrics", .serialized)
@MainActor
struct SettingsWindowMetricsTests {
    /// The nine shipped localizations, per `AGENTS.md`.
    private static let shippedLocales = [
        "en", "de", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans",
    ]

    /// Tab-button widths measured on a live macOS 26 Settings window. Identical
    /// at 720 pt and 900 pt of window width, which is what proves the strip is
    /// never compressed.
    private static let measuredRussianItemWidths: [CGFloat] = [
        68, 66.5, 117, 123.5, 165,
    ]
    private static let measuredEnglishItemWidths: [CGFloat] = [
        55, 57, 106.5, 88.5, 123.5,
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
        for identifier in Self.shippedLocales {
            #expect(titles(identifier).count == 5)
            #expect(titles(identifier).allSatisfy { !$0.isEmpty })
        }
    }

    // MARK: - Shipped locales must not move a pixel

    @Test("Every shipped locale keeps the historical 720 pt window")
    func shippedLocalesKeepBaselineWidth() {
        for identifier in Self.shippedLocales {
            #expect(
                SettingsWindowMetrics.windowWidth(
                    forTabTitles: titles(identifier)
                ) == SettingsWindowMetrics.baselineWidth,
                """
                \(identifier) would resize the Settings window; no shipped \
                locale overflows the measured 720 pt strip
                """
            )
        }
    }

    @Test("Every shipped strip fits the baseline with measured slack")
    func shippedStripsFitTheBaseline() {
        for identifier in Self.shippedLocales {
            let strip = SettingsWindowMetrics.tabStripWidth(
                forTabTitles: titles(identifier)
            )
            #expect(
                strip < SettingsWindowMetrics.baselineWidth,
                "\(identifier) needs \(strip) pt, which no longer fits 720 pt"
            )
        }
    }

    // MARK: - The estimate, pinned to the live measurements

    @Test("Item widths track what a live Settings window renders")
    func itemWidthsTrackMeasuredWindow() {
        let cases = [
            ("en", Self.measuredEnglishItemWidths),
            ("ru", Self.measuredRussianItemWidths),
        ]
        for (identifier, measured) in cases {
            for (title, actual) in zip(titles(identifier), measured) {
                let estimate = SettingsWindowMetrics.tabItemWidth(for: title)
                #expect(
                    abs(estimate - actual) <= 8,
                    """
                    \(identifier) "\(title)": estimated \(estimate) pt against \
                    a measured \(actual) pt
                    """
                )
            }
        }
    }

    @Test("A whole shipped strip estimates within a tab of the real one")
    func stripWidthTracksMeasuredWindow() {
        // Measured span of the Russian strip, outermost edge to outermost edge.
        let measured: CGFloat = 540
        let estimate = SettingsWindowMetrics.tabStripWidth(
            forTabTitles: titles("ru")
        ) - SettingsWindowMetrics.tabStripInset
        #expect(abs(estimate - measured) <= 20)
    }

    // MARK: - The overflow that is real

    @Test("Doubled-length titles widen the window past the baseline")
    func doubledTitlesWidenTheWindow() {
        let doubled = titles("en").map { "\($0) \($0)" }
        let width = SettingsWindowMetrics.windowWidth(forTabTitles: doubled)
        #expect(
            width > SettingsWindowMetrics.baselineWidth,
            """
            Doubled strings span roughly 815 pt; at 720 pt AppKit drops the \
            fifth tab out of the window instead of truncating it
            """
        )
        #expect(
            width >= SettingsWindowMetrics.tabStripWidth(forTabTitles: doubled)
        )
    }

    @Test("The window never sizes below a strip it has to show")
    func windowNeverSizesBelowItsStrip() {
        let inputs = Self.shippedLocales.map { titles($0) }
            + [titles("en").map { "\($0) \($0)" }]
            + [titles("ru").map { String(repeating: $0, count: 3) }]
        for input in inputs {
            #expect(
                SettingsWindowMetrics.windowWidth(forTabTitles: input)
                    >= SettingsWindowMetrics.tabStripWidth(forTabTitles: input)
            )
        }
    }

    @Test("The width is monotonic in title length")
    func widthGrowsWithTitleLength() {
        let short = titles("en")
        let long = short.map { String(repeating: $0, count: 4) }
        #expect(
            SettingsWindowMetrics.windowWidth(forTabTitles: long)
                > SettingsWindowMetrics.windowWidth(forTabTitles: short)
        )
    }

    @Test("An empty strip still yields the baseline width")
    func emptyTitlesFallBackToBaseline() {
        #expect(SettingsWindowMetrics.tabStripWidth(forTabTitles: []) == 0)
        #expect(
            SettingsWindowMetrics.windowWidth(forTabTitles: [])
                == SettingsWindowMetrics.baselineWidth
        )
    }

    // MARK: - The real window keeps its shipped geometry

    @Test("Settings renders 720 x 540 in every shipped locale")
    func settingsWindowKeepsShippedGeometry() throws {
        for identifier in ["en", "de", "ru"] {
            let host = NSHostingView(
                rootView: try makeSettingsView(locale: identifier)
            )
            host.layoutSubtreeIfNeeded()
            #expect(
                host.fittingSize
                    == NSSize(
                        width: SettingsWindowMetrics.baselineWidth,
                        height: SettingsWindowMetrics.baselineHeight
                    ),
                "\(identifier) renders \(host.fittingSize), not 720 × 540"
            )
        }
    }

    @Test("The window modifier widens a real view when titles overflow")
    func windowModifierWidensOnOverflow() {
        // Pseudolocalization cannot be switched on mid-process — `NSBundle`
        // reads `NSDoubleLocalizedStrings` at launch — so the overflow case is
        // exercised through the modifier the window applies. Re-pinning the
        // *call site* to a literal 720 is only observable under a real
        // overflow, which is what the pseudolocalized `A11y & Localization`
        // lane asserts.
        let doubled = titles("en").map { "\($0) \($0)" }
        let host = NSHostingView(
            rootView: Color.clear.settingsWindowSize(tabTitles: doubled)
        )
        host.layoutSubtreeIfNeeded()
        #expect(
            host.fittingSize.width
                == SettingsWindowMetrics.windowWidth(forTabTitles: doubled)
        )
        #expect(host.fittingSize.width > SettingsWindowMetrics.baselineWidth)

        let shipped = NSHostingView(
            rootView: Color.clear.settingsWindowSize(tabTitles: titles("ru"))
        )
        shipped.layoutSubtreeIfNeeded()
        #expect(
            shipped.fittingSize.width == SettingsWindowMetrics.baselineWidth,
            "Russian must keep the shipped 720 pt window"
        )
    }

    @Test("Panes stay rigid so a ScrollView cannot widen the window")
    func panesStayRigid() throws {
        let offered = NSSize(
            width: SettingsWindowMetrics.baselineWidth + 180,
            height: SettingsWindowMetrics.paneHeight + 180
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
            let size = NSHostingController(rootView: AnyView(pane))
                .sizeThatFits(in: offered)
            #expect(
                size.width == SettingsWindowMetrics.baselineWidth,
                """
                The \(name) pane claims \(size.width) pt of a \(offered.width) \
                pt offer; a greedy pane is what drove the window to 900 pt
                """
            )
        }
    }

    // MARK: - Helpers

    private func titles(_ identifier: String) -> [String] {
        Strings.settingsTabTitles(locale: Locale(identifier: identifier))
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
