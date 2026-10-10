//
//  TerminalFontSettings.swift
//  Pine
//
//  Persisted terminal font preferences with Nerd Font auto-detection (#1649).
//
//  The terminal font was hardcoded to SF Mono 13, which renders Powerline /
//  Powerlevel10k / Starship Private-Use-Area glyphs as LastResort tofu. The
//  user can now pick any installed fixed-pitch family and a size; when no
//  explicit choice exists, a curated Nerd Font list is auto-detected so
//  prompt icons render out of the box once one is installed.
//
//  Settings persist in UserDefaults and broadcast via
//  `Notification.Name.terminalFontChanged`; live project and Quick Terminal
//  tabs re-apply the font without restarting their shells (`resetFont()`
//  recomputes the grid and the size-changed delegate chain raises SIGWINCH).
//

import AppKit
import CoreText

/// The family resolution before an `NSFont` is instantiated. Kept as data so
/// auto-detection and the unset-vs-explicit-System distinction are testable
/// without the font having to exist on the machine running the tests.
enum TerminalFontResolution: Equatable, Sendable {
    /// NSFont.monospacedSystemFont — the "System (SF Mono)" choice.
    case system
    /// An installed (or previously installed) font family name.
    case family(String)
}

/// Centralised terminal font preferences shared by project and Quick
/// Terminal tabs.
@MainActor
@Observable
final class TerminalFontSettings {
    static let shared = TerminalFontSettings(
        defaults: PineSettingsDefaults.shared()
    )

    nonisolated enum Keys {
        static let fontFamily = "terminal.font.family"
        static let fontSize = "terminal.font.size"
    }

    nonisolated static let defaultSize: Double = 13
    nonisolated static let minimumSize: Double = 8
    nonisolated static let maximumSize: Double = 24

    /// Persisted value for the explicit "System (SF Mono)" choice. The key
    /// being absent means "Automatic" (Nerd Font auto-detection); this marker
    /// keeps a deliberate system-font choice from being overridden by a Nerd
    /// Font the user installs later.
    static let systemFamilyMarker = "__system__"

    /// Nerd Font families tried in order when the preference is Automatic.
    /// Only Mono-suffixed variants are listed: non-Mono Nerd Fonts size PUA
    /// icons as double-width glyphs that can overflow a single terminal cell.
    static let nerdFontCandidates: [String] = [
        "MesloLGS NF",
        "JetBrainsMono Nerd Font Mono",
        "FiraCode Nerd Font Mono",
        "Hack Nerd Font Mono",
    ]

    private let defaults: UserDefaults

    /// Delivery channel used by both the settings model and its terminal-tab
    /// observers. Injection keeps isolated tests on the same live-update path
    /// as production.
    let notificationCenter: NotificationCenter

    /// Family probe used by auto-detection and the detection-status caption.
    /// Production queries CoreText; tests inject a fixed list so no font has
    /// to be installed on the machine running the suite.
    private let availableFontFamiliesProvider: () -> Set<String>

    /// Re-entrancy guard for the normalizing self-assignment in the
    /// `fontSize` observer. An `@Observable` property observer IS re-entered
    /// when the property is assigned from inside its own `didSet`; the
    /// normalization is idempotent so the re-entry terminates, but without
    /// this guard the inner pass would persist and post the change
    /// notification a second time (reproduced empirically).
    @ObservationIgnored
    private var isNormalizingFontSize = false

    /// The user's family choice: `nil` = Automatic (auto-detect),
    /// `Self.systemFamilyMarker` = explicit System (SF Mono), otherwise an
    /// installed font family name.
    var fontFamilySelection: String? {
        didSet {
            guard fontFamilySelection != oldValue else { return }
            if let fontFamilySelection {
                defaults.set(fontFamilySelection, forKey: Keys.fontFamily)
            } else {
                defaults.removeObject(forKey: Keys.fontFamily)
            }
            notifyChanged()
        }
    }

    /// Terminal font size in points, clamped to 8…24. Out-of-range and
    /// non-finite writes are normalized and persisted; only an effective
    /// change notifies observers.
    var fontSize: Double {
        didSet {
            guard !isNormalizingFontSize else { return }
            let normalized = Self.normalizedSize(fontSize)
            if !fontSize.isFinite || normalized != fontSize {
                defaults.set(normalized, forKey: Keys.fontSize)
                isNormalizingFontSize = true
                fontSize = normalized
                isNormalizingFontSize = false
                if normalized != oldValue {
                    notifyChanged()
                }
                return
            }
            guard fontSize != oldValue else { return }
            defaults.set(fontSize, forKey: Keys.fontSize)
            notifyChanged()
        }
    }

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        availableFontFamilies: (() -> Set<String>)? = nil
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.availableFontFamiliesProvider = availableFontFamilies
            ?? { TerminalFontSettings.installedFontFamilies() }

