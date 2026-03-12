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

    /// Only auto-restore on first appearance (cold launch).
    private static var didAutoRestore = false

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
            // Auto-restore last session only on cold launch
            guard !Self.didAutoRestore else { return }
            Self.didAutoRestore = true
            if let session = SessionState.load() {
                openProject(at: session.projectURL)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFolder)) { _ in
            openFolder()
        }
    }

    private func openFolder() {
        if let url = registry.openProjectViaPanel() {
            openWindow(value: url)
            dismissWindow(id: "welcome")
        }
    }

    private func openProject(at url: URL) {
        _ = registry.projectManager(for: url)
        openWindow(value: url)
        dismissWindow(id: "welcome")
    }
}
