//
//  WelcomeView.swift
//  Pine
//
//  Created by Claude on 13.03.2026.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// NSViewRepresentable wrapper for native NSSearchField (with magnifying glass and clear button).
struct WelcomeSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.placeholderString = Strings.welcomeSearchPlaceholderString
        searchField.delegate = context.coordinator
        searchField.setAccessibilityIdentifier(AccessibilityID.welcomeSearchField)
        return searchField
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

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
    @State private var isSearchVisible = false
    @State private var isDragTargeted = false

    /// Recent projects filtered by the search query.
    private var filteredProjects: [URL] {
        RecentProjectsFilter.filter(registry.recentProjects, query: searchText)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: logo and actions
            VStack(spacing: 14) {
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

                Button {
                    if let appDelegate {
                        appDelegate.showAgentInbox()
                    } else {
                        openWindow(id: "agent-inbox")
                    }
                } label: {
                    Label(Strings.menuAgentInbox, systemImage: MenuIcons.agentInbox)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier(AccessibilityID.welcomeAgentInboxButton)

                Spacer()
            }
            .frame(width: 260)
            .padding()

            Divider()

            // Right: recent projects
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(Strings.welcomeRecentProjects)
                        .font(.headline)
                    Spacer()
                    if registry.recentProjects.count > 8 {
                        Button {
                            isSearchVisible.toggle()
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier(AccessibilityID.welcomeSearchToggle)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 4)

                if registry.recentProjects.isEmpty {
                    ContentUnavailableView {
                        Label(Strings.welcomeNoRecent, systemImage: "clock")
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    if isSearchVisible {
                        WelcomeSearchField(text: $searchText)
                            .frame(height: 22)
                            .padding(.horizontal)
                            .padding(.bottom, 4)
                    }

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
                                        openRecentProject(at: url)
                                    }
                                    .contextMenu {
                                        Button {
                                            NSWorkspace.shared.activateFileViewerSelecting([url])
                                        } label: {
                                            Label(
                                                Strings.welcomeRevealInFinder,
                                                systemImage: "folder"
                                            )
                                        }
                                        Divider()
                                        Button {
                                            registry.removeFromRecent(url)
                                        } label: {
                                            Label(
                                                Strings.welcomeRemoveFromRecent,
                                                systemImage: "minus.circle"
                                            )
                                        }
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
        .onChange(of: isSearchVisible) { _, visible in
            if !visible {
                searchText = ""
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFolder)) { _ in
            guard controlActiveState == .key else { return }
            openFolder()
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
        .overlay {
            if isDragTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.blue, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .task {
            // Open pending project from PINE_OPEN_PROJECT env var.
            guard let url = appDelegate?.pendingProjectURL else { return }
            appDelegate?.pendingProjectURL = nil
            // Wait for initial SwiftUI layout to complete.
            try? await Task.sleep(for: .seconds(UITimings.Delay.long))
            openProject(at: url)
        }
    }

    /// Handles file URLs dropped onto the Welcome window.
    /// Directories are opened as projects; files determine the project from their parent directory.
    private func handleDrop(providers: [NSItemProvider]) {
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                guard let url = try? await provider.loadItem(
                    forTypeIdentifier: UTType.fileURL.identifier
                ) as? URL else { continue }
                urls.append(url)
            }

            let classified = DropHandler.classifyURLs(urls)
            for directory in classified.directories {
                openProject(at: directory)
            }

            guard let firstFile = classified.files.first else { return }
            // Open one parent project for the complete file batch, then wait
            // once for its real AppKit owner before any possible large-file
            // sheet is requested.
            let projectDir = firstFile.deletingLastPathComponent()
                .resolvingSymlinksInPath()
            guard let projectManager = openProject(at: projectDir),
                  let owner = await projectManager.awaitDialogOwnerWindow(),
                  projectManager.dialogOwnerWindow === owner,
                  registry.openProjects[registry.canonicalProjectURL(projectDir)] === projectManager else {
                return
            }
            for file in classified.files {
                projectManager.paneManager.openFileInActiveEditor(url: file)
            }
        }
    }

    private func openFolder() {
        let context = DialogPresenter.context(
            for: appDelegate?.welcomeWindow ?? NSApp.keyWindow
        )
        Task { @MainActor in
            if let url = await registry.openProjectViaPanel(context: context) {
                openProjectWindow(url)
                closeWelcome()
            }
        }
    }

    /// Welcome recents use the same deferred AppDelegate transition as
    /// File > Open Recent and the Dock menu.
    private func openRecentProject(at url: URL) {
        if let appDelegate {
            appDelegate.requestOpenRecentProject(
                url,
                fallbackOpenProjectWindow: { url in
                    openProjectWindow(url)
                }
            )
            return
        }
        NativeCommandDelivery.deferToNextMainRunLoop {
            _ = openProject(at: url)
        }
    }

    @discardableResult
    private func openProject(at url: URL) -> ProjectManager? {
        let canonical = registry.canonicalProjectURL(url)
        if let appDelegate {
            guard appDelegate.openRecentProject(
                canonical,
                fallbackOpenProjectWindow: { url in
                    openProjectWindow(url)
                }
            ) else {
                return nil
            }
            return registry.openProjects[canonical]
        }

        // Preview/fallback hosts without AppDelegate still preserve the
        // registry's retained ProjectManager instead of rebuilding it.
        guard let projectManager = registry.projectManager(for: canonical) else {
            return nil
        }
        openProjectWindow(canonical)
        closeWelcome()
        return projectManager
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
        if let appDelegate {
            appDelegate.hideWelcome()
            return
        }
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
        .animation(PineAnimation.quick, value: isHovered)
        .onHover { isHovered = $0 }
    }
}
