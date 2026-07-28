//
//  SidebarView.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import AppKit
import SwiftUI

// MARK: - Sidebar edit state

/// Tracks inline rename / new-item state for the sidebar file tree.
@MainActor
@Observable
final class SidebarEditState {
    var renamingURL: URL?
    var editingText: String = ""
    var isNewlyCreated: Bool = false
    /// URL of the newly created node to scroll to in the sidebar.
    var scrollToNodeID: URL?

    func startRename(for node: FileNode) {
        renamingURL = node.url
        editingText = node.name
        isNewlyCreated = false
    }

    func startNewItem(url: URL) {
        renamingURL = url
        editingText = url.lastPathComponent
        isNewlyCreated = true
    }

    func clear() {
        renamingURL = nil
        editingText = ""
        isNewlyCreated = false
    }

    /// Creates a file or folder with a unique "untitled" name, then starts inline rename.
    ///
    /// When creating a new item, undo registration is deferred to `commitRename` so that
    /// the entire create+rename sequence is undone as a single Cmd+Z action (#527).
    /// The `undoManager` is stored and used later by `commitRename`.
    func createNewItem(
        in parentURL: URL,
        isDirectory: Bool,
        workspace: WorkspaceManager,
        undoManager: UndoManager? = nil
    ) {
        if let root = workspace.rootURL, !FileNode.isWithinProjectRoot(parentURL, projectRoot: root) {
            Self.showFileError(Strings.operationOutsideProject)
            return
        }

        let baseName = isDirectory ? "untitled folder" : "untitled"
        let name = Self.uniqueName(baseName, in: parentURL)
        let newURL = parentURL.appendingPathComponent(name)

        do {
            // Do NOT register undo here — undo is deferred to commitRename so that
            // create + rename are grouped as a single undo action (#527).
            if isDirectory {
                try FileManager.default.createDirectory(at: newURL, withIntermediateDirectories: false)
            } else if !FileManager.default.createFile(atPath: newURL.path, contents: nil) {
                Self.showFileError(Strings.fileCreateError(name))
                return
            }
            workspace.refreshFileTree()
            startNewItem(url: newURL)
            scrollToNodeID = newURL
        } catch {
            Self.showFileError(error.localizedDescription)
        }
    }

    /// Duplicates a file or folder with Finder-style naming, then starts inline rename.
    func duplicateItem(
        at url: URL,
        isDirectory: Bool,
        workspace: WorkspaceManager,
        tabManager: TabManager
    ) {
        if let root = workspace.rootURL, !FileNode.isWithinProjectRoot(url, projectRoot: root) {
            Self.showFileError(Strings.operationOutsideProject)
            return
        }

        guard let copyURL = Self.finderCopyURL(for: url) else { return }

        do {
            try FileManager.default.copyItem(at: url, to: copyURL)
            workspace.refreshFileTree()
            // Start inline rename — same pattern as createNewItem.
            // isNewlyCreated is false so cancelling rename keeps the copy.
            renamingURL = copyURL
            editingText = copyURL.lastPathComponent
            isNewlyCreated = false
            scrollToNodeID = copyURL
            if !isDirectory {
                tabManager.openTab(url: copyURL)
            }
        } catch {
            Self.showFileError(error.localizedDescription)
        }
    }

    /// Returns a unique name by appending a counter if the name already exists.
    static func uniqueName(_ baseName: String, in parentURL: URL) -> String {
        FileNameGenerator.uniqueName(baseName, in: parentURL)
    }

    /// Generates a Finder-style copy URL: "name copy", "name copy 2", etc.
    static func finderCopyURL(for url: URL) -> URL? {
        FileNameGenerator.finderCopyURL(for: url)
    }

    /// Shows an AppKit error alert for file operations.
    static func showFileError(_ message: String) {
        AlertTemplate.fileOperationErrorWarning.runModal(
            messageText: Strings.fileOperationErrorTitle,
            informativeText: message
        )
    }
}

// MARK: - Sidebar keyboard focus

