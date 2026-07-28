//
//  CommandOverlayView.swift
//  Pine
//
//  Lightweight non-modal overlay container for command-palette-style UI.
//  Replaces document-modal .sheet presentations for navigation overlays
//  (Quick Open, Symbol Navigator, Go to Line).
//

import SwiftUI

/// A non-modal overlay that presents content as a centered, floating panel
/// over a translucent backdrop.
///
/// Unlike `.sheet`, this overlay does not block the document behind it.
/// Clicking the backdrop or pressing Escape dismisses the overlay. The inner
/// content view retains full keyboard behavior (arrow keys, Enter, Escape).
struct CommandOverlayView<Content: View>: View {
    @Binding var isPresented: Bool
    /// Optional cleanup invoked by every container-owned dismissal path
    /// (backdrop click and Escape) after the binding is cleared.
    var onDismiss: () -> Void = {}
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            // Translucent backdrop: dimmed to focus attention, captures clicks to dismiss.
            Color.primary.opacity(0.15)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    dismiss()
                }

            // Centered command content with Liquid Glass material background.
            content()
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.regularMaterial)
                        .shadow(color: .black.opacity(0.2), radius: 24, y: 6)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
        .animation(PineAnimation.overlay, value: isPresented)
        .accessibilityAddTraits(.isModal)
        .onExitCommand {
            dismiss()
        }
    }

    /// Keeps pointer and keyboard cancellation on the exact same path. The
    /// guard also makes the cleanup one-shot if an Escape event bubbles from
    /// focused content to this container.
    func dismiss() {
        guard isPresented else { return }
        withAnimation(PineAnimation.overlay) {
            isPresented = false
        }
        onDismiss()
    }
}
