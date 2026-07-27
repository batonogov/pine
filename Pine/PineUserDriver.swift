//
//  PineUserDriver.swift
//  Pine
//
//  Created by Pine Agent on 27.07.2026.
//
//  Custom `SPUUserDriver` that translates every Sparkle user-interaction
//  callback into a state transition on `UpdateCoordinator`. Sparkle guarantees
//  all methods are invoked on the main thread (the protocol is annotated
//  `NS_SWIFT_UI_ACTOR`), so the conformance is main-actor-isolated — which
//  matches the coordinator.
//
//  This driver replaces `SPUStandardUpdaterController`'s built-in user driver
//  so Pine can present the update flow entirely in-app (#1250): no Sparkle
//  windows, just a titlebar indicator + popover owned by SwiftUI.
//

import Foundation
import Sparkle

/// Thin adapter from the `SPUUserDriver` ObjC protocol to `UpdateCoordinator`.
///
/// The driver holds a weak (via `unowned`) back-reference to the coordinator
/// that owns it (set after init, because the coordinator creates the driver in
/// its own `init`). Every protocol method forwards to the coordinator; the
/// driver itself holds no UI state.
final class PineUserDriver: NSObject, SPUUserDriver {

    /// Back-reference to the owning coordinator. Set by `UpdateCoordinator.init`
    /// immediately after the driver is constructed. `unowned` is safe because
    /// the coordinator owns the driver for its entire lifetime.
    var coordinator: UpdateCoordinator!

    // MARK: - Update permission

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        // Pine's first launch already enables automatic checks; accept
        // Sparkle's permission prompt with automatic checks on and no system
        // profile submission.
        let response = SUUpdatePermissionResponse(
            automaticUpdateChecks: true,
            sendSystemProfile: false
        )
        reply(response)
    }

    // MARK: - User-initiated check

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        coordinator.handleShowUserInitiatedUpdateCheck(cancellation: cancellation)
    }

    // MARK: - Update found

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        coordinator.handleShowUpdateFound(
            appcastItem: appcastItem,
            state: state,
            reply: reply
        )
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        coordinator.handleShowReleaseNotes(data: downloadData.data)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        coordinator.handleReleaseNotesFailedToDownload()
    }

    // MARK: - No update found / errors

    func showUpdateNotFound(
        withError error: Error,
        acknowledgement: @escaping () -> Void
    ) {
        coordinator.handleShowUpdateNotFound(
            error: error,
            acknowledgement: acknowledgement
        )
    }

    func showUpdaterError(
        _ error: Error,
        acknowledgement: @escaping () -> Void
    ) {
        coordinator.handleShowUpdaterError(
            error: error,
            acknowledgement: acknowledgement
        )
    }

    // MARK: - Download

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        coordinator.handleDownloadInitiated(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        coordinator.handleDownloadReceivedExpectedContentLength(expected: expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        // The expected length is tracked on the coordinator via
        // `handleDownloadReceivedExpectedContentLength`; forward both so the
        // coordinator can compute progress without the driver holding state.
        coordinator.handleDownloadReceivedData(
            length: length,
            expected: coordinator.expectedContentLength
        )
    }

    func showDownloadDidStartExtractingUpdate() {
        coordinator.handleDownloadStartedExtracting()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        coordinator.handleExtractionReceivedProgress(progress: progress)
    }

    // MARK: - Install & relaunch

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        coordinator.handleReadyToInstallAndRelaunch(reply: reply)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication retry: @escaping () -> Void
    ) {
        coordinator.handleInstallingUpdate(
            applicationTerminated: applicationTerminated,
            retryTerminatingApplication: retry
        )
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        coordinator.handleUpdateInstalledAndRelaunched(
            relaunched: relaunched,
            acknowledgement: acknowledgement
        )
    }

    // MARK: - Dismissal

    func dismissUpdateInstallation() {
        coordinator.handleDismissUpdateInstallation()
    }

    // MARK: - Focus (optional)

    func showUpdateInFocus() {
        coordinator.showUpdateInFocus()
    }
}