/// Owns the AppKit responder used by the plain ScrollView file tree.
///
/// `ScrollView.focusable()` is still useful for keyboard traversal, but a
/// mouse click on one of its gesture-driven rows does not reliably make the
/// SwiftUI key handler first responder. Keeping a real NSView target gives
/// row clicks the same synchronous responder semantics as NSOutlineView.
@MainActor
@Observable
final class SidebarKeyboardFocusController {
    private weak var responderView: SidebarKeyboardResponderView?
    private(set) var isFocused = false

    func attach(_ responderView: SidebarKeyboardResponderView) {
        self.responderView = responderView
        responderView.onFocusChange = { [weak self] focused in
            self?.updateFocus(focused)
        }
        updateFocus(responderView.window?.firstResponder === responderView)
    }

    @discardableResult
    func requestFocus() -> Bool {
        guard let responderView, let window = responderView.window else {
            return false
        }
        return window.makeFirstResponder(responderView)
            && window.firstResponder === responderView
    }

    private func updateFocus(_ focused: Bool) {
        guard isFocused != focused else { return }
        isFocused = focused
    }
}

/// Prevents a newly-created preview editor from displacing the sidebar while
/// preserving implicit initial focus for non-sidebar open paths.
enum SidebarKeyboardFocusPolicy {
    static func allowsEditorInitialFocus(
        tabID: UUID,
        pendingFocusTabID: UUID?,
        firstResponder: NSResponder?
    ) -> Bool {
        pendingFocusTabID == tabID
            || !(firstResponder is SidebarKeyboardResponderView)
    }
}

/// Navigation commands shared by SwiftUI key presses, physical AppKit events,
/// and the standard key-binding selectors used by Full Keyboard Access and
/// Accessibility-driven input.
enum SidebarKeyboardCommand: Equatable, Sendable {
    case up
    case down
    case left
    case right
    case home
    case end
    case pageUp
    case pageDown

    init?(keyCode: UInt16) {
        switch keyCode {
        case 123:
            self = .left
        case 124:
            self = .right
        case 125:
            self = .down
        case 126:
            self = .up
        case 115:
            self = .home
        case 119:
            self = .end
        case 116:
            self = .pageUp
        case 121:
            self = .pageDown
        default:
            return nil
        }
    }

    init?(selector: Selector) {
        switch NSStringFromSelector(selector) {
        case "moveUp:":
            self = .up
        case "moveDown:":
            self = .down
        case "moveLeft:":
            self = .left
        case "moveRight:":
            self = .right
        case "moveToBeginningOfDocument:",
             "scrollToBeginningOfDocument:":
            self = .home
        case "moveToEndOfDocument:",
             "scrollToEndOfDocument:":
            self = .end
        case "pageUp:",
             "scrollPageUp:":
            self = .pageUp
        case "pageDown:",
             "scrollPageDown:":
            self = .pageDown
        default:
            return nil
        }
    }
}

/// Invisible responder embedded in the sidebar hierarchy.
@MainActor
final class SidebarKeyboardResponderView: NSView {
    var onCommand: ((SidebarKeyboardCommand) -> Bool)?
    var onPrintableText: ((String) -> Bool)?
    var onReturn: ((SidebarKeyboardModifiers) -> Bool)?
    var onSpace: (() -> Bool)?
    var onFocusChange: ((Bool) -> Void)?
    /// Injectable only so hosted tests can prove selector trust boundaries.
    var currentEventProvider: () -> NSEvent? = { NSApp.currentEvent }
    private var isForwardingNavigationKey = false
    private var isForwardingReturnKey = false
    private var isForwardingSpaceKey = false

    override var acceptsFirstResponder: Bool { true }

