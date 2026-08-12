//
//  TerminalCursorSettings.swift
//  Pine
//
//  Persisted terminal cursor shape and blinking preferences (#1409).
//

import Foundation
import SwiftTerm

/// User-facing cursor shapes. Blinking is modelled separately so changing the
/// shape never changes the user's blink preference (and vice versa).
enum TerminalCursorShape: CaseIterable, Hashable, Sendable {
    case verticalBar
    case block
    case underline

    /// Localization key for the shape's human-readable name.
    var nameKey: String {
        switch self {
        case .verticalBar:
            return "terminal.cursor.shape.verticalBar"
        case .block:
            return "terminal.cursor.shape.block"
        case .underline:
            return "terminal.cursor.shape.underline"
        }
    }

    /// Combines this shape with the independent blink preference using
    /// SwiftTerm's six concrete cursor styles.
    func cursorStyle(blinks: Bool) -> CursorStyle {
        switch (self, blinks) {
        case (.verticalBar, true):
            return .blinkBar
        case (.verticalBar, false):
            return .steadyBar
        case (.block, true):
            return .blinkBlock
        case (.block, false):
            return .steadyBlock
        case (.underline, true):
            return .blinkUnderline
        case (.underline, false):
            return .steadyUnderline
        }
    }

    /// Extracts Pine's shape dimension from a concrete SwiftTerm style.
    init(cursorStyle: CursorStyle) {
        switch cursorStyle {
        case .blinkBar, .steadyBar:
            self = .verticalBar
        case .blinkBlock, .steadyBlock:
            self = .block
        case .blinkUnderline, .steadyUnderline:
            self = .underline
        }
    }
}

private extension CursorStyle {
    var blinks: Bool {
        switch self {
        case .blinkBar, .blinkBlock, .blinkUnderline:
            return true
        case .steadyBar, .steadyBlock, .steadyUnderline:
            return false
        }
    }
}

/// Centralised cursor preferences shared by regular and Quick Terminal tabs.
///
/// The six concrete SwiftTerm styles are stored through their stable
/// `tagName`. Live tabs observe a cursor-only notification so unrelated theme,
/// focus, redraw, and renderer events never overwrite a TUI's explicit
/// DECSCUSR style. A DECSCUSR default-reset command restores this preference.
@MainActor
@Observable
final class TerminalCursorSettings {
    static let shared = TerminalCursorSettings(
        defaults: PineSettingsDefaults.shared()
    )

    enum Keys {
        static let cursorStyle = "terminal.cursor.style"
    }

    /// Pine's default is intentionally thinner than SwiftTerm's block cursor.
    static let defaultCursorStyle = CursorStyle.blinkBar

    private let defaults: UserDefaults

    /// Injected delivery channel used by settings and live terminal tabs.
    let notificationCenter: NotificationCenter

    /// SwiftTerm's stable `tagName`, persisted instead of enum ordinals.
    private(set) var cursorStyleTag: String {
        didSet {
            guard cursorStyleTag != oldValue else { return }
            defaults.set(cursorStyleTag, forKey: Keys.cursorStyle)
            notificationCenter.post(
                name: .terminalCursorStyleChanged,
                object: self
            )
        }
    }

    /// The concrete style currently preferred by the user.
    var cursorStyle: CursorStyle {
        CursorStyle(tagName: cursorStyleTag) ?? Self.defaultCursorStyle
    }

    /// Cursor shape exposed by Settings. Updating it preserves blinking.
    var cursorShape: TerminalCursorShape {
        get { TerminalCursorShape(cursorStyle: cursorStyle) }
        set { setCursorStyle(newValue.cursorStyle(blinks: cursorBlinks)) }
    }

    /// Blink preference exposed independently from shape.
    var cursorBlinks: Bool {
        get { cursorStyle.blinks }
        set { setCursorStyle(cursorShape.cursorStyle(blinks: newValue)) }
    }

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter

        let storedCursorStyle = defaults.string(forKey: Keys.cursorStyle)
        if let storedCursorStyle,
           let style = CursorStyle(tagName: storedCursorStyle) {
            self.cursorStyleTag = style.tagName
        } else {
            self.cursorStyleTag = Self.defaultCursorStyle.tagName
            if storedCursorStyle?.isEmpty == false {
                defaults.set(
                    Self.defaultCursorStyle.tagName,
                    forKey: Keys.cursorStyle
                )
            }
        }
    }

    /// Sets one of SwiftTerm's six concrete styles. This is the single
    /// persistence and notification boundary for both Settings controls.
    func setCursorStyle(_ style: CursorStyle) {
        cursorStyleTag = style.tagName
    }

    func reset() {
        setCursorStyle(Self.defaultCursorStyle)
    }
}

extension Notification.Name {
    /// Posted only when the user changes cursor shape or blinking. Live tabs
    /// apply the new preference once; subsequent explicit DECSCUSR sequences
    /// remain in control until the user changes the preference again (#1409).
    static let terminalCursorStyleChanged = Notification.Name(
        "terminalCursorStyleChanged"
    )
}
