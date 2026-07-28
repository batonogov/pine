//
//  UpdateCoordinator.swift
//  Pine
//
//  Created by Pine Agent on 27.07.2026.
//
//  App-scoped coordinator that owns the Sparkle `SPUUpdater` and a custom
//  `SPUUserDriver`, presenting the update flow entirely in-app — no Sparkle
//  windows. One instance lives for the app's lifetime (created by
//  `AppDelegate`); it is shared across every project window so the update
//  transaction is never duplicated (#1250).
//

import Combine
import Foundation
import Observation
import Sparkle

/// Discrete states the in-app update flow can be in.
///
/// The coordinator is always in exactly one of these states. Transitions are
/// driven by `PineUserDriver` callbacks (which Sparkle guarantees are
/// delivered on the main actor) and by user actions routed through the UI.
enum UpdateState: Equatable {
    /// No update activity. The coordinator is waiting for the next scheduled
    /// background check or a user-initiated check.
    case idle
    /// A check is in progress (user-initiated or scheduled).
    case checking
    /// An update is available and waiting for the user to act. Carries the
    /// version string and whether the update is informational-only.
    case available(version: String, displayVersion: String, informationalOnly: Bool, critical: Bool)
    /// The update is downloading. `progress` is 0.0–1.0 (clamped); `-1` means
    /// the expected content length is not yet known.
    case downloading(progress: Double)
    /// The update has been downloaded and extracted; the user is being asked
    /// whether to install and relaunch.
    case readyToInstall
    /// Sparkle is installing the update (the app may be about to be terminated).
    case installing
    /// The latest available release is informational-only (no download); the
    /// user should be directed to the info URL.
    case informational(infoURL: URL?, message: String)
    /// The user cancelled an in-flight check or download.
    case cancelled
    /// The check failed or the download/extract/install errored.
    /// `message` is a user-facing description (never raw error debugDescription).
    case failed(message: String)
}

/// A snapshot of the update popover payload — version, release notes, and the
/// stage Sparkle reported when the update was found.
struct UpdateInfo: Equatable {
    let version: String
    let displayVersion: String
    /// HTML or plain-text release notes fetched from the appcast, if any.
    var releaseNotes: String?
    /// `true` when the appcast marked this update as critical.
    let critical: Bool
    /// `true` for an informational-only update (no download/install).
    let informationalOnly: Bool
    /// The URL to open in a browser for informational-only updates.
    let infoURL: URL?
}

/// App-scoped owner of the Sparkle update flow.
///
/// Created once by `AppDelegate` and shared via SwiftUI environment. Owns the
/// `SPUUpdater` (started eagerly) and a `PineUserDriver` that translates every
/// Sparkle user-driver callback into a state transition here. All UI surfaces
/// — menu item, titlebar indicator, popover, "up to date" toast — read from
/// this single source of truth, guaranteeing the update transaction is never
/// duplicated across windows (#1250).
@MainActor
@Observable
final class UpdateCoordinator {

    // MARK: - Observable state

    /// Current discrete state. Drives the titlebar indicator and popover.
    private(set) var state: UpdateState = .idle

    /// Details for the currently-presented update (if any). Populated when an
    /// update is found and cleared on dismiss/install.
    private(set) var updateInfo: UpdateInfo?

    /// Whether the popover anchored to the titlebar indicator is presented.
    var isPopoverPresented = false

    /// Whether the user dismissed the current "available" offer. Sparkle may
    /// still remind them later.
    private(set) var didDismissCurrentOffer = false

    // MARK: - Sparkle objects

    /// The Sparkle updater. Started in ``start()``.
    let updater: SPUUpdater

    /// The custom user driver that forwards Sparkle callbacks here.
    let userDriver: PineUserDriver

    /// Whether `checkForUpdates()` may be invoked right now. Mirrors Sparkle's
    /// KVO-published property so SwiftUI menu items can disable themselves.
    var canCheckForUpdates = false

    // MARK: - Cancellation

    /// The current cancellation handler supplied by Sparkle, if any.
    /// Captured so the UI's "Cancel" button can abort an in-flight check or
    /// download.
    private var cancellation: (() -> Void)?

