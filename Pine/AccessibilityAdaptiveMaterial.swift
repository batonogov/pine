//
//  AccessibilityAdaptiveMaterial.swift
//  Pine
//
//  Material backgrounds that honour Reduce Transparency (#1533).
//

import SwiftUI

/// Paints `material` behind a view, or the opaque `fallback` colour when
/// Reduce Transparency is on (#1533). Materials never consult the setting
/// themselves, so a panel painted with one can sit illegibly over the
/// bright content behind it — the exact situation Reduce Transparency
/// exists to prevent.
///
/// The branch is chosen in `body`, not in a `ShapeStyle.resolve(in:)`: a
/// material returned from a custom style's resolve does not rasterize
/// identically to a direct `background(_: Material)` call (on macOS 26 the
/// two differ well past the snapshot tolerance), while the modifier's
/// allowed branch below *is* that direct call, so existing rendering —
/// and its recorded baselines — is untouched when transparency is allowed.
private struct AccessibilityAdaptiveMaterialBackground: ViewModifier {
    let material: Material
    let opacity: Double
    let fallback: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(fallback)
        } else if opacity < 1 {
            content.background(material.opacity(opacity))
        } else {
            content.background(material)
        }
    }
}

/// The `background(_:in:)` counterpart of
/// `AccessibilityAdaptiveMaterialBackground`.
private struct AccessibilityAdaptiveMaterialClip<Clip: Shape>: ViewModifier {
    let material: Material
    let clip: Clip
    let fallback: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(fallback, in: clip)
        } else {
            content.background(material, in: clip)
        }
    }
}

/// The shape-`fill` counterpart of
/// `AccessibilityAdaptiveMaterialBackground`.
private struct AccessibilityAdaptiveMaterialFill<Filled: Shape>: View {
    let shape: Filled
    let material: Material
    let fallback: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            shape.fill(fallback)
        } else {
            shape.fill(material)
        }
    }
}

extension View {
    /// `.background(material)` that honours Reduce Transparency (#1533).
    /// When the setting is on, the opaque `fallback` is painted instead;
    /// `opacity` applies only to the material, never to the fallback —
    /// a translucent fallback would defeat the setting.
    func adaptiveMaterialBackground(
        _ material: Material,
        opacity: Double = 1,
        fallback: Color = Color(nsColor: .windowBackgroundColor)
    ) -> some View {
        modifier(AccessibilityAdaptiveMaterialBackground(
            material: material,
            opacity: opacity,
            fallback: fallback
        ))
    }

    /// `.background(material, in: clip)` that honours Reduce Transparency
    /// (#1533). When the setting is on, the opaque `fallback` fills `clip`
    /// instead.
    func adaptiveMaterialBackground<Clip: Shape>(
        _ material: Material,
        in clip: Clip,
        fallback: Color = Color(nsColor: .windowBackgroundColor)
    ) -> some View {
        modifier(AccessibilityAdaptiveMaterialClip(
            material: material,
            clip: clip,
            fallback: fallback
        ))
    }
}

extension Shape {
    /// `.fill(material)` that honours Reduce Transparency (#1533). When the
    /// setting is on, the shape is filled with the opaque `fallback`
    /// instead.
    func adaptiveMaterialFill(
        _ material: Material,
        fallback: Color = Color(nsColor: .windowBackgroundColor)
    ) -> some View {
        AccessibilityAdaptiveMaterialFill(
            shape: self,
            material: material,
            fallback: fallback
        )
    }
}
