//
//  AgentInboxToolbarLabelTests.swift
//  PineTests
//
//  Localization coverage for the Agent Inbox toolbar button's tooltip and
//  VoiceOver label (#1337). The attention dot carries no number, so these two
//  strings are the *only* places the exact count reaches the user — these
//  tests pin both the composition and the plural categories.
//

import Foundation
import Testing

@testable import Pine

@Suite("Agent Inbox toolbar label")
@MainActor
struct AgentInboxToolbarLabelTests {

    private let english = Locale(identifier: "en")
    private let russian = Locale(identifier: "ru")
    private let japanese = Locale(identifier: "ja")

    // MARK: - VoiceOver label

    @Test("announces only the name when nothing needs attention")
    func zeroCountOmitsTheAttentionPhrase() {
        let label = AgentInboxToolbarButton.accessibilityLabel(
            attentionCount: 0,
            locale: english
        )
        #expect(label == "Agent Inbox")
    }

    @Test("joins the name and the attention phrase")
    func joinsNameAndAttentionPhrase() {
        let label = AgentInboxToolbarButton.accessibilityLabel(
            attentionCount: 2,
            locale: english
        )
        #expect(label == "Agent Inbox, 2 tasks need attention")
    }

    @Test("uses the singular form for a single task")
    func singularForOneTask() {
        let label = AgentInboxToolbarButton.accessibilityLabel(
            attentionCount: 1,
            locale: english
        )
        #expect(label == "Agent Inbox, 1 task needs attention")
    }

    /// The dot looks identical at 3 and at 150, so a screen-reader user must
    /// still hear the real number — there is no visual fallback.
    @Test("announces large counts verbatim")
    func announcesLargeCountsVerbatim() {
        let label = AgentInboxToolbarButton.accessibilityLabel(
            attentionCount: 150,
            locale: english
        )
        #expect(label == "Agent Inbox, 150 tasks need attention")
    }

    /// A negative count cannot occur through `ProjectRegistry`, but the view
    /// is a pure function of its input and must not claim attention for one.
    @Test("treats a negative count as no attention")
    func negativeCountIsTreatedAsZero() {
        let label = AgentInboxToolbarButton.accessibilityLabel(
            attentionCount: -1,
            locale: english
        )
        #expect(label == "Agent Inbox")
    }

    // MARK: - Tooltip

    @Test("tooltip states only the action when nothing needs attention")
    func tooltipWithoutAttention() {
        let tooltip = AgentInboxToolbarButton.tooltip(
            attentionCount: 0,
            locale: english
        )
        #expect(tooltip == "Open the Agent Inbox")
    }

    @Test("tooltip carries the exact count the dot cannot show")
    func tooltipCarriesTheCount() {
        let tooltip = AgentInboxToolbarButton.tooltip(
            attentionCount: 150,
            locale: english
        )
        #expect(tooltip == "Open the Agent Inbox, 150 tasks need attention")
    }

    /// The tooltip names the same surface as the window title; a drift between
    /// them reads as two different features.
    @Test("tooltip agrees with the inbox name in every shipped language")
    func tooltipMatchesInboxName() throws {
        let languages = [
            "de", "en", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans",
        ]
        for language in languages {
            let locale = Locale(identifier: language)
            let name = Strings.agentInboxTitleText(locale: locale)
            let tooltip = Strings.agentInboxToolbarTooltipText(locale: locale)
            #expect(
                tooltip.localizedCaseInsensitiveContains(name),
                "\(language): tooltip \"\(tooltip)\" should name \"\(name)\""
            )
        }
    }

    // MARK: - Localization

    @Test("uses the localized inbox name")
    func usesLocalizedName() {
        let label = AgentInboxToolbarButton.accessibilityLabel(
            attentionCount: 1,
            locale: russian
        )
        #expect(label.hasPrefix("Входящие от агентов"))
        #expect(label.contains("1 задача требует внимания"))
    }

    /// Russian distinguishes one/few/many where English has only one/other.
    /// A count-agnostic format would read "5 задача" — assert all three.
    @Test("selects Russian one/few/many plural categories")
    func russianPluralCategories() {
        #expect(
            Strings.agentInboxToolbarAttentionCount(1, locale: russian)
                == "1 задача требует внимания"
        )
        #expect(
            Strings.agentInboxToolbarAttentionCount(3, locale: russian)
                == "3 задачи требуют внимания"
        )
        #expect(
            Strings.agentInboxToolbarAttentionCount(5, locale: russian)
                == "5 задач требуют внимания"
        )
        // 21 is `one` in Russian, unlike 11 which is `many`.
        #expect(
            Strings.agentInboxToolbarAttentionCount(21, locale: russian)
                == "21 задача требует внимания"
        )
        #expect(
            Strings.agentInboxToolbarAttentionCount(11, locale: russian)
                == "11 задач требуют внимания"
        )
    }

    /// Japanese has a single plural category; the label must still compose.
    @Test("composes for a language without plural categories")
    func japaneseComposes() {
        let label = AgentInboxToolbarButton.accessibilityLabel(
            attentionCount: 2,
            locale: japanese
        )
        #expect(label.hasPrefix("エージェント受信トレイ"))
        #expect(label.contains("2"))
    }
}
