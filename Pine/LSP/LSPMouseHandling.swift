//
//  LSPMouseHandling.swift
//  Pine
//
//  Phase 5 of LSP support (milestone #1088, item 1).
//
//  Protocol so the GutterTextView mouse-override methods can call back to
//  the CodeEditorView.Coordinator without a circular import. The coordinator
//  conforms to this protocol.
//

import AppKit

/// Protocol implemented by `CodeEditorView.Coordinator` so that
/// `GutterTextView` mouse overrides can route LSP hover, definition, code
/// action, and rename requests.
@MainActor
protocol LSPMouseHandling: AnyObject {
    /// Called when the mouse hovers over a symbol for the debounce delay.
    /// - Parameters:
    ///   - offset: The UTF-16 offset of the character under the cursor.
    func lspHover(at offset: Int)

    /// Called when the mouse exits the text view or scrolls.
    func lspHoverEnded()

    /// Called when the user ⌘+Clicks a symbol.
    /// - Returns: `true` if the click was handled (definition found).
    func lspGoToDefinition(at offset: Int) -> Bool

    /// Called when the user right-clicks to request code actions.
    /// - Parameters:
    ///   - offset: The UTF-16 offset of the character under the cursor.
    ///   - menuLocation: The click location in the text view's coordinate
    ///     space, for positioning the menu.
    func lspRequestCodeActions(at offset: Int, menuLocation: NSPoint)

    /// Called when the user triggers rename (Cmd+R or menu).
    /// - Parameter offset: The UTF-16 offset of the character to rename.
    func lspRequestRename(at offset: Int)
}
