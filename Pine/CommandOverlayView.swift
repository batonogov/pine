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
    /// Forces the motion preference. Production leaves this `nil` and reads the
    /// environment; tests pin a branch with it, mirroring
    /// `GlobalTabSwitcherOverlay`.
    var reduceMotionOverride: Bool?
    /// Reports the resolved presentation so hosted tests can verify that the
    /// geometry component is really gone, rather than that a helper was called.
    var observeMotion: (PineAnimation.OverlayPresentation) -> Void = { _ in }
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The motion preference this overlay actually obeys.
    var effectiveReduceMotion: Bool {
        reduceMotionOverride ?? reduceMotion
    }

    /// Curve used by `dismiss()`. `nil` under Reduce Motion, so the overlay
    /// disappears immediately instead of springing away.
    var dismissalAnimation: Animation? {
        PineAnimation.overlay(reduceMotion: effectiveReduceMotion)
    }

    var body: some View {
        let presentation = PineAnimation.OverlayPresentation.resolve(
            reduceMotion: effectiveReduceMotion
        )
        return ZStack {
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
                // Opacity-only under Reduce Motion: a cross-fade is the HIG
                // replacement for a scale, and the scale is what moves.
                .transition(PineAnimation.overlayTransition(presentation))
        }
        .animation(presentation.animation, value: isPresented)
        .accessibilityAddTraits(.isModal)
        .onAppear {
            observeMotion(presentation)
        }
        .onChange(of: presentation) { _, newPresentation in
            observeMotion(newPresentation)
        }
        .onExitCommand {
            dismiss()
        }
    }

    /// Keeps pointer and keyboard cancellation on the exact same path. The
    /// guard also makes the cleanup one-shot if an Escape event bubbles from
    /// focused content to this container.
    func dismiss() {
        guard isPresented else { return }
        withAnimation(dismissalAnimation) {
            isPresented = false
        }
        onDismiss()
    }
}
