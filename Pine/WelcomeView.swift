//
//  WelcomeView.swift
//  Pine
//
//  Created by Claude on 13.03.2026.
//

import SwiftUI

extension URL {
    /// Returns the path with the home directory replaced by `~`.
    var abbreviatedPath: String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

/// Welcome window shown when no project is open.
struct WelcomeView: View {
    var registry: ProjectRegistry
    @Environment(\.openWindow) var openWindow
    @Environment(\.dismissWindow) var dismissWindow
    @Environment(\.controlActiveState) var controlActiveState

    /// AppDelegate reference for checking pending project URL (UI testing).
    var appDelegate: AppDelegate?

    @State private var searchText = ""

    /// Recent projects filtered by the search query.
    private var filteredProjects: [URL] {
        RecentProjectsFilter.filter(registry.recentProjects, query: searchText)
    }

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
                    TextField(Strings.welcomeSearchPlaceholder, text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                        .accessibilityIdentifier(AccessibilityID.welcomeSearchField)

                    if filteredProjects.isEmpty {
                        ContentUnavailableView {
                            Label(Strings.welcomeNoSearchResults, systemImage: "magnifyingglass")
                        }
                        .frame(maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(
                                    Array(filteredProjects.enumerated()),
                                    id: \.element
                                ) { index, url in
                                    if index > 0 {
                                        Divider()
                                            .padding(.leading)
                                    }
                                    RecentProjectRow(url: url) {
                                        openProject(at: url)
                                    }
                                    .accessibilityIdentifier(
                                        AccessibilityID.welcomeRecentProject(url.lastPathComponent)
                                    )
                                }
                            }
                        }
                        .accessibilityIdentifier(AccessibilityID.welcomeRecentProjectsList)
                    }
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
            openProjectWindow(url)
            closeWelcome()
        }
    }

    private func openProject(at url: URL) {
        let canonical = url.resolvingSymlinksInPath()
        // If the project is still in openProjects (window close didn't clean up),
        // save its session and remove it so projectManager(for:) creates a fresh PM.
        if registry.isProjectOpen(canonical) {
            registry.openProjects[canonical]?.saveSession()
            registry.closeProject(canonical)
        }
        guard registry.projectManager(for: canonical) != nil else { return }
        openProjectWindow(canonical)
        closeWelcome()
    }

    /// Opens a project window using AppDelegate's captured closure (works from both
    /// SwiftUI scene windows and AppKit-created fallback windows) or falls back
    /// to the SwiftUI environment action.
    private func openProjectWindow(_ url: URL) {
        if let open = appDelegate?.openProjectWindow {
            open(url)
        } else {
            openWindow(value: url)
        }
    }

    /// Closes all Welcome windows — both SwiftUI-managed and AppKit-created fallback.
    private func closeWelcome() {
        dismissWindow(id: "welcome")
        // Close any AppKit-created welcome windows that dismissWindow doesn't handle
        for window in NSApp.windows
            where window.identifier?.rawValue == "welcome" && window.isVisible {
            window.close()
        }
    }
}

/// A single row in the recent projects list with hover highlight.
private struct RecentProjectRow: View {
    let url: URL
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 13))
                    Text(url.abbreviatedPath)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovered ? Color.primary.opacity(0.06) : .clear)
        .onHover { isHovered = $0 }
    }
}
