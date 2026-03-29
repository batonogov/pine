//
//  CrashReportingOptInView.swift
//  Pine
//
//  First-launch opt-in dialog for crash reporting.
//

import SwiftUI

/// Opt-in dialog shown on first launch asking the user to enable crash reporting.
/// Explains what data is collected and provides clear Enable/Disable choices.
struct CrashReportingOptInView: View {
    @Binding var isPresented: Bool
    var onChoice: (Bool) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: MenuIcons.crashReporting)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text(Strings.crashReportingOptInTitle)
                .font(.headline)

            Text(Strings.crashReportingOptInMessage)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(Strings.crashReportingOptInPrivacy)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button(String(localized: "crashReporting.optIn.disable")) {
                    CrashReportingSettings.recordChoice(enabled: false)
                    onChoice(false)
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "crashReporting.optIn.enable")) {
                    CrashReportingSettings.recordChoice(enabled: true)
                    onChoice(true)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}