        if let storedFamily = defaults.string(forKey: Keys.fontFamily),
           !storedFamily.isEmpty {
            self.fontFamilySelection = storedFamily
        } else {
            self.fontFamilySelection = nil
            if defaults.object(forKey: Keys.fontFamily) != nil {
                // Corrupt (empty) family: normalize back to Automatic.
                defaults.removeObject(forKey: Keys.fontFamily)
            }
        }

        if let storedSize = defaults.object(forKey: Keys.fontSize) as? Double {
            let normalized = Self.normalizedSize(storedSize)
            self.fontSize = normalized
            if normalized != storedSize {
                defaults.set(normalized, forKey: Keys.fontSize)
            }
        } else {
            self.fontSize = Self.defaultSize
            if defaults.object(forKey: Keys.fontSize) != nil {
                // Persisted value of an unexpected type: normalize.
                defaults.set(Self.defaultSize, forKey: Keys.fontSize)
            }
        }
    }

    // MARK: - Resolution

    /// The family choice resolved against installed fonts. An explicit
    /// family that has since been uninstalled still resolves to `.family`
    /// here — `resolvedFont` performs the SF Mono fallback at instantiation
    /// time so the preference survives reinstalling the font.
    var fontResolution: TerminalFontResolution {
        switch fontFamilySelection {
        case .some(Self.systemFamilyMarker):
            return .system
        case .some(let family) where !family.isEmpty:
            return .family(family)
        case .some, .none:
            if let detected = detectedNerdFontFamily {
                return .family(detected)
            }
            return .system
        }
    }

    /// The font applied to every terminal view.
    var resolvedFont: NSFont {
        switch fontResolution {
        case .system:
            return Self.systemFont(size: fontSize)
        case .family(let family):
            // `NSFontManager.font(withFamily:)` accepts family names by
            // contract (`NSFont(name:)` is documented for full/PostScript
            // names). `isFixedPitch` is enforced at this trust boundary:
            // a hand-edited defaults entry naming a proportional family
            // must never reach the terminal grid.
            let candidate = NSFontManager.shared.font(
                withFamily: family,
                traits: [],
                weight: 5,
                size: fontSize
            )
            guard let candidate, candidate.isFixedPitch else {
                return Self.systemFont(size: fontSize)
            }
            return candidate
        }
    }

    /// The first curated Nerd Font family installed on this Mac, if any.
    var detectedNerdFontFamily: String? {
        Self.detectedNerdFontFamily(
            availableFamilies: availableFontFamiliesProvider()
        )
    }

    /// Pure auto-detection over an injected family list, so tests never touch
    /// CoreText.
    static func detectedNerdFontFamily(
        availableFamilies: Set<String>
    ) -> String? {
        nerdFontCandidates.first { availableFamilies.contains($0) }
    }

    // MARK: - Font enumeration

    /// Installed fixed-pitch families, sorted for the Settings picker.
    static func fixedPitchFontFamilies() -> [String] {
        installedFontFamilies()
            .filter { family in
                NSFontManager.shared.font(
                    withFamily: family,
                    traits: [],
                    weight: 5,
                    size: defaultSize
                )?.isFixedPitch == true
            }
            .sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
    }

    static func installedFontFamilies() -> Set<String> {
        guard let names = CTFontManagerCopyAvailableFontFamilyNames()
                as? [String] else { return [] }
        return Set(names)
    }

    // MARK: - Mutation

    /// Clamps to the supported range; non-finite values fall back to the
    /// default so a corrupt defaults entry can never reach AppKit.
    /// `nonisolated`: pure value math shared with the UI-test seeding hook
    /// in `PineSettingsDefaults`, which has no MainActor access.
    nonisolated static func normalizedSize(_ size: Double) -> Double {
        guard size.isFinite else { return defaultSize }
        return min(max(size, minimumSize), maximumSize)
    }

    /// Restores Automatic family detection and the default size.
    func reset() {
        fontFamilySelection = nil
        fontSize = Self.defaultSize
    }

    // MARK: - Broadcasting

    private func notifyChanged() {
        notificationCenter.post(name: .terminalFontChanged, object: self)
    }

    private static func systemFont(size: Double) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

extension Notification.Name {
    /// Posted after the terminal font family or size changes. Live terminal
    /// tabs (project and Quick Terminal) re-apply the font, recompute their
    /// grid, and repaint without restarting their shells (#1649).
    static let terminalFontChanged = Notification.Name("terminalFontChanged")
}