    /// The current "reply" closure for an update-found or ready-to-install
    /// prompt. Captured so the UI's action buttons can deliver the user's
    /// choice to Sparkle.
    private var pendingReply: ((SPUUserUpdateChoice) -> Void)?

    /// The current retry-termination handler supplied by Sparkle during
    /// installation, if any.
    private var retryTermination: (() -> Void)?

    /// The info-URL acknowledgement for ``showUpdateNotFoundWithError`` /
    /// ``showUpdaterError`` — Sparkle requires this to be called.
    private var pendingAcknowledgement: (() -> Void)?

    /// Combine subscription bag for KVO publishers.
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Toast / notification bridge

    /// Closure used to surface a non-blocking "up to date" / error toast.
    /// Wired by `AppDelegate` to the key window's `ToastManager`. Optional so
    /// the coordinator is testable without a UI.
    var showToast: ((String) -> Void)?

    // MARK: - Dirty-tab / session-save safeguard bridge

    /// Called by ``installAndRelaunch`` before quitting: should prompt the
    /// user to save dirty tabs and save sessions across all open projects.
    /// Returns `true` when it is safe to proceed with the quit/relaunch.
    /// Wired by `AppDelegate`; defaults to `true` when unset.
    var prepareForQuit: () -> Bool = { true }

    // MARK: - Init

    init(hostBundle: Bundle = .main, applicationBundle: Bundle = .main) {
        let driver = PineUserDriver()
        self.userDriver = driver
        // `SPUUpdater` is `NS_SWIFT_UI_ACTOR` → main-actor-isolated.
        self.updater = SPUUpdater(
            hostBundle: hostBundle,
            applicationBundle: applicationBundle,
            userDriver: driver,
            delegate: nil
        )
        driver.coordinator = self
    }

    // MARK: - Lifecycle

    /// Starts the Sparkle updater. Must be called once, early in app launch
    /// (before the next runloop, per Sparkle's contract). Logs and swallows
    /// the error on failure — the app continues without auto-updates rather
    /// than crashing.
    func start() {
        do {
            try updater.start()
        } catch {
            state = .failed(message: Self.startFailureMessage)
        }
        // Mirror Sparkle's canCheckForUpdates so the menu item can disable
        // itself before the updater is ready. KVO publisher is main-actor.
        updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
            .store(in: &cancellables)
    }

    nonisolated static let startFailureMessage: String =
        String(localized: "update.startFailure", defaultValue: "Couldn’t start the updater.")

    // MARK: - Public actions (UI entry points)

    /// User-initiated "Check for Updates…". No-op if a transaction is already
    /// in flight (prevents duplicate checks across windows).
    func checkForUpdates() {
        // Only allow a new check from terminal states. This guard is what
        // guarantees a single in-flight transaction app-wide (#1250).
        guard state.isTerminal else { return }
        didDismissCurrentOffer = false
        accumulatedDownloaded = 0
        expectedContentLength = 0
        updater.checkForUpdates()
    }

    /// The user chose "Restart to Update" (install). Routes through the
    /// dirty-tab / session-save safeguard before telling Sparkle to install.
    func installAndRelaunch() {
        guard let reply = pendingReply else { return }
        // Offer to save dirty work and persist sessions before Sparkle sends
        // the quit event. If the user cancels the save dialog, abort the
        // install — do NOT call the reply closure.
        guard prepareForQuit() else { return }
        pendingReply = nil
        reply(.install)
    }

    /// The user chose "Later" (dismiss). The update remains available and
    /// Sparkle may remind the user later.
    func dismissUpdate() {
        guard let reply = pendingReply else { return }
        didDismissCurrentOffer = true
        pendingReply = nil
        isPopoverPresented = false
        reply(.dismiss)
    }

    /// The user chose "Skip this version". Sparkle will not remind them again
    /// for this version unless they manually check.
    func skipVersion() {
        guard let reply = pendingReply else { return }
        pendingReply = nil
        isPopoverPresented = false
        reply(.skip)
    }

