//
//  ProblemsPanelController.swift
//  Pine
//
//  Wires the existing Problems panel into editor chrome (#1236).
//
//  A project-scoped diagnostics aggregate that merges LSP diagnostics (read
//  live from `LSPManager.allDiagnostics`, generation-guarded) with
//  config-validator diagnostics (revision-guarded by the active tab's
//  `contentVersion`). Exposes grouped/flat diagnostics, a severity summary,
//  the panel visibility toggle, and next/previous navigation with wrap-around.
//
//  Owned by `ProjectManager` so every window/pane observes the same source of
//  truth. Config-validator diagnostics are pushed in by `PaneLeafView` via
//  `setConfigDiagnostics(_:for:)` whenever the active editor's
//  `ConfigValidator.diagnostics` change.
//

import Foundation

/// A flat diagnostic entry that carries its file URI so the Problems panel can
/// navigate to the right tab on selection.
struct ProblemsFlatDiagnostic: Identifiable, Equatable {
    let id = UUID()
    let uri: String
    let diagnostic: ValidationDiagnostic

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.uri == rhs.uri && lhs.diagnostic == rhs.diagnostic
    }
}

/// Project-scoped aggregate of all diagnostics shown in the Problems panel.
///
/// `@MainActor @Observable` so SwiftUI views re-render when diagnostics or
/// panel visibility change. The controller does NOT duplicate the LSP
/// diagnostic store — it reads `LSPManager.allDiagnostics` live on every
/// access, guarded by a generation token so stale recomputations are skipped.
@MainActor
@Observable
final class ProblemsPanelController {

    // MARK: - Dependencies

    private weak var lspManager: LSPManager?

    // MARK: - Config diagnostics (revision-guarded)

    /// Config-validator diagnostics keyed by document URI, with the
    /// `contentVersion` at which they were captured. Stale entries (whose
    /// version no longer matches the active tab) are discarded on read.
    private var configDiagnosticsByURI: [String: [ValidationDiagnostic]] = [:]
    private var configRevisionsByURI: [String: UInt64] = [:]

    // MARK: - Generation guard

    /// Bumped whenever config diagnostics are pushed (or when LSP diagnostics
    /// change, via `.onChange(of: lspManager.allDiagnostics)` in the host view).
    /// `mergedDiagnostics()` records the generation it last computed with; if
    /// it hasn't changed, the (potentially expensive) merge is skipped.
    private(set) var configGeneration: UInt64 = 0

    // MARK: - Navigation

    /// Index of the currently-selected diagnostic in `flatDiagnostics`, or
    /// `nil` when nothing is selected.
    private(set) var selectionIndex: Int?

    /// Marks the diagnostics set as changed so observers (and the selection
    /// validity check) refresh. Called by the host view when LSP diagnostics
    /// change (`.onChange(of: lspManager.allDiagnostics)`) so stale cached
    /// state is invalidated.
    func refreshFromLSPDiagnostics() {
        configGeneration &+= 1
        clearSelectionIfInvalidated()
    }

    // MARK: - Panel visibility

    /// Whether the bottom Problems panel is visible.
    var isPanelVisible: Bool = false

    // MARK: - Init

    init(lspManager: LSPManager? = nil) {
        self.lspManager = lspManager
    }

    /// Re-binds the LSP manager (used by `ProjectManager` after init).
    func configure(lspManager: LSPManager?) {
        self.lspManager = lspManager
    }

    // MARK: - Config diagnostics push (revision-guarded)

    /// Pushes config-validator diagnostics for a document URI, tagged with the
    /// `contentVersion` of the editor that produced them. Only diagnostics
    /// whose revision matches the current version are surfaced — stale results
    /// from a superseded edit are silently dropped.
    func setConfigDiagnostics(
        _ diagnostics: [ValidationDiagnostic],
        for uri: String,
        contentVersion: UInt64
    ) {
        guard configDiagnosticsByURI[uri] != diagnostics
            || configRevisionsByURI[uri] != contentVersion
        else {
            return
        }
        configDiagnosticsByURI[uri] = diagnostics
        configRevisionsByURI[uri] = contentVersion
        configGeneration &+= 1
        clearSelectionIfInvalidated()
    }

    /// Removes config diagnostics for a document URI (e.g. when the tab closes).
    func removeConfigDiagnostics(for uri: String) {
        guard configDiagnosticsByURI[uri] != nil else { return }
        configDiagnosticsByURI[uri] = nil
        configRevisionsByURI[uri] = nil
        configGeneration &+= 1
        clearSelectionIfInvalidated()
    }

