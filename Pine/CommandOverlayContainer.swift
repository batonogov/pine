//
//  CommandOverlayContainer.swift
//  Pine
//
//  Single SwiftUI overlay modifier that renders whichever command overlay the
//  router reports as active (#975). Installed once per project window — this
//  is the shared container all four flows route through.
//
//  Only one overlay is ever mounted at a time because the router holds a single
//  `activePresentation` value; switching to a different case replaces the
//  mounted view (and its @State) deterministically.
//

import SwiftUI

/// View modifier that observes a `CommandOverlayRouter` and presents its active
/// flow inside a `CommandOverlayWindow` panel.
///
/// Observes `.commandOverlayDismissRequested` (backdrop tap) to cancel the
/// overlay without mutating document state.
struct CommandOverlayContainer: ViewModifier {

    let router: CommandOverlayRouter
    let projectManager: ProjectManager

    func body(content: Content) -> some View {
        content
            .background {
                overlayWindow
                    .frame(width: 0, height: 0)
                    .opacity(0)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .commandOverlayDismissRequested
                )
            ) { _ in
                router.dismiss()
            }
    }

    /// The window-backed overlay. Hidden as a background so it never affects
    /// the document layout — the actual panel floats above the window.
    @ViewBuilder
    private var overlayWindow: some View {
        if let presentation = router.activePresentation {
            CommandOverlayWindow(
                isPresented: Binding(
                    get: { router.activePresentation != nil },
                    set: { newValue in
                        if !newValue { router.dismiss() }
                    }
                ),
                containerIdentifier: presentation.containerIdentifier
            ) {
                overlayContent(for: presentation)
                    .environment(projectManager)
            }
            .id(presentation) // remount on flow switch → fresh @State
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func overlayContent(
        for presentation: CommandOverlayPresentation
    ) -> some View {
        switch presentation {
        case .quickOpen:
            QuickOpenView(
                isPresented: Binding(
                    get: {
                        router.activePresentation == .quickOpen
                    },
                    set: { newValue in
                        if !newValue { router.dismiss(ifMatching: .quickOpen) }
                    }
                )
            )
        case .symbolNavigator:
            SymbolNavigatorView(
                isPresented: Binding(
                    get: {
                        router.activePresentation == .symbolNavigator
                    },
                    set: { newValue in
                        if !newValue {
                            router.dismiss(ifMatching: .symbolNavigator)
                        }
                    }
                )
            )
        case .goToLine:
            GoToLineView(
                totalLines: GoToLineLineCountProvider.lineCount(
                    in: projectManager
                ),
                isPresented: Binding(
                    get: {
                        router.activePresentation == .goToLine
                    },
                    set: { newValue in
                        if !newValue {
                            router.dismiss(ifMatching: .goToLine)
                        }
                    }
                ),
                onGoTo: { line, column in
                    GoToLineLineCountProvider.navigate(
                        line: line,
                        column: column,
                        in: projectManager
                    )
                    router.dismiss(ifMatching: .goToLine)
                }
            )
        case .commandPalette:
            CommandPaletteView(
                isPresented: Binding(
                    get: {
                        router.activePresentation == .commandPalette
                    },
                    set: { newValue in
                        if !newValue {
                            router.dismiss(ifMatching: .commandPalette)
                        }
                    }
                ),
                items: CommandPaletteCatalog.makeItems(
                    tasks: ExtensibilityManager.shared.tasks.tasks,
                    keybindings: ExtensibilityManager.shared.keybindings,
                    context: UserCommandInvocationRouter.context(
                        for: projectManager
                    )
                ),
                onInvoke: { item in
                    router.dismiss(ifMatching: .commandPalette)
                    CommandPaletteInvocationRouter.invoke(
                        item,
                        projectManager: projectManager
                    )
                }
            )
        }
    }
}

/// Indirection layer so `CommandOverlayContainer` does not need to reach into
/// `ContentView`'s private helpers (`totalLineCount`, `activeTabManager`) —
/// keeping the container testable in isolation.
nonisolated enum GoToLineLineCountProvider {
    /// The line count of the active tab in the given project.
    @MainActor static func lineCount(in projectManager: ProjectManager) -> Int {
        guard let content = projectManager.activeTabManager.activeTab?.content
        else { return 1 }
        let ns = content as NSString
        var count = 1
        var pos = 0
        while pos < ns.length {
            pos = NSMaxRange(
                ns.lineRange(for: NSRange(location: pos, length: 0))
            )
            count += 1
        }
        return max(1, count - 1)
    }

    /// Routes a Go-to-Line result to the active pane's TabManager via
    /// `pendingGoToLine`, matching the previous `.sheet` wiring.
    @MainActor static func navigate(
        line: Int,
        column: Int?,
        in projectManager: ProjectManager
    ) {
        guard projectManager.activeTabManager.activeTab != nil else { return }
        _ = column
        projectManager.activeTabManager.pendingGoToLine = line
    }
}

/// Thin router that delegates command-palette invocation to the existing
/// invocation paths. Extracted so `CommandOverlayContainer` stays free of
/// `ContentView` coupling.
@MainActor
enum CommandPaletteInvocationRouter {
    static func invoke(
        _ item: CommandPaletteItem,
        projectManager: ProjectManager
    ) {
        switch item.id {
        case .builtIn(let command):
            UserCommandInvocationRouter.dispatch(
                command,
                projectManager: projectManager
            )
        case .task(let id):
            guard let task = ExtensibilityManager.shared.tasks.task(forID: id)
            else { return }
            UserTaskInvocationController.invoke(
                task,
                projectManager: projectManager
            )
        }
    }
}
