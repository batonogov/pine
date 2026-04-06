//
//  DiagnosticPopoverController.swift
//  Pine
//
//  NSViewController that hosts a small SwiftUI view describing a single
//  validation diagnostic. Displayed inside an NSPopover anchored to the
//  diagnostic icon in the line number gutter when the user clicks the icon
//  (#679 — diagnostic icons need an explanation).
//

import AppKit
import SwiftUI

/// Hosts a SwiftUI explanation view inside an NSPopover.
final class DiagnosticPopoverController: NSViewController {
    let diagnostic: ValidationDiagnostic

    init(diagnostic: ValidationDiagnostic) {
        self.diagnostic = diagnostic
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let host = NSHostingView(rootView: DiagnosticPopoverView(diagnostic: diagnostic))
        // A modest preferred size — popover will resize to fit content.
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 100)
        view = host
    }
}

/// SwiftUI body of the diagnostic popover.
/// Shows: severity icon + label, the validator source, and the full message.
struct DiagnosticPopoverView: View {
    let diagnostic: ValidationDiagnostic

    private var severityLabel: String {
        switch diagnostic.severity {
        case .error: return Strings.diagnosticSeverityError
        case .warning: return Strings.diagnosticSeverityWarning
        case .info: return Strings.diagnosticSeverityInfo
        }
    }

    private var lineLabel: String {
        if let column = diagnostic.column {
            return Strings.diagnosticLineColumnLabel(line: diagnostic.line, column: column)
        }
        return Strings.diagnosticLineLabel(line: diagnostic.line)
    }

    private var severityColor: Color {
        switch diagnostic.severity {
        case .error: return .red
        case .warning: return .yellow
        case .info: return .blue
        }
    }

    private var severitySymbol: String {
        switch diagnostic.severity {
        case .error: return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: severitySymbol)
                    .foregroundStyle(severityColor)
                Text(severityLabel)
                    .font(.headline)
                Spacer()
                Text(diagnostic.source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(diagnostic.message)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(lineLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(12)
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 420, alignment: .leading)
    }
}
