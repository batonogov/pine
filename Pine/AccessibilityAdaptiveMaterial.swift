//
//  AccessibilityAdaptiveMaterial.swift
//  Pine
//
//  Material backgrounds that honour Reduce Transparency (#1533).
//

import SwiftUI

/// A material that resolves to an opaque colour when Reduce Transparency is
/// on (#1533). Materials never consult the setting themselves, so a panel
/// painted with one can sit illegibly over the bright content behind it —
/// the exact situation Reduce Transparency exists to prevent.
///
/// The decision is made in `resolve(in:)`, so the style tracks the
/// environment of the view that uses it and follows the system setting live,
/// the same way `\.accessibilityReduceMotion` consumers do.
struct AccessibilityAdaptiveMaterial: ShapeStyle {
    /// The material painted when transparency is allowed.
    var material: Material
    /// The opaque colour painted instead of `material` when Reduce
    /// Transparency is on.
    var fallback: Color

    init(
        _ material: Material,
        fallback: Color = Color(nsColor: .windowBackgroundColor)
    ) {
        self.material = material
        self.fallback = fallback
    }

    func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        if environment.accessibilityReduceTransparency {
            return AnyShapeStyle(fallback)
        }
        return AnyShapeStyle(material)
    }
}

extension ShapeStyle where Self == AccessibilityAdaptiveMaterial {
    /// `.regularMaterial` that honours Reduce Transparency (#1533).
    static var adaptiveRegularMaterial: AccessibilityAdaptiveMaterial {
        AccessibilityAdaptiveMaterial(.regularMaterial)
    }

    /// `.bar` that honours Reduce Transparency (#1533).
    static var adaptiveBar: AccessibilityAdaptiveMaterial {
        AccessibilityAdaptiveMaterial(.bar)
    }
}
