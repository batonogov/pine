//
//  CrashReportDialogs.swift
//  Pine
//
//  AppKit dialogs for crash reporting:
//  1. First-launch opt-in dialog ("Help improve Pine?")
//  2. Pending crash report dialog ("Pine crashed last time. Send report?")
//

import AppKit

enum CrashReportDialogs {

    /// Shows the first-launch opt-in dialog. Returns true if user opted in.
    @discardableResult
    static func showOptInDialog(settings: CrashReportSettings) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "crashReport.optIn.title")
        alert.informativeText = String(localized: "crashReport.optIn.message")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "crashReport.optIn.enable"))
        alert.addButton(withTitle: String(localized: "crashReport.optIn.noThanks"))

        settings.hasBeenAsked = true

        let response = alert.runModal()
        let enabled = response == .alertFirstButtonReturn
        settings.isEnabled = enabled
        return enabled
    }

    /// Shows a dialog with pending crash report(s). User can send or dismiss.
    /// "Send" copies the report to clipboard (for pasting into a GitHub issue).
    static func showPendingReportDialog(reports: [CrashReport]) {
        guard let report = reports.first else { return }

        let alert = NSAlert()
        alert.messageText = String(localized: "crashReport.pending.title")
        alert.informativeText = String(localized: "crashReport.pending.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "crashReport.pending.copyAndOpen"))
        alert.addButton(withTitle: String(localized: "crashReport.pending.dismiss"))

        // Add accessory view with crash details
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 450, height: 200))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = report.formattedText
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView

        alert.accessoryView = scrollView

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Copy to clipboard
            let combined = reports.map(\.formattedText).joined(separator: "\n\n---\n\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(combined, forType: .string)

            // Open GitHub issues page
            // swiftlint:disable:next force_unwrapping
            let url = URL(string: "https://github.com/batonogov/pine/issues/new?labels=bug&title=Crash+Report&body=Paste+crash+report+here")!
            NSWorkspace.shared.open(url)
        }

        // Always clear after showing
        CrashReportHandler.clearPendingReports()
    }
}
