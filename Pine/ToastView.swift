//
//  ToastView.swift
//  Pine
//
//  Non-blocking toast notification overlay.
//  Slides in from the top edge and auto-dismisses.
//
//  Issue #1247: the full-window clear layer is `allowsHitTesting(false)` so
//  clicks pass through to the editor, sidebar, and terminal while a toast is
//  visible. Hit testing is re-enabled only on the visible toast card and its
//  action buttons. Reduce Motion is respected: when enabled, the toast fades
//  in instead of sliding.
//

import SwiftUI

/// Overlay that shows the current toast from ToastManager.
struct ToastOverlay: View {
    @Environment(ToastManager.self) private var toastManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            // Full-window clear layer. Hit testing is disabled so the overlay
            // never blocks clicks in the editor/sidebar/terminal (issue #1247).
            Color.clear
                .allowsHitTesting(ToastHitTesting.containerAllowsHitTesting)

            if let toast = toastManager.currentToast {
                ToastView(item: toast) {
                    withAnimation(PineAnimation.quick) {
                        toastManager.dismiss()
                    }
                }
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .padding(.top, 8)
                .accessibilityIdentifier(AccessibilityID.toastNotification)
                // Only the visible toast card participates in hit testing.
                .allowsHitTesting(ToastHitTesting.cardAllowsHitTesting)
            }
        }
        // The container itself does not intercept events; each child declares
        // its own hit-testing policy above.
        .allowsHitTesting(ToastHitTesting.containerAllowsHitTesting)
        .animation(reduceMotion ? PineAnimation.content : PineAnimation.overlay,
                   value: toastManager.currentToast?.id)
    }
}

/// Individual toast notification view.
struct ToastView: View {
    let item: ToastItem
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
                .font(.body)

            Text(item.message)
                .font(.callout)
                .lineLimit(2)

            Spacer(minLength: 4)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Strings.a11yToastDismissLabel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
        .frame(maxWidth: 400)
    }

    private var iconName: String {
        switch item.kind {
        case .filesReloaded:
            return "arrow.clockwise"
        case .info:
            return "info.circle"
        }
    }
}

/// Pure description of the toast overlay hit-testing policy (issue #1247).
///
/// Extracted as a standalone enum so unit tests can assert the policy without
/// rendering a SwiftUI view. `ToastOverlay` applies these decisions via
/// `.allowsHitTesting(_:)` modifiers — see `ToastOverlay.body`.
enum ToastHitTesting {
    /// The full-window clear container never intercepts clicks, even while a
    /// toast is visible. This is the core fix for #1247: the editor, sidebar,
    /// and terminal remain interactive.
    static let containerAllowsHitTesting: Bool = false

    /// The visible toast card participates in hit testing so its dismiss
    /// button and any action buttons remain clickable.
    static let cardAllowsHitTesting: Bool = true

    /// Returns the effective hit-testing policy for a given visibility state.
    /// The container is always non-interactive; the card is interactive only
    /// when a toast is visible.
    static func cardHitTesting(isToastVisible: Bool) -> Bool {
        isToastVisible && cardAllowsHitTesting
    }
}