    /// The responder is focused programmatically by a row click and must not
    /// intercept pointer hit testing itself.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = SidebarKeyboardModifiers(event.modifierFlags)
        if Self.isReturnEvent(event) {
            routePhysicalReturn(event, modifiers: modifiers)
            return
        }
        if Self.isSpaceEvent(event) {
            routePhysicalSpace(event, modifiers: modifiers)
            return
        }
        if let command = SidebarKeyboardCommand(keyCode: event.keyCode) {
            if modifiers.isEmpty, onCommand?(command) == true {
                return
            }
            forwardUnclaimedNavigationKey(event)
            return
        }
        if let character = SidebarTypeSelectInput.printableCharacter(
            from: event.characters,
            modifiers: modifiers
        ), onPrintableText?(character) == true {
            return
        }
        if event.keyCode == 48 {
            switch SidebarTabTraversalDirection.resolve(
                modifiers: modifiers
            ) {
            case .next:
                window?.selectNextKeyView(self)
                return
            case .previous:
                window?.selectPreviousKeyView(self)
                return
            case nil:
                break
            }
        }
        super.keyDown(with: event)
    }

    /// AppKit's key-binding machinery routes interpreted printable input here.
    /// XCUITest and accessibility input can use this path without emitting the
    /// `keyDown` event seen for a physical keyboard.
    override func insertText(_ insertString: Any) {
        guard let text = Self.plainText(from: insertString) else {
            super.insertText(insertString)
            return
        }
        if text == " ", !isForwardingSpaceKey {
            let modifiers = currentSpaceEventModifiers() ?? []
            if SidebarSpaceAction.accepts(modifiers: modifiers),
               onSpace?() == true {
                return
            }
        }
        if let character = SidebarTypeSelectInput.printableCharacter(
            from: text,
            modifiers: []
        ),
           onPrintableText?(character) == true {
            return
        }
        super.insertText(insertString)
    }

    /// Accessibility and Full Keyboard Access can route movement through
    /// AppKit's standard key-binding selectors instead of delivering an
    /// `NSEvent`. Keep that path on the same command callback as `keyDown`.
    override func doCommand(by selector: Selector) {
        if !isForwardingReturnKey,
           NSStringFromSelector(selector) == "insertNewline:",
           let event = currentEventProvider(),
           Self.isReturnEvent(event) {
            let modifiers = SidebarKeyboardModifiers(event.modifierFlags)
            if modifiers == [.command],
               onReturn?(modifiers) == true {
                return
            }
        }
        if !isForwardingNavigationKey,
           let command = SidebarKeyboardCommand(selector: selector),
           onCommand?(command) == true {
            return
        }
        super.doCommand(by: selector)
    }

    private func routePhysicalReturn(
        _ event: NSEvent,
        modifiers: SidebarKeyboardModifiers
    ) {
        if SidebarReturnAction.accepts(modifiers: modifiers),
           onReturn?(modifiers) == true {
            return
        }
        isForwardingReturnKey = true
        defer { isForwardingReturnKey = false }
        super.keyDown(with: event)
    }

    private func routePhysicalSpace(
        _ event: NSEvent,
        modifiers: SidebarKeyboardModifiers
    ) {
        if SidebarSpaceAction.accepts(modifiers: modifiers),
           onSpace?() == true {
            return
        }
        isForwardingSpaceKey = true
        defer { isForwardingSpaceKey = false }
        super.keyDown(with: event)
    }

    /// Let modified or otherwise-unclaimed movement continue through AppKit
    /// without re-entering our selector-only accessibility command path.
    private func forwardUnclaimedNavigationKey(_ event: NSEvent) {
        isForwardingNavigationKey = true
        defer { isForwardingNavigationKey = false }
        super.keyDown(with: event)
    }

    private static func plainText(from value: Any) -> String? {
        if let string = value as? String {
            return string
        }
        return (value as? NSAttributedString)?.string
    }

    private func currentSpaceEventModifiers() -> SidebarKeyboardModifiers? {
        guard let event = currentEventProvider(),
              Self.isSpaceEvent(event) else {
            return nil
        }
        return SidebarKeyboardModifiers(event.modifierFlags)
    }

    private static func isReturnEvent(_ event: NSEvent) -> Bool {
        event.type == .keyDown
            && (
                event.keyCode == 36
                    || event.keyCode == 76
                    || event.characters == "\r"
                    || event.characters == "\n"
            )
    }

    private static func isSpaceEvent(_ event: NSEvent) -> Bool {
        event.type == .keyDown
            && (event.keyCode == 49 || event.characters == " ")
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocusChange?(true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onFocusChange?(false)
        }
        return resigned
    }
}

/// Keeps the AppKit responder attached to SwiftUI's sidebar lifecycle.
struct SidebarKeyboardFocusBridge: NSViewRepresentable {
    let controller: SidebarKeyboardFocusController
    let onCommand: (SidebarKeyboardCommand) -> Bool
    let onPrintableText: (String) -> Bool
    let onReturn: (SidebarKeyboardModifiers) -> Bool
    let onSpace: () -> Bool