    /// Open the informational update's URL in the default browser, then
    /// dismiss the offer.
    func openInformationalURL() {
        if let url = updateInfo?.infoURL {
            NSWorkspace.shared.open(url)
        }
        dismissUpdate()
    }

    /// Cancel an in-flight check or download.
    func cancel() {
        cancellation?()
        cancellation = nil
        state = .cancelled
        isPopoverPresented = false
    }

    /// Re-present whatever update UI is currently active (Sparkle's
    /// `showUpdateInFocus` entry point). Brings the popover forward.
    func showUpdateInFocus() {
        if state != .idle {
            isPopoverPresented = true
        }
    }

    // MARK: - PineUserDriver callbacks (called by the driver on the main actor)

    /// Stores the cancellation block for a user-initiated check and flips to
    /// the `.checking` state.
    func handleShowUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        state = .checking
    }

    /// An update was found. Capture its details and move to `.available`.
    func handleShowUpdateFound(
        appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        // Reset download accounting in case Sparkle resumes a background
        // download without a fresh checkForUpdates() call.
        accumulatedDownloaded = 0
        expectedContentLength = 0
        // Informational-only updates cannot be installed.
        if appcastItem.isInformationOnlyUpdate {
            let message = String(
                localized: "update.informational.message",
                defaultValue: "A newer version is available. Visit the website to download it."
            )
            self.state = .informational(infoURL: appcastItem.infoURL, message: message)
            self.updateInfo = UpdateInfo(
                version: appcastItem.versionString,
                displayVersion: appcastItem.displayVersionString,
                releaseNotes: appcastItem.itemDescription,
                critical: appcastItem.isCriticalUpdate,
                informationalOnly: true,
                infoURL: appcastItem.infoURL
            )
            self.pendingReply = reply
            self.isPopoverPresented = true
            return
        }

        self.state = .available(
            version: appcastItem.versionString,
            displayVersion: appcastItem.displayVersionString,
            informationalOnly: false,
            critical: appcastItem.isCriticalUpdate
        )
        self.updateInfo = UpdateInfo(
            version: appcastItem.versionString,
            displayVersion: appcastItem.displayVersionString,
            releaseNotes: appcastItem.itemDescription,
            critical: appcastItem.isCriticalUpdate,
            informationalOnly: false,
            infoURL: appcastItem.infoURL
        )
        self.pendingReply = reply
        // Reset the dismiss flag — this is a fresh offer.
        didDismissCurrentOffer = false
        // If the update was already downloaded in the background, jump
        // straight to ready-to-install.
        if state.stage == .downloaded || state.stage == .installing {
            self.state = .readyToInstall
        }
        self.isPopoverPresented = true
    }

    /// Release notes were downloaded. Merge them into ``updateInfo``.
    func handleShowReleaseNotes(data: Data) {
        let text = String(data: data, encoding: .utf8) ?? ""
        if updateInfo != nil {
            updateInfo?.releaseNotes = text
        }
    }

    /// Release notes failed to download — non-fatal, keep the popover.
    func handleReleaseNotesFailedToDownload() {
        // No state change; the popover simply shows no release notes.
    }

    /// No update found. Show a non-blocking "up to date" toast and clear the
    /// transaction.
    func handleShowUpdateNotFound(error: Error, acknowledgement: @escaping () -> Void) {
        // Distinguish "you're up to date" from a genuine error using Sparkle's
        // `SPUNoUpdateFoundReasonKey`. When the reason is missing or
        // indicates the user is already on the latest version, we show the
        // friendly toast; otherwise surface the localized description.
        let nsError = error as NSError
        let isUpToDate = nsError.domain == "org.sparkle-project.Sparkle.Error"
            && nsError.code == 1

        if isUpToDate {
            showToast?(Self.upToDateMessage)
            state = .idle
        } else {
            // Treat unknown "no update" reasons as informational, not failure.
            showToast?(error.localizedDescription)
            state = .idle
        }
        pendingAcknowledgement = acknowledgement
        // Sparkle expects the acknowledgement promptly — fire it on the next
        // runloop so any toast presentation has flushed.
        DispatchQueue.main.async { [weak self] in
            self?.pendingAcknowledgement?()
            self?.pendingAcknowledgement = nil
        }
    }

    /// A check / download / extract / install error occurred.
    func handleShowUpdaterError(error: Error, acknowledgement: @escaping () -> Void) {
        state = .failed(message: error.localizedDescription)
        pendingAcknowledgement = acknowledgement
        DispatchQueue.main.async { [weak self] in
            self?.pendingAcknowledgement?()
            self?.pendingAcknowledgement = nil
        }
    }

    /// Download started. Capture the cancellation block.
    func handleDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        state = .downloading(progress: -1)
    }

    /// Sparkle told us the expected content length of the download.
    func handleDownloadReceivedExpectedContentLength(expected: UInt64) {
        expectedContentLength = expected
        // No state change beyond initializing progress at 0 if we were at -1.
        if case .downloading(let p) = state, p < 0 {
            state = .downloading(progress: 0)
        }
    }

    /// The expected total bytes for the current download, as reported by
    /// Sparkle. Read by `PineUserDriver` when forwarding incremental data.
    /// Reset when a new download starts.
    private(set) var expectedContentLength: UInt64 = 0

    /// Sparkle reported incremental download progress.
    func handleDownloadReceivedData(length: UInt64, expected: UInt64) {
        // Track running totals on the coordinator so we don't depend on the
        // driver holding them across callbacks.
        accumulatedDownloaded += length
        let effectiveExpected = max(expected, accumulatedDownloaded)
        guard effectiveExpected > 0 else { return }
        let progress = Double(accumulatedDownloaded) / Double(effectiveExpected)
        state = .downloading(progress: min(max(progress, 0), 1))
    }

    /// Running byte count for the current download. Reset when a new download
    /// starts (in ``handleShowUpdateFound`` and ``checkForUpdates``).
    private var accumulatedDownloaded: UInt64 = 0

    /// The download finished and extraction began.
    func handleDownloadStartedExtracting() {
        // Extraction is part of the "readying" phase; keep the popover open
        // with an indeterminate feel by pinning progress at the extracting
        // sentinel.
        state = .downloading(progress: 1.0)
        cancellation = nil
    }

    /// Extraction progress reported by Sparkle (0.0–1.0).
    func handleExtractionReceivedProgress(progress: Double) {
        state = .downloading(progress: min(max(progress, 0), 1))
    }

    /// The update is ready to install and relaunch.
    func handleReadyToInstallAndRelaunch(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        state = .readyToInstall
        // Ready-to-install replaces any prior pending reply (e.g. from the
        // update-found prompt).
        pendingReply = reply
        cancellation = nil
        // Keep the popover presented so the user can choose.
        isPopoverPresented = true
    }

    /// Sparkle is installing the update.
    func handleInstallingUpdate(
        applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        state = .installing
        self.retryTermination = retryTerminatingApplication
        if applicationTerminated {
            // Nothing more for the UI to do; the app is being quit.
            isPopoverPresented = false
        }
    }

    /// Installation finished (only called if the updater process is alive).
    func handleUpdateInstalledAndRelaunched(relaunched: Bool, acknowledgement: @escaping () -> Void) {
        state = .idle
        updateInfo = nil
        pendingReply = nil
        cancellation = nil
        retryTermination = nil
        pendingAcknowledgement = acknowledgement
        DispatchQueue.main.async { [weak self] in
            self?.pendingAcknowledgement?()
            self?.pendingAcknowledgement = nil
        }
    }

    /// Sparkle asked us to tear down all update UI.
    func handleDismissUpdateInstallation() {
        state = .idle
        updateInfo = nil
        pendingReply = nil
        cancellation = nil
        retryTermination = nil
        isPopoverPresented = false
    }

    // MARK: - Helpers

    nonisolated static let upToDateMessage: String =
        String(localized: "update.upToDate", defaultValue: "You’re up to date.")
}

private extension UpdateState {
    /// Quick equability helper used in ``checkForUpdates`` guard.
    var isTerminal: Bool {
        switch self {
        case .idle, .cancelled, .failed, .informational:
            return true
        case .checking, .available, .downloading, .readyToInstall, .installing:
            return false
        }
    }
}

#if canImport(AppKit)
import AppKit
#endif
