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

    /// Only auto-restore on first appearance (cold launch).
    /// Reset via `WelcomeView.resetAutoRestore()` in tests if needed.
    private(set) static var didAutoRestore = false

    /// Allows tests/previews to reset the auto-restore flag.
    static func resetAutoRestore() { didAutoRestore = false }

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
                    }
                    .listStyle(.plain)
                }
            }
            .frame(minWidth: 280)
        }
        .frame(width: 600, height: 400)
        .onAppear {
            // Auto-restore all previously open projects on cold launch
            guard !Self.didAutoRestore else { return }
            Self.didAutoRestore = true
            var restored = false
            let projectURLs = SessionState.loadOpenProjects()
            if projectURLs.isEmpty {
                // Fallback: try legacy single-project key for migration
                if let state = SessionState.loadLegacySingle() {
                    openProjectWindow(at: state.projectURL)
                    restored = true
                }
            } else {
                for url in projectURLs {
                    openProjectWindow(at: url)
                    restored = true
                }
            }
            if restored {
                dismissWindow(id: "welcome")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFolder)) { _ in
            guard controlActiveState == .key else { return }
            openFolder()
        }
    }

    private func openFolder() {
        if let url = registry.openProjectViaPanel() {
            openWindow(value: url)
            dismissWindow(id: "welcome")
        }
    }

    /// Opens a project window without dismissing Welcome (used by restore loop).
    private func openProjectWindow(at url: URL) {
        let canonical = url.resolvingSymlinksInPath()
        guard registry.projectManager(for: canonical) != nil else { return }
        openWindow(value: canonical)
    }

    /// Opens a project and dismisses Welcome (used by user clicks).
    private func openProject(at url: URL) {
        openProjectWindow(at: url)
        dismissWindow(id: "welcome")
    }
}