    func makeNSView(context: Context) -> SidebarKeyboardResponderView {
        let view = SidebarKeyboardResponderView()
        view.onCommand = onCommand
        view.onPrintableText = onPrintableText
        view.onReturn = onReturn
        view.onSpace = onSpace
        controller.attach(view)
        return view
    }

    func updateNSView(_ nsView: SidebarKeyboardResponderView, context: Context) {
        nsView.onCommand = onCommand
        nsView.onPrintableText = onPrintableText
        nsView.onReturn = onReturn
        nsView.onSpace = onSpace
        controller.attach(nsView)
    }
}

// MARK: - Sidebar

private struct SidebarKeyboardNavigationModifier: ViewModifier {
    var actions: SidebarKeyboardActions
    var isEnabled: Bool

    func body(content: Content) -> some View {
        content
            .onKeyPress(.upArrow, phases: .down) { press in
                handleNavigation(press, command: .up)
            }
            .onKeyPress(.downArrow, phases: .down) { press in
                handleNavigation(press, command: .down)
            }
            .onKeyPress(.leftArrow, phases: .down) { press in
                handleNavigation(press, command: .left)
            }
            .onKeyPress(.rightArrow, phases: .down) { press in
                handleNavigation(press, command: .right)
            }
            .onKeyPress(.home, phases: .down) { press in
                handleNavigation(press, command: .home)
            }
            .onKeyPress(.end, phases: .down) { press in
                handleNavigation(press, command: .end)
            }
            .onKeyPress(.pageUp, phases: .down) { press in
                handleNavigation(press, command: .pageUp)
            }
            .onKeyPress(.pageDown, phases: .down) { press in
                handleNavigation(press, command: .pageDown)
            }
            .onKeyPress(phases: .down) { press in
                guard isEnabled,
                      let character = SidebarTypeSelectInput.printableCharacter(
                        from: press.characters,
                        modifiers: SidebarKeyboardModifiers(press.modifiers)
                      ) else {
                    return .ignored
                }
                actions.onCharacters(character)
                return .handled
            }
    }

    private func handleNavigation(
        _ press: KeyPress,
        command: SidebarKeyboardCommand
    ) -> KeyPress.Result {
        let modifiers = SidebarKeyboardModifiers(press.modifiers)
        guard isEnabled, modifiers.isEmpty else { return .ignored }
        actions.onCommand(command)
        return .handled
    }
}

/// Groups navigation and type-selection callbacks for the keyboard modifier.
struct SidebarKeyboardActions {
    var onCommand: (SidebarKeyboardCommand) -> Void
    var onCharacters: (String) -> Void
}

extension View {
    func sidebarKeyboardNavigation(
        _ actions: SidebarKeyboardActions,
        isEnabled: Bool
    ) -> some View {
        modifier(
            SidebarKeyboardNavigationModifier(
                actions: actions,
                isEnabled: isEnabled
            )
        )
    }
}

private extension SidebarKeyboardModifiers {
    init(_ modifiers: EventModifiers) {
        var result: SidebarKeyboardModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        self = result
    }

    init(_ modifiers: NSEvent.ModifierFlags) {
        var result: SidebarKeyboardModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        self = result
    }
}

struct SidebarView: View {
    @Binding var selectedFile: FileNode?
    let onFileOpen: (FileNode, SidebarFileOpenDisposition) -> Void
    @Environment(WorkspaceManager.self) private var workspace
    @Environment(PaneManager.self) private var paneManager
    @Environment(ProjectRegistry.self) private var registry
    @Environment(\.openWindow) var openWindow
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var editState = SidebarEditState()
    @State private var expansion = SidebarExpansionState()
    @State private var keyboardFocusController = SidebarKeyboardFocusController()
    @State private var navigation = SidebarTreeNavigation()
    @FocusState private var hasSwiftUIKeyboardFocus: Bool

