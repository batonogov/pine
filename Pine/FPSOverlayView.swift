//
//  FPSOverlayView.swift
//  Pine
//
//  Created by Claude on 23.03.2026.
//

import SwiftUI

/// A compact overlay that displays real-time FPS.
///
/// Color-coded by performance level:
/// - Green: ≥ 90 fps (ProMotion)
/// - Yellow: ≥ 50 fps
/// - Orange: ≥ 30 fps
/// - Red: < 30 fps
struct FPSOverlayView: View {
    var fpsCounter: FPSCounter

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color(nsColor: fpsCounter.level.color))
                .frame(width: 6, height: 6)

            Text(verbatim: fpsCounter.fpsText)
                .monospacedDigit()
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier(AccessibilityID.fpsOverlay)
    }
}
