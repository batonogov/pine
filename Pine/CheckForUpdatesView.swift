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
    static let appcastURLString = "https://github.com/batonogov/pine/releases/latest/download/appcast.xml"
}

/// ViewModel that observes `SPUUpdater.canCheckForUpdates` via Combine.
/// Uses `ObservableObject` (not `@Observable`) because Sparkle publishes
/// KVO-based properties through Combine publishers.
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updater.checkForUpdates()
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
