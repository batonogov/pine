//
//  CommandOverlaySelectionAnnouncement.swift
//  Pine
//
//  Shared VoiceOver selection feedback for searchable command overlays.
//

import Foundation

/// Owner-scoped announcement sink supplied by `CommandOverlayContainer`.
/// Returning `false` means the presentation or its document owner is stale.
typealias CommandOverlayAnnouncementSink = @MainActor (String) -> Bool

/// Coalesces result-set announcements while keeping explicit keyboard
/// navigation immediate. Each overlay owns one controller for its mounted
/// lifetime, so dismissal cancels pending speech and replacement starts with a
/// fresh duplicate-suppression boundary.
@MainActor
@Observable
final class CommandOverlaySelectionAnnouncer {
    @ObservationIgnored
    private var pendingTask: Task<Void, Never>?

    @ObservationIgnored
    private var generation = 0

    @ObservationIgnored
    private var lastDeliveredMessage: String?

    @ObservationIgnored
    private let delay: Duration

    init(delay: Duration = .milliseconds(150)) {
        self.delay = delay
    }

    /// Replaces any pending result-set announcement. This is used after query
    /// or async-result stabilization, never for pointer selection.
    func schedule(
        _ message: String,
        using sink: @escaping CommandOverlayAnnouncementSink
    ) {
        generation &+= 1
        let scheduledGeneration = generation
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.delay ?? .zero)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.generation == scheduledGeneration else {
                return
            }
            self.deliverIfNeeded(message, using: sink)
        }
    }

    /// Cancels a pending query summary and immediately speaks a keyboard-driven
    /// selection. Callers first verify that the index actually changed.
    func announceImmediately(
        _ message: String,
        using sink: CommandOverlayAnnouncementSink
    ) {
        cancelPending()
        deliverIfNeeded(message, using: sink)
    }

    /// Invalidates work captured by a view that is leaving the hierarchy.
    func invalidate() {
        cancelPending()
    }

    private func cancelPending() {
        generation &+= 1
        pendingTask?.cancel()
        pendingTask = nil
    }

    private func deliverIfNeeded(
        _ message: String,
        using sink: CommandOverlayAnnouncementSink
    ) {
        guard !message.isEmpty, message != lastDeliveredMessage else { return }
        guard sink(message) else { return }
        lastDeliveredMessage = message
    }
}

/// Localized semantic projection shared by Quick Open, Command Palette, and
/// Symbol Navigator. Views keep their native search-field focus and existing
/// row actions; only the highlighted-row feedback is projected here.
enum CommandOverlaySelectionAnnouncement {
    static func resultSummary(
        count: Int,
        selectedRow: String?,
        locale: Locale = .current
    ) -> String {
        guard count > 0, let selectedRow, !selectedRow.isEmpty else {
            return Strings.commandOverlayNoResults(locale: locale)
        }
        if count == 1 {
            return Strings.commandOverlayOneResult(
                selectedRow: selectedRow,
                locale: locale
            )
        }
        return Strings.commandOverlayManyResults(
            count: count,
            selectedRow: selectedRow,
            locale: locale
        )
    }

    static func quickOpenRow(
        fileName: String,
        relativePath: String
    ) -> String {
        guard relativePath != fileName, !relativePath.isEmpty else {
            return fileName
        }
        return "\(fileName), \(relativePath)"
    }

    static func commandPaletteRow(
        item: CommandPaletteItem,
        locale: Locale = .current
    ) -> String {
        var parts = [item.title, item.subtitle]
        if let shortcut = item.shortcut.displayText, !shortcut.isEmpty {
            parts.append(
                Strings.commandOverlayShortcut(
                    shortcut,
                    locale: locale
                )
            )
        }
        if let reason = item.unavailabilityReason, !reason.isEmpty {
            parts.append(
                Strings.commandOverlayUnavailable(
                    reason,
                    locale: locale
                )
            )
        }
        return parts.joined(separator: ", ")
    }

    static func symbolRow(
        kind: String,
        name: String,
        line: Int,
        locale: Locale = .current
    ) -> String {
        Strings.commandOverlaySymbol(
            kind: kind,
            name: name,
            line: line,
            locale: locale
        )
    }
}
