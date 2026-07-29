//
//  CheckForUpdatesView.swift
//  Pine
//
//  Created by Федор Батоногов on 17.03.2026.
//

import Combine
import Sparkle
import SwiftUI

/// Sparkle configuration constants.
enum SparkleConstants {
    nonisolated static let appcastURLString = "https://github.com/batonogov/pine/releases/latest/download/appcast.xml"
}

/// ViewModel that observes `SPUUpdater.canCheckForUpdates` via Combine.
/// Uses `ObservableObject` (not `@Observable`) because Sparkle publishes
/// KVO-based properties through Combine publishers.
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    /// Kept as a narrow action instead of exposing Sparkle to the menu
    /// presentation. Production supplies `SPUUpdater.checkForUpdates`; tests
    /// can verify request gating without starting a second updater.
    private let checkForUpdatesAction: () -> Void

    init(updater: SPUUpdater) {
        checkForUpdatesAction = {
            updater.checkForUpdates()
        }
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Focused test seam for the menu action. The production app always uses
    /// ``init(updater:)`` and owns exactly one Sparkle controller in
    /// `AppDelegate`.
    init(
        canCheckForUpdates: Bool,
        checkForUpdatesAction: @escaping () -> Void
    ) {
        self.canCheckForUpdates = canCheckForUpdates
        self.checkForUpdatesAction = checkForUpdatesAction
    }

    func checkForUpdates() {
        // SwiftUI disables the menu item while unavailable, but keep the
        // command boundary fail-closed as well. Clearing availability before
        // forwarding also rejects a duplicate activation in the same event
        // cycle; Sparkle's KVO publisher re-enables it when the updater is
        // ready for another check.
        guard canCheckForUpdates else { return }
        canCheckForUpdates = false
        checkForUpdatesAction()
    }
}

/// Menu button for "Check for Updates…" in the app menu.
struct CheckForUpdatesView: View {
    @ObservedObject var viewModel: CheckForUpdatesViewModel

    var body: some View {
        Button(Strings.menuCheckForUpdates) {
            viewModel.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}