    var body: some View {
        Group {
            if workspace.rootURL == nil {
                List {
                    ContentUnavailableView {
                        Label(Strings.noFolderOpen, systemImage: "folder")
                    } description: {
                        Text(Strings.openFolderPrompt)
                    } actions: {
                        Button(Strings.openFolderButton) {
                            openNewProject()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .navigationTitle(Strings.filesTitle)
            } else if workspace.rootNodes.isEmpty && workspace.isLoading {
                List {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowSeparator(.hidden)
                }
                .navigationTitle(workspace.projectName)
            } else {
                ScrollViewReader { scrollProxy in
                    // Plain `ScrollView + VStack` instead of `List(.sidebar)`:
                    // SwiftUI's sidebar List enforces a minimum row height
                    // via NSOutlineView that could not be overridden to
                    // reach Xcode/Zed-style compact density (#778). Rows
                    // are content-sized and handle their own selection,
                    // tap, and context-menu via `FileNodeRow` +
                    // `SidebarFileTree.row`.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            SidebarFileTree(
                                nodes: workspace.rootNodes,
                                treeRevision: workspace.rootNodesRevision,
                                selection: $selectedFile,
                                onFileOpen: onFileOpen,
                                isKeyboardFocused: keyboardFocusController.isFocused
                                    && controlActiveState == .key,
                                onKeyboardFocusRequested: {
                                    claimSidebarKeyboardFocus()
                                }
                            )
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityIdentifier("sidebar")
                    .background(alignment: .topLeading) {
                        SidebarKeyboardFocusBridge(
                            controller: keyboardFocusController,
                            onCommand: handleSidebarCommand,
                            onPrintableText: handleSidebarPrintableText,
                            onReturn: handleSidebarReturn,
                            onSpace: handleSidebarSpace
                        )
                        .frame(width: 1, height: 1)
                    }
                    .focusable()
                    .focused($hasSwiftUIKeyboardFocus)
                    .background(GeometryReader { geo in
                        Color.clear.onAppear { navigation.viewportHeight = geo.size.height }
                            .onChange(of: geo.size.height) { _, h in navigation.viewportHeight = h }
                    })
                    .onChange(of: hasSwiftUIKeyboardFocus) { _, hasFocus in
                        guard hasFocus else { return }
                        // Full Keyboard Access focuses SwiftUI's host first.
                        // Normalize that path to the AppKit responder so a
                        // deferred editor-creation focus cannot displace it.
                        claimSidebarKeyboardFocus()
                    }
                    .environment(editState)
                    .environment(expansion)
                    .environment(navigation)
                    .onChange(of: workspace.rootNodesRevision) { _, _ in
                        // Drop expanded entries for folders that disappeared
                        // (e.g. after delete) so the set stays bounded.
                        expansion.prune(toMatch: workspace.rootNodes)
                        reconcileSelectionAfterReload()
                    }
                    .onAppear {
                        // Wire the ScrollViewReader proxy so selection
                        // changes can keep the selected row visible.
                        navigation.scrollMotion = .resolve(
                            reduceMotion: reduceMotion
                        )
                        navigation.scrollToNode = { id, motion in
                            DispatchQueue.main.async {
                                if motion == .animated {
                                    withAnimation {
                                        scrollProxy.scrollTo(
                                            id,
                                            anchor: .center
                                        )
                                    }
                                } else {
                                    scrollProxy.scrollTo(id, anchor: .center)
                                }
                            }
                        }
                    }
                    .onChange(of: reduceMotion) { _, newValue in
                        navigation.scrollMotion = .resolve(
                            reduceMotion: newValue
                        )
                    }
                    .sidebarKeyboardNavigation(
                        SidebarKeyboardActions(
                            onCommand: { _ = handleSidebarCommand($0) },
                            onCharacters: { handleTypedCharacters($0) }
                        ),
                        isEnabled: editState.renamingURL == nil
                    )
                    .onKeyPress(.return, phases: .down) { press in
                        handleSidebarReturn(
                            modifiers: SidebarKeyboardModifiers(press.modifiers)
                        ) ? .handled : .ignored
                    }
                    .onKeyPress(.space, phases: .down) { press in
                        let modifiers = SidebarKeyboardModifiers(
                            press.modifiers
                        )
                        guard SidebarSpaceAction.accepts(
                            modifiers: modifiers
                        ),
                              editState.renamingURL == nil else {
                            return .ignored
                        }
                        return handleSidebarSpace() ? .handled : .ignored
                    }
                    .contextMenu {
                        if let rootURL = workspace.rootURL {
                            Button {
                                editState.createNewItem(
                                    in: rootURL,
                                    isDirectory: false,
                                    workspace: workspace,
                                    undoManager: undoManager
                                )
                            } label: {
                                Label(Strings.contextNewFile, systemImage: MenuIcons.newFile)
                            }
                            .accessibilityIdentifier(AccessibilityID.contextMenuNewFile)

                            Button {
                                editState.createNewItem(
                                    in: rootURL,
                                    isDirectory: true,
                                    workspace: workspace,
                                    undoManager: undoManager
                                )
                            } label: {
                                Label(Strings.contextNewFolder, systemImage: MenuIcons.newFolder)
                            }
                            .accessibilityIdentifier(AccessibilityID.contextMenuNewFolder)

                            Divider()

                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([rootURL])
                            } label: {
                                Label(Strings.contextRevealInFinder, systemImage: MenuIcons.revealInFinder)
                            }
                        }
                    }
                    .navigationTitle(workspace.projectName)
                    .onChange(of: editState.renamingURL) { _, newURL in
                        if let newURL {
                            // Context-menu rename/new/duplicate paths do not
                            // necessarily pass through a row focus claim.
                            // Claim the AppKit responder before the inline
                            // TextField takes focus so both explicit retries
                            // and implicit editor creation are superseded.
                            navigation.resetTypeAhead()
                            claimSidebarKeyboardFocus()
                            // Keep the edited row selected. Deferring avoids
                            // mutating the binding during the view update, and
                            // also lets a synchronous create/duplicate refresh
                            // install the fresh FileNode first.
                            DispatchQueue.main.async {
                                if case .present(let node) =
                                    SidebarTreeFlattener.lookup(
                                        newURL,
                                        rootNodes: workspace.rootNodes
                                    ) {
                                    selectedFile = node
                                }
                            }
                        }
                    }
                    .onChange(of: editState.scrollToNodeID) { _, targetID in
                        guard let targetID else { return }
                        // Defer scroll to next run loop so the file tree has time to update.
                        DispatchQueue.main.async {
                            if case .present(let node) =
                                SidebarTreeFlattener.lookup(
                                    targetID,
                                    rootNodes: workspace.rootNodes
                                ) {
                                selectedFile = node
                            }
                            withAnimation {
                                scrollProxy.scrollTo(targetID, anchor: .center)
                            }
                            editState.scrollToNodeID = nil
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200, idealWidth: 250)
    }

    /// Opens a new project via folder picker in a new window.
    private func openNewProject() {
        guard let url = registry.openProjectViaPanel() else { return }
        openWindow(value: url)
    }

    /// A sidebar action supersedes any older destination-focus request. The
    /// model is invalidated before AppKit changes first responder so a queued
    /// editor or terminal retry cannot reclaim focus on the next run loop.
    private func claimSidebarKeyboardFocus() {
        paneManager.cancelPendingFocusForActivePane()
        keyboardFocusController.requestFocus()
    }

    private func handleSidebarPrintableText(_ text: String) -> Bool {
        guard editState.renamingURL == nil else { return false }
        handleTypedCharacters(text)
        return true
    }

    /// One production dispatch point for SwiftUI key presses, physical
    /// `NSEvent` navigation, and AppKit standard key-binding selectors.
    private func handleSidebarCommand(
        _ command: SidebarKeyboardCommand
    ) -> Bool {
        guard editState.renamingURL == nil else { return false }

        switch command {
        case .up:
            handleArrow(delta: -1)
        case .down:
            handleArrow(delta: 1)
        case .left:
            handleLeftArrow()
        case .right:
            handleRightArrow()
        case .home:
            handleHome()
        case .end:
            handleEnd()
        case .pageUp:
            handlePageUp()
        case .pageDown:
            handlePageDown()
        }
        return true
    }

    /// Finder-style Return: rename in place. Command-Return is an explicit
    /// open and moves focus into the editor.
    private func handleSidebarReturn(
        modifiers: SidebarKeyboardModifiers
    ) -> Bool {
        guard editState.renamingURL == nil,
              let selected = selectedFile,
              let action = SidebarReturnAction.resolve(
                modifiers: modifiers,
                isRenaming: false,
                selectedIsDirectory: selected.isDirectory
              ) else {
            return false
        }

        switch action {
        case .open:
            navigation.resetTypeAhead()
            onFileOpen(selected, .permanent)
            return true
        case .rename:
            navigation.resetTypeAhead()
            paneManager.cancelPendingFocusForActivePane()
            editState.startRename(for: selected)
            return true
        }
    }

    private func handleSidebarSpace() -> Bool {
        guard editState.renamingURL == nil,
              let selected = selectedFile,
              !selected.isDirectory else {
            return false
        }
        navigation.resetTypeAhead()
        claimSidebarKeyboardFocus()
        onFileOpen(selected, .transientPreview)
        return true
    }

    // MARK: - Finder-style keyboard navigation (#1238)

    /// Flattened list of currently-visible rows (respecting expansion state).
    private var visibleRows: [SidebarVisibleRow] {
        SidebarTreeFlattener.visibleRows(
            rootNodes: workspace.rootNodes,
            expansion: expansion
        )
    }

    /// Updates the selection and ensures the newly-selected row is visible.
    private func navigate(to node: FileNode?) {
        guard let node else { return }
        selectedFile = node
        navigation.scroll(to: node)
    }

    /// Up / Down arrow: move by `delta` visible rows.
    private func handleArrow(delta: Int) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        navigate(to: navigation.move(by: delta, current: selectedFile, rows: rows))
    }

    /// Left: collapse an expanded folder, or move to the parent.
    private func handleLeftArrow() {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        navigate(
            to: navigation.handleLeftArrow(
                current: selectedFile,
                rows: rows,
                expansion: expansion
            )
        )
    }

    /// Right: expand a collapsed folder, or enter the first child.
    private func handleRightArrow() {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        navigate(
            to: navigation.handleRightArrow(
                current: selectedFile,
                rows: rows,
                expansion: expansion
            )
        )
    }

    private func handleHome() {
        navigate(to: navigation.firstRow(rows: visibleRows))
    }

    private func handleEnd() {
        navigate(to: navigation.lastRow(rows: visibleRows))
    }

    private func handlePageUp() {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        navigate(to: navigation.pageUp(current: selectedFile, rows: rows))
    }

    private func handlePageDown() {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        navigate(to: navigation.pageDown(current: selectedFile, rows: rows))
    }

    /// Type-to-select with repeated-character cycling and Unicode support.
    private func handleTypedCharacters(_ characters: String) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        navigate(
            to: navigation.typeSelect(
                character: characters,
                current: selectedFile,
                rows: rows
            )
        )
    }

    private func reconcileSelectionAfterReload() {
        let rows = visibleRows
        let reconciled = navigation.reconciledSelection(
            current: selectedFile,
            rootNodes: workspace.rootNodes,
            rows: rows
        )
        selectedFile = reconciled
        if let reconciled {
            navigation.scroll(to: reconciled)
        }

        if let renamingURL = editState.renamingURL,
           !SidebarTreeFlattener.contains(
               renamingURL,
               rootNodes: workspace.rootNodes
           ) {
            editState.clear()
        }
    }
}

// MARK: - Sidebar searchable content

/// Wrapper view that switches between file tree and search results based on query state.
/// Does not rely on `@Environment(\.isSearching)` or `isSearchPresented` because neither
/// updates reliably when text is entered via XCUITest synthetic events into `NSSearchToolbarItem`.
struct SidebarSearchableContent: View {
    @Binding var selectedNode: FileNode?
    let onFileOpen: (FileNode, SidebarFileOpenDisposition) -> Void
    @Environment(ProjectManager.self) private var projectManager

    var body: some View {
        Group {
            if !projectManager.searchProvider.query.isEmpty {
                SearchResultsView()
            } else {
                SidebarView(
                    selectedFile: $selectedNode,
                    onFileOpen: onFileOpen
                )
            }
        }
        .onKeyPress(.escape) {
            // Escape clears the search query and returns to the file tree.
            if !projectManager.searchProvider.query.isEmpty {
                projectManager.searchProvider.query = ""
                projectManager.searchProvider.cancel()
                return .handled
            }
            return .ignored
        }
    }
}
