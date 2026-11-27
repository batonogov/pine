//
//  ADEProjectOverviewView.swift
//  Pine
//
//  What the main area shows while no task is selected.
//

import SwiftUI

/// The project overview: the task input, with room around it.
struct ADEProjectOverviewView: View {
    @Bindable var model: ADEWorkspaceModel

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                // The composer's eyebrow reuses `workspace.newTask`: one
                // concept, one string, per the #1760 simplicity budget. The
                // uppercase styling is presentation, not a second key.
                Text(Strings.workspaceNewTask)
                    .font(.caption.weight(.semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                if model.hasTasks {
                    Text(Strings.workspaceOverviewSelectHint)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 10)
                }
                ADEComposerView(model: model, isProminent: true)
                Text(Strings.openCodeTaskEmptyDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 640)
            Spacer(minLength: 24)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.workspaceOverview)
    }
}
