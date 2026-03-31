//
//  ToastView.swift
//  Pine
//
//  Non-blocking toast notification overlay.
//  Slides in from the top edge and auto-dismisses.
//

import SwiftUI

/// Overlay that shows the current toast from ToastManager.
struct ToastOverlay: View {
    @Environment(ToastManager.self) private var toastManager

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            if let toast = toastManager.currentToast {
                ToastView(item: toast) {
                    withAnimation(PineAnimation.quick) {
                        toastManager.dismiss()
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.top, 8)
                .accessibilityIdentifier(AccessibilityID.toastNotification)
            }
        }
        .animation(PineAnimation.overlay, value: toastManager.currentToast?.id)
        .allowsHitTesting(toastManager.currentToast != nil)
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
            .accessibilityLabel("Dismiss")
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
