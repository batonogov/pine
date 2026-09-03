//
//  ThemeContrastTests.swift
//  PineTests
//
//  WCAG contrast coverage for the default syntax theme (#1540):
//  light-mode colours must clear AA (4.5:1) against the light editor
//  background, and `dynamicColor` must supply an increased-contrast
//  variant for the system Increase Contrast preference.
//

import AppKit
import Testing

@testable import Pine

@Suite("Theme WCAG Contrast")
struct ThemeContrastTests {

    // MARK: - Reference backgrounds

    /// Resolves `NSColor.textBackgroundColor` under the requested system
    /// appearance — the backdrop the editor actually paints text on.
    private func textBackground(isDark: Bool) -> (Double, Double, Double) {
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        var resolved: (Double, Double, Double) = isDark ? (0, 0, 0) : (1, 1, 1)
        appearance?.performAsCurrentDrawingAppearance {
            if let color = NSColor.textBackgroundColor.usingColorSpace(.sRGB) {
                resolved = (
                    Double(color.redComponent),
                    Double(color.greenComponent),
                    Double(color.blueComponent)
                )
            }
        }
        return resolved
    }

    /// Resolves a dynamic theme colour under the requested appearance.
    private func resolve(
        _ color: NSColor,
        isDark: Bool
    ) -> (Double, Double, Double) {
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        var resolved = (Double.nan, Double.nan, Double.nan)
        appearance?.performAsCurrentDrawingAppearance {
            if let color = color.usingColorSpace(.sRGB) {
                resolved = (
                    Double(color.redComponent),
                    Double(color.greenComponent),
                    Double(color.blueComponent)
                )
            }
        }
        return resolved
    }

    private func ratioVsBackground(
        _ rgb: (Double, Double, Double),
        isDark: Bool
    ) -> Double {
        Theme.contrastRatio(rgb, textBackground(isDark: isDark))
    }

    private var scopes: [String] { Array(Theme.default.colors.keys).sorted() }

    // MARK: - AA in light mode (issue checklist)

    @Test("All light-mode syntax colours meet WCAG AA (4.5:1) against white")
    func lightSyntaxColoursMeetAA() throws {
        for scope in scopes {
            let rgb = resolve(try #require(Theme.default.color(for: scope)), isDark: false)
            let ratio = ratioVsBackground(rgb, isDark: false)
            #expect(
                ratio >= 4.5,
                "\(scope) light contrast \(String(format: "%.2f", ratio)) is below 4.5:1"
            )
        }
    }

    @Test("The ten scopes named in #1540 now clear the AA threshold")
    func issueNamedScopesClearAA() throws {
        let named = [
            "number", "markdown.image", "type", "markdown.list", "comment",
            "markdown.rule", "markdown.heading.3", "markdown.heading.4",
            "markdown.heading.2", "markdown.quote",
        ]
        for scope in named {
            let rgb = resolve(try #require(Theme.default.color(for: scope)), isDark: false)
            let ratio = ratioVsBackground(rgb, isDark: false)
            #expect(
                ratio >= 4.5,
                "\(scope) was darkened for #1540 but measures \(String(format: "%.2f", ratio))"
            )
        }
    }

    @Test("All dark-mode syntax colours meet WCAG AA against the dark editor background")
    func darkSyntaxColoursMeetAA() throws {
        for scope in scopes {
            let rgb = resolve(try #require(Theme.default.color(for: scope)), isDark: true)
            let ratio = ratioVsBackground(rgb, isDark: true)
            #expect(
                ratio >= 4.5,
                "\(scope) dark contrast \(String(format: "%.2f", ratio)) is below 4.5:1"
            )
        }
    }

    // MARK: - Increase Contrast variant

    @Test("High-contrast light variants reach 7:1 against white")
    func highContrastLightVariantsReachAAA() throws {
        for scope in scopes {
            let base = resolve(try #require(Theme.default.color(for: scope)), isDark: false)
            let boosted = Theme.increasedContrastVariant(
                of: base,
                isDarkAppearance: false
            )
            let ratio = ratioVsBackground(boosted, isDark: false)
            #expect(
                ratio >= 7.0,
                "\(scope) high-contrast light \(String(format: "%.2f", ratio)) is below 7:1"
            )
        }
    }

    @Test("High-contrast dark variants reach 7:1 against the dark background")
    func highContrastDarkVariantsReachAAA() throws {
        for scope in scopes {
            let base = resolve(try #require(Theme.default.color(for: scope)), isDark: true)
            let boosted = Theme.increasedContrastVariant(
                of: base,
                isDarkAppearance: true
            )
            let ratio = ratioVsBackground(boosted, isDark: true)
            #expect(
                ratio >= 7.0,
                "\(scope) high-contrast dark \(String(format: "%.2f", ratio)) is below 7:1"
            )
        }
    }

    @Test("High-contrast variants stay within the sRGB gamut")
    func highContrastVariantsStayInGamut() throws {
        for isDark in [false, true] {
            for scope in scopes {
                let base = resolve(try #require(Theme.default.color(for: scope)), isDark: isDark)
                let boosted = Theme.increasedContrastVariant(
                    of: base,
                    isDarkAppearance: isDark
                )
                for component in [boosted.0, boosted.1, boosted.2] {
                    #expect(component >= 0 && component <= 1)
                }
            }
        }
    }

    @Test("Variant selection follows appearance and contrast flags")
    func variantSelection() {
        // Both bases sit below the 7:1 target so the boost actually applies.
        let light = (0.5, 0.5, 0.5)
        let dark = (0.55, 0.55, 0.55)

        // Normal contrast returns the base palette untouched.
        #expect(
            Theme.resolvedVariant(
                light: light,
                dark: dark,
                isDarkAppearance: false,
                increasedContrast: false
            ) == light
        )
        #expect(
            Theme.resolvedVariant(
                light: light,
                dark: dark,
                isDarkAppearance: true,
                increasedContrast: false
            ) == dark
        )

        // Increased contrast darkens light / brightens dark.
        let boostedLight = Theme.resolvedVariant(
            light: light,
            dark: dark,
            isDarkAppearance: false,
            increasedContrast: true
        )
        let boostedDark = Theme.resolvedVariant(
            light: light,
            dark: dark,
            isDarkAppearance: true,
            increasedContrast: true
        )
        #expect(boostedLight != light)
        #expect(boostedDark != dark)
        #expect(boostedLight.0 < light.0)
        #expect(boostedDark.0 > dark.0)
    }

    @Test("A colour that already clears the target is returned unchanged")
    func sufficientColourIsUntouched() {
        let black = (0.0, 0.0, 0.0)
        #expect(
            Theme.increasedContrastVariant(of: black, isDarkAppearance: false) == black
        )
        let white = (1.0, 1.0, 1.0)
        #expect(
            Theme.increasedContrastVariant(of: white, isDarkAppearance: true) == white
        )
    }

    // MARK: - Ratio math

    @Test("Contrast ratio of black and white is 21")
    func ratioSanity() {
        let ratio = Theme.contrastRatio((0, 0, 0), (1, 1, 1))
        #expect(abs(ratio - 21) < 0.01)
    }

    @Test("Identical colours have a ratio of 1")
    func ratioIdentity() {
        #expect(abs(Theme.contrastRatio((0.3, 0.6, 0.9), (0.3, 0.6, 0.9)) - 1) < 0.001)
    }
}
