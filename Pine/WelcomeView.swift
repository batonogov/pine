//
//  WelcomeView.swift
//  Pine
//
//  Created by Claude on 13.03.2026.
//

import SwiftUI

/// Welcome window shown when no project is open.
struct WelcomeView: View {
    var registry: ProjectRegistry
    @Environment(\.openWindow) var openWindow
    @Environment(\.dismissWindow) var dismissWindow
    @Environment(\.controlActiveState) var controlActiveState

    /// AppDelegate reference for checking pending project URL (UI testing).
    var appDelegate: AppDelegate?

    var body: some View {
        HStack(spacing: 0) {
            // Left: logo and actions
            VStack(spacing: 20) {
                Spacer()

                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)

                Text("Pine")
                    .font(.system(size: 28, weight: .bold))

                Text(Strings.welcomeSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button(Strings.openFolderButton) {
                    openFolder()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier(AccessibilityID.welcomeOpenFolderButton)

                Spacer()
            }
            .frame(width: 260)
            .padding()

            Divider()

            // Right: recent projects
            VStack(alignment: .leading, spacing: 0) {
                Text(Strings.welcomeRecentProjects)
                    .font(.headline)
                    .padding(.horizontal)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                if registry.recentProjects.isEmpty {
                    ContentUnavailableView {
                        Label(Strings.welcomeNoRecent, systemImage: "clock")
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    List(registry.recentProjects, id: \.self) { url in
                        Button {
                            openProject(at: url)
                        } label: {
                            HStack {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.lastPathComponent)
                                        .font(.system(size: 13))
                                    Text(url.path)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(AccessibilityID.welcomeRecentProject(url.lastPathComponent))
                    }
                    .listStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.welcomeRecentProjectsList)
                }
            }
            .frame(minWidth: 280)
        }
        .frame(width: 600, height: 400)
        .onReceive(NotificationCenter.default.publisher(for: .openFolder)) { _ in
            guard controlActiveState == .key else { return }
            openFolder()
        }
        .task {
            // Open pending project from PINE_OPEN_PROJECT env var.
            guard let url = appDelegate?.pendingProjectURL else { return }
            appDelegate?.pendingProjectURL = nil
            // Wait for initial SwiftUI layout to complete.
            try? await Task.sleep(for: .seconds(0.5))
            openProject(at: url)
        }
    }

    private func openFolder() {
        if let url = registry.openProjectViaPanel() {
            openWindow(value: url)
            dismissWindow(id: "welcome")
        }
    }

    private func openProject(at url: URL) {
        let canonical = url.resolvingSymlinksInPath()
        guard registry.projectManager(for: canonical) != nil else { return }
        openWindow(value: canonical)
        dismissWindow(id: "welcome")
    }
}
