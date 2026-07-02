//
//  LSPUIEndpoint.swift
//  Pine
//
//  Phase 5 of LSP support (milestone #1088, item 1).
//
//  Bridges the AppKit `CodeEditorView.Coordinator` (which drives hover,
//  go-to-definition, code actions, and rename) to the
//  `@MainActor @Observable` `LSPManager` (which owns the language-server
//  connections).
//
//  Follows the same singleton pattern as `CompletionEndpoint`: the
//  coordinator cannot reach `ProjectManager.lspManager` directly (it lives
//  several SwiftUI layers above the `NSViewRepresentable`), so `PaneLeafView`
//  installs closures on the shared endpoint and the coordinator routes
//  requests through them.
//
//  A single shared endpoint is sufficient because Pine is a document-based
//  app where only one editor pane is first-responder at a time.
//

import Foundation

/// `@MainActor` singleton bridge from the editor coordinator to the active
/// project's `LSPManager` for hover, definition, code action, and rename.
///
/// `PaneLeafView` sets the handler closures when the active editor pane
/// appears (and clears them on disappear) so the coordinator can issue LSP
/// requests without holding a reference to the project.
@MainActor
final class LSPUIEndpoint {

    /// The shared endpoint. There is exactly one per process.
    static let shared = LSPUIEndpoint()

    // MARK: - Hover

    /// Called by the coordinator with the file URL, UTF-16 offset, and full
    /// document text. Returns the server's hover info or `nil`.
    var hoverHandler: ((URL, Int, String) async -> LSPHover?)?

    /// Convenience wrapper that no-ops (returns `nil`) when no handler is
    /// installed.
    func hover(url: URL, offset: Int, text: String) async -> LSPHover? {
        guard let handler else { return nil }
        return await handler(url, offset, text)
    }

    // MARK: - Definition

    /// Called by the coordinator to request go-to-definition.
    var definitionHandler: ((URL, Int, String) async -> LSPDefinitionResponse)?

    /// Convenience wrapper that returns `.empty` when no handler is installed.
    func definition(url: URL, offset: Int, text: String) async -> LSPDefinitionResponse {
        guard let handler else { return .empty }
        return await handler(url, offset, text)
    }

    // MARK: - Code Action

    /// Called by the coordinator to request code actions at the cursor.
    var codeActionHandler: ((URL, Int, String) async -> LSPCodeActionResponse)?

    /// Convenience wrapper that returns empty when no handler is installed.
    func codeAction(url: URL, offset: Int, text: String) async -> LSPCodeActionResponse {
        guard let handler else { return LSPCodeActionResponse(actions: []) }
        return await handler(url, offset, text)
    }

    // MARK: - Rename

    /// Called by the coordinator to request a rename. Returns the
    /// `WorkspaceEdit` or an empty edit.
    var renameHandler: ((URL, Int, String, String) async -> LSPWorkspaceEdit)?

    /// Convenience wrapper that returns an empty edit when no handler.
    func rename(url: URL, offset: Int, text: String, newName: String) async -> LSPWorkspaceEdit {
        guard let handler else { return LSPWorkspaceEdit(operatedFiles: []) }
        return await handler(url, offset, text, newName)
    }

    // MARK: - Workspace edit application

    /// Called by the coordinator to apply a `WorkspaceEdit` (from code action
    /// or rename) across open tabs. Returns `true` on success.
    var applyEditHandler: ((LSPWorkspaceEdit) -> Bool)?

    /// Convenience wrapper that returns `false` when no handler is installed.
    func applyWorkspaceEdit(_ edit: LSPWorkspaceEdit) -> Bool {
        guard let handler else { return false }
        return handler(edit)
    }

    // MARK: - Open file navigation

    /// Called by the coordinator when go-to-definition targets a different
    /// file. The handler should open the file and navigate to the given
    /// line/column (both 0-based LSP positions).
    var openFileAtLineHandler: ((URL, Int, Int) -> Void)?

    /// Convenience wrapper that no-ops when no handler is installed.
    func openFileAtLine(url: URL, line: Int, character: Int) {
        openFileAtLineHandler?(url, line, character)
    }

    private init() {}
}