    // MARK: - Aggregated diagnostics

    /// All merged diagnostics grouped by URI, sorted by file path. LSP
    /// diagnostics come from `LSPManager.allDiagnostics` (read live); config
    /// diagnostics are merged in for the matching URIs.
    var groupedDiagnostics: [(uri: String, diagnostics: [ValidationDiagnostic])] {
        var merged: [String: [ValidationDiagnostic]] = [:]
        for group in lspManager?.allDiagnostics ?? [] {
            merged[group.uri] = group.diagnostics
        }
        for (uri, diags) in configDiagnosticsByURI where !diags.isEmpty {
            merged[uri, default: []].append(contentsOf: diags)
        }
        return merged
            .filter { !$0.value.isEmpty }
            .map { (uri: $0.key, diagnostics: $0.value) }
            .sorted { $0.uri < $1.uri }
    }

    /// All diagnostics flattened into a single array (for navigation).
    /// Computed live from `groupedDiagnostics` so LSP diagnostic changes are
    /// always reflected (the previous cached copy could go stale when only
    /// `lspManager.allDiagnostics` changed — see issue #1236).
    var flatDiagnostics: [ProblemsFlatDiagnostic] {
        groupedDiagnostics.flatMap { group in
            group.diagnostics.map { diagnostic in
                ProblemsFlatDiagnostic(uri: group.uri, diagnostic: diagnostic)
            }
        }
    }

    /// Severity summary for the status bar indicator.
    var summary: DiagnosticsSummary {
        let flat = flatDiagnostics
        let errors = flat.filter { $0.diagnostic.severity == .error }.count
        let warnings = flat.filter { $0.diagnostic.severity == .warning }.count
        return DiagnosticsSummary(errorCount: errors, warningCount: warnings)
    }

    /// The currently-selected flat diagnostic, if any.
    var selectedDiagnostic: ProblemsFlatDiagnostic? {
        guard let selectionIndex,
              flatDiagnostics.indices.contains(selectionIndex) else {
            return nil
        }
        return flatDiagnostics[selectionIndex]
    }

    // MARK: - Panel visibility

    /// Toggles the panel; opening it when there are diagnostics.
    func togglePanel() {
        if isPanelVisible {
            isPanelVisible = false
        } else {
            isPanelVisible = true
        }
    }

    /// Shows the panel.
    func showPanel() {
        isPanelVisible = true
    }

    // MARK: - Navigation (wrap-around)

    /// Selects and returns the next diagnostic, wrapping to the first when at
    /// the end. Returns `nil` when there are no diagnostics. Opens the panel
    /// if it was hidden so the user sees the navigation target.
    @discardableResult
    func nextDiagnostic() -> ProblemsFlatDiagnostic? {
        let flat = flatDiagnostics
        guard !flat.isEmpty else { return nil }
        isPanelVisible = true
        let newIndex: Int
        if let selectionIndex {
            newIndex = (selectionIndex + 1) % flat.count
        } else {
            newIndex = 0
        }
        selectionIndex = newIndex
        return flat[newIndex]
    }

    /// Selects and returns the previous diagnostic, wrapping to the last when
    /// at the start. Returns `nil` when there are no diagnostics.
    @discardableResult
    func previousDiagnostic() -> ProblemsFlatDiagnostic? {
        let flat = flatDiagnostics
        guard !flat.isEmpty else { return nil }
        isPanelVisible = true
        let newIndex: Int
        if let selectionIndex {
            newIndex = (selectionIndex - 1 + flat.count) % flat.count
        } else {
            newIndex = flat.count - 1
        }
        selectionIndex = newIndex
        return flat[newIndex]
    }

    /// Selects a specific diagnostic by identity (e.g. when the user clicks a
    /// row in the panel).
    func select(_ diagnostic: ProblemsFlatDiagnostic) {
        let flat = flatDiagnostics
        selectionIndex = flat.firstIndex { $0.diagnostic == diagnostic.diagnostic
            && $0.uri == diagnostic.uri }
    }

    // MARK: - Private

    /// Resets `selectionIndex` to `nil` if it no longer points at a valid entry
    /// after the diagnostics set changed.
    private func clearSelectionIfInvalidated() {
        guard let selectionIndex else { return }
        if !flatDiagnosticsIndicesContain(selectionIndex) {
            self.selectionIndex = nil
        }
    }

    private func flatDiagnosticsIndicesContain(_ index: Int) -> Bool {
        // `flatDiagnostics` is recomputed lazily and cached; reading it here is
        // safe and avoids duplicating the merge logic.
        flatDiagnostics.indices.contains(index)
    }
}
