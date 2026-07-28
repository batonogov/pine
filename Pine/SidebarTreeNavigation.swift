//
//  SidebarTreeNavigation.swift
//  Pine
//
//  Finder-style keyboard navigation and type-to-select for the sidebar
//  file tree (#1238). Provides a single selection model that both the
//  SwiftUI `.onKeyPress` handlers and the AppKit responder route through,
//  eliminating the parallel-state divergence that previously left arrow,
//  Home/End, Page Up/Down, and type-ahead unimplemented.
//

import Foundation

// MARK: - Flattened visible rows

/// A visible row in the sidebar tree, annotated with its nesting depth.
///
/// Depth is used to find a row's parent during Left-arrow navigation
/// without depending on URL path normalisation (which is unreliable
/// across symlinked directories and trailing-slash variants).
struct SidebarVisibleRow: Equatable {
    let node: FileNode
    let depth: Int
}

/// Stable lexical identity for sidebar paths.
///
/// Keyboard navigation runs on the main actor, so identity checks must never
/// resolve symlinks or otherwise consult the file system. Normalizing `.` /
/// `..` components and trailing separators is sufficient because every
/// `FileNode` in a workspace preserves the lexical URL used to load it.
struct SidebarPathIdentity: Hashable, Sendable {
    let path: String

    init(_ url: URL) {
        path = Self.normalizeDarwinRootAlias(Self.normalize(url.path))
    }

    private init(normalizedPath: String) {
        path = normalizedPath
    }

    var parent: SidebarPathIdentity? {
        guard path != "/" && path != "." else { return nil }
        guard let separator = path.lastIndex(of: "/") else {
            return Self(normalizedPath: ".")
        }
        if separator == path.startIndex {
            return Self(normalizedPath: "/")
        }
        return Self(normalizedPath: String(path[..<separator]))
    }

    func isDescendant(of directory: SidebarPathIdentity) -> Bool {
        guard self != directory else { return false }
        let prefix = directory.path == "/"
            ? "/"
            : directory.path + "/"
        return path.hasPrefix(prefix)
    }

    private static func normalize(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var components: [Substring] = []

        for component in path.split(
            separator: "/",
            omittingEmptySubsequences: true
        ) {
            switch component {
            case ".":
                continue
            case "..":
                if components.last != "..", !components.isEmpty {
                    components.removeLast()
                } else if !isAbsolute {
                    components.append(component)
                }
            default:
                components.append(component)
            }
        }

        let normalized = components.joined(separator: "/")
        if isAbsolute {
            return normalized.isEmpty ? "/" : "/" + normalized
        }
        return normalized.isEmpty ? "." : normalized
    }

    /// Foundation can spell children of Darwin's root-level compatibility
    /// symlinks using their `/private` target even when the workspace URL was
    /// opened through `/var`, `/tmp`, or `/etc`. Canonicalize only these
    /// stable system aliases so identity remains lexical and never performs
    /// file-system I/O or resolves user-controlled symlinks.
    private static func normalizeDarwinRootAlias(_ path: String) -> String {
        for alias in ["/var", "/tmp", "/etc"] {
            if path == alias {
                return "/private" + alias
            }
            if path.hasPrefix(alias + "/") {
                return "/private" + path
            }
        }
        return path
    }
}

enum SidebarTreeLookup {
    case present(FileNode)
    case deferred
    case absent
}

/// Flattens the recursive sidebar file tree into the ordered list of
/// currently-visible rows (respecting folder expansion state).
enum SidebarTreeFlattener {
    /// Returns the depth-first list of visible rows. A folder's children
    /// are included only when the folder is expanded and has loaded children.
    static func visibleRows(
        rootNodes: [FileNode],
        expansion: SidebarExpansionState
    ) -> [SidebarVisibleRow] {
        var rows: [SidebarVisibleRow] = []
        appendVisible(rootNodes, depth: 0, expansion: expansion, into: &rows)
        return rows
    }

    /// Returns whether a URL is present in the loaded tree or may still be
    /// present below a deferred folder whose children are not loaded yet.
    ///
    /// Treating a deferred subtree as an indeterminate match prevents the
    /// shallow phase of a progressive refresh from cancelling an inline edit
    /// before the full tree arrives. A later full-tree revision can make the
    /// definitive removal decision.
    static func lookup(_ url: URL, rootNodes: [FileNode]) -> SidebarTreeLookup {
        let target = SidebarPathIdentity(url)
        var hasDeferredAncestor = false
        var stack = rootNodes
        while let node = stack.popLast() {
            let nodeIdentity = SidebarPathIdentity(node.url)
            if nodeIdentity == target {
                return .present(node)
            }
            if node.isDirectory,
               node.hasDeferredChildren,
               target.isDescendant(of: nodeIdentity) {
                hasDeferredAncestor = true
            }
            if let children = node.children {
                stack.append(contentsOf: children)
            }
        }
        return hasDeferredAncestor ? .deferred : .absent
    }

    static func contains(_ url: URL, rootNodes: [FileNode]) -> Bool {
        switch lookup(url, rootNodes: rootNodes) {
        case .present, .deferred:
            return true
        case .absent:
            return false
        }
    }

    private static func appendVisible(
        _ nodes: [FileNode],
        depth: Int,
        expansion: SidebarExpansionState,
        into rows: inout [SidebarVisibleRow]
    ) {
        for node in nodes {
            rows.append(SidebarVisibleRow(node: node, depth: depth))
            if node.isDirectory,
               expansion.isExpanded(node.url),
               let children = node.children {
                appendVisible(children, depth: depth + 1, expansion: expansion, into: &rows)
            }
        }
    }
}

// MARK: - Keyboard input classification

/// Platform-neutral modifier flags used by both the SwiftUI and AppKit
/// sidebar keyboard paths.
struct SidebarKeyboardModifiers: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let command = Self(rawValue: 1 << 0)
    static let control = Self(rawValue: 1 << 1)
    static let option = Self(rawValue: 1 << 2)
    static let shift = Self(rawValue: 1 << 3)
}

/// Classifies text suitable for Finder-style type-to-select.
///
/// A valid input is exactly one printable extended grapheme cluster. Shift is
/// allowed because it participates in producing uppercase letters and
/// punctuation. Option is also allowed when it produced real printable text:
/// localized keyboard layouts and macOS Option composition use that path.
/// Command and Control remain reserved for shortcut chords. Whitespace,
/// controls, standalone non-rendering marks or format scalars, and AppKit's
/// private-use function-key scalars are not type-select input.
enum SidebarTypeSelectInput {
    private static let shortcutModifiers: SidebarKeyboardModifiers = [
        .command, .control,
    ]
    private static let appKitFunctionKeyRange = 0xF700...0xF8FF

    static func printableCharacter(
        from characters: String?,
        modifiers: SidebarKeyboardModifiers
    ) -> String? {
        guard modifiers.isDisjoint(with: shortcutModifiers),
              let characters,
              characters.count == 1,
              let character = characters.first else {
            return nil
        }

        let scalars = character.unicodeScalars
        guard !scalars.isEmpty,
              !scalars.contains(where: {
                  $0.properties.generalCategory == .control
              }),
              scalars.contains(where: { !isNonRendering($0) }),
              !scalars.contains(where: { appKitFunctionKeyRange.contains(Int($0.value)) })
        else {
            return nil
        }

        return String(character)
    }

    private static func isNonRendering(_ scalar: Unicode.Scalar) -> Bool {
        if CharacterSet.whitespacesAndNewlines.contains(scalar) {
            return true
        }
        switch scalar.properties.generalCategory {
        case .control, .format, .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }
}

enum SidebarReturnAction: Equatable, Sendable {
    case rename
    case open

    static func accepts(
        modifiers: SidebarKeyboardModifiers
    ) -> Bool {
        modifiers.isEmpty || modifiers == [.command]
    }

    static func resolve(
        modifiers: SidebarKeyboardModifiers,
        isRenaming: Bool,
        selectedIsDirectory: Bool
    ) -> Self? {
        guard !isRenaming, accepts(modifiers: modifiers) else {
            return nil
        }
        if modifiers == [.command] {
            return selectedIsDirectory ? nil : .open
        }
        return .rename
    }
}

enum SidebarSpaceAction {
    static func accepts(
        modifiers: SidebarKeyboardModifiers
    ) -> Bool {
        modifiers.isEmpty
    }
}

enum SidebarTabTraversalDirection: Equatable, Sendable {
    case next
    case previous

    static func resolve(
        modifiers: SidebarKeyboardModifiers
    ) -> Self? {
        if modifiers.isEmpty { return .next }
        if modifiers == [.shift] { return .previous }
        return nil
    }
}

enum SidebarKeyboardScrollMotion: Equatable, Sendable {
    case animated
    case immediate

    static func resolve(reduceMotion: Bool) -> Self {
        reduceMotion ? .immediate : .animated
    }
}

// MARK: - Type-ahead

/// Finder-style type-to-select with repeated-character cycling.
///
/// Behaviour mirrors macOS Finder:
/// - A single character selects the first visible row whose name begins
///   with that character (case-insensitive, Unicode-aware).
/// - Typing the same character again within the reset interval cycles
///   through all matching rows.
/// - Typing a different character within the interval builds a prefix.
///   If no row matches the full prefix, the buffer resets to the new
///   character alone.
/// - After ``resetInterval`` seconds of inactivity the buffer clears.
struct SidebarTypeAhead {
    /// Current search buffer, normalized for localized matching.
    private(set) var buffer = ""
    private var lastTypedAt: TimeInterval?
    private var sequenceLength = 0
    static let resetInterval: TimeInterval = 0.5

    /// Processes a typed character and returns the index of the row to
    /// select, or `nil` if no row matches.
    mutating func handle(
        character: String,
        rows: [SidebarVisibleRow],
        currentIndex: Int?,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime,
        locale: Locale = .current
    ) -> Int? {
        guard !rows.isEmpty else {
            reset()
            return nil
        }
        let timedOut = lastTypedAt.map {
            now < $0 || now - $0 >= Self.resetInterval
        } ?? true
        defer { lastTypedAt = now }

        let normalizedCharacter = Self.normalized(character, locale: locale)
        guard !normalizedCharacter.isEmpty else { return nil }

        if timedOut {
            buffer = normalizedCharacter
            sequenceLength = 1
            return firstMatch(
                for: normalizedCharacter,
                rows: rows,
                searchOrigin: 0,
                locale: locale
            )
        }

        // Same single character repeated → cycle through matches.
        if sequenceLength == 1, normalizedCharacter == buffer {
            let origin = ((currentIndex ?? -1) + 1) % rows.count
            return firstMatch(
                for: normalizedCharacter,
                rows: rows,
                searchOrigin: max(0, origin),
                locale: locale
            )
        }

        // Build prefix and try to match.
        let candidate = buffer + normalizedCharacter
        if let match = firstMatch(
            for: candidate,
            rows: rows,
            searchOrigin: 0,
            locale: locale
        ) {
            buffer = candidate
            sequenceLength += 1
            return match
        }

        // Multi-char prefix has no match: fall back to the new char alone.
        buffer = normalizedCharacter
        sequenceLength = 1
        return firstMatch(
            for: normalizedCharacter,
            rows: rows,
            searchOrigin: 0,
            locale: locale
        )
    }

    /// Finds the first row (cycling from ``searchOrigin``) whose name
    /// starts with ``prefix``. The comparison is case-insensitive and
    /// works with any Unicode filename (Cyrillic, CJK, etc.).
    private func firstMatch(
        for prefix: String,
        rows: [SidebarVisibleRow],
        searchOrigin: Int,
        locale: Locale
    ) -> Int? {
        guard !prefix.isEmpty, !rows.isEmpty else { return nil }
        let count = rows.count
        let origin = ((searchOrigin % count) + count) % count
        for offset in 0..<count {
            let index = (origin + offset) % count
            let normalizedName = Self.normalized(rows[index].node.name, locale: locale)
            if normalizedName.hasPrefix(prefix) {
                return index
            }
        }
        return nil
    }

    private static func normalized(_ value: String, locale: Locale) -> String {
        value
            .precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: locale
            )
    }

    mutating func reset() {
        buffer = ""
        lastTypedAt = nil
        sequenceLength = 0
    }
}

// MARK: - Navigation model

/// Single selection model for sidebar keyboard navigation.
///
/// Owns type-ahead state and routes all keyboard-driven selection
/// changes through one place so the SwiftUI `.onKeyPress` handlers and
/// the AppKit ``SidebarKeyboardResponderView`` never diverge (#1238).
///
/// The model is **stateless** with respect to the tree contents: every
/// navigation method receives the current flattened row list as a
/// parameter and returns the new selection. Only the type-ahead buffer
/// and the optional scroll callback are stored.
@MainActor
@Observable
final class SidebarTreeNavigation {
    private(set) var typeAhead = SidebarTypeAhead()

    /// Scroll callback invoked after selection changes to keep the
    /// selected row visible. Set by ``SidebarView`` via the
    /// ``ScrollViewProxy`` captured inside ``ScrollViewReader``.
    var scrollToNode: ((URL, SidebarKeyboardScrollMotion) -> Void)?

    /// Updated from SwiftUI's Reduce Motion environment.
    var scrollMotion: SidebarKeyboardScrollMotion = .animated

    /// Viewport height of the sidebar scroll area, used to estimate page
    /// size for Page Up / Page Down.
    var viewportHeight: Double = 400

    /// Estimated number of visible rows per page, derived from the
    /// viewport height and the minimum row height.
    var estimatedPageSize: Int {
        max(1, Int(viewportHeight / SidebarRowMetrics.minRowHeight))
    }

    // MARK: - Linear movement (Up / Down / Home / End / Page)

    func moveDown(current: FileNode?, rows: [SidebarVisibleRow]) -> FileNode? {
        move(by: 1, current: current, rows: rows)
    }

    func moveUp(current: FileNode?, rows: [SidebarVisibleRow]) -> FileNode? {
        move(by: -1, current: current, rows: rows)
    }

    func firstRow(rows: [SidebarVisibleRow]) -> FileNode? {
        typeAhead.reset()
        return rows.first?.node
    }

    func lastRow(rows: [SidebarVisibleRow]) -> FileNode? {
        typeAhead.reset()
        return rows.last?.node
    }

    func pageDown(current: FileNode?, rows: [SidebarVisibleRow]) -> FileNode? {
        move(by: estimatedPageSize, current: current, rows: rows)
    }

    func pageUp(current: FileNode?, rows: [SidebarVisibleRow]) -> FileNode? {
        move(by: -estimatedPageSize, current: current, rows: rows)
    }

    /// Moves the selection by ``delta`` rows, clamping to the visible bounds.
    /// When there is no current selection, Down picks the first row and Up
    /// picks the last row.
    func move(
        by delta: Int,
        current: FileNode?,
        rows: [SidebarVisibleRow]
    ) -> FileNode? {
        typeAhead.reset()
        guard !rows.isEmpty else { return nil }
        let currentIndex = indexOf(current, in: rows)
        let resolvedIndex: Int
        if let currentIndex {
            resolvedIndex = currentIndex
        } else {
            resolvedIndex = delta > 0 ? -1 : rows.count
        }
        let nextIndex = max(0, min(rows.count - 1, resolvedIndex + delta))
        return rows[nextIndex].node
    }

    // MARK: - Expand / collapse (Left / Right)

    /// Left collapses an expanded folder or moves selection to the parent.
    /// Returns the node that should be selected (which may be the same as
    /// `current` when only a collapse occurred), or `nil` if there is no
    /// current selection.
    @discardableResult
    func handleLeftArrow(
        current: FileNode?,
        rows: [SidebarVisibleRow],
        expansion: SidebarExpansionState
    ) -> FileNode? {
        typeAhead.reset()
        guard let visibleCurrent = visibleNode(matching: current, in: rows) else {
            return nil
        }
        if visibleCurrent.isDirectory,
           expansion.isExpanded(visibleCurrent.url) {
            setDisclosure(
                visibleCurrent,
                expanded: false,
                expansion: expansion
            )
            return visibleCurrent
        }
        // Collapsed folder or file → move to parent.
        return parent(of: visibleCurrent, in: rows)
    }

    /// Right expands a collapsed folder or enters the first child of an
    /// already-expanded folder. Returns the node that should be selected
    /// (which may be the same as `current` when only an expansion
    /// occurred), or `nil` for files or folders with no children.
    @discardableResult
    func handleRightArrow(
        current: FileNode?,
        rows: [SidebarVisibleRow],
        expansion: SidebarExpansionState
    ) -> FileNode? {
        typeAhead.reset()
        guard let visibleCurrent = visibleNode(matching: current, in: rows),
              visibleCurrent.isDirectory else {
            return nil
        }
        if !expansion.isExpanded(visibleCurrent.url) {
            setDisclosure(
                visibleCurrent,
                expanded: true,
                expansion: expansion
            )
            return visibleCurrent
        }
        // Already expanded → move to first child.
        if let firstChild = visibleCurrent.children?.first {
            return firstChild
        }
        return nil
    }

    /// Shared disclosure transition used by keyboard, pointer, and
    /// accessibility activation paths.
    @discardableResult
    func setDisclosure(
        _ node: FileNode,
        expanded: Bool,
        expansion: SidebarExpansionState
    ) -> Bool {
        guard node.isDirectory else { return false }
        expansion.setExpanded(node.url, expanded)
        return true
    }

    /// Shared toggle transition. Pointer double-clicks use the debounced
    /// variant; keyboard and accessibility actions are immediate.
    @discardableResult
    func toggleDisclosure(
        _ node: FileNode,
        expansion: SidebarExpansionState,
        debounced: Bool
    ) -> Bool? {
        guard node.isDirectory else { return nil }
        return debounced
            ? expansion.toggleDebounced(node.url)
            : expansion.toggle(node.url)
    }

    // MARK: - Type-ahead

    func typeSelect(
        character: String,
        current: FileNode?,
        rows: [SidebarVisibleRow]
    ) -> FileNode? {
        let currentIndex = indexOf(current, in: rows)
        guard let index = typeAhead.handle(
            character: character,
            rows: rows,
            currentIndex: currentIndex
        ) else {
            return nil
        }
        return rows[index].node
    }

    func resetTypeAhead() {
        typeAhead.reset()
    }

    // MARK: - Reload reconciliation

    /// Rebinds a selection to the fresh `FileNode` instance created by a
    /// workspace reload.
    ///
    /// A progressive shallow reload can temporarily replace a deep subtree
    /// with a deferred folder. In that indeterminate phase the stale node is
    /// deliberately retained as the desired selection. The full reload then
    /// supplies its exact fresh identity. Ancestor fallback is used only when
    /// the complete loaded tree proves that the desired path was removed.
    func reconciledSelection(
        current: FileNode?,
        rootNodes: [FileNode],
        rows: [SidebarVisibleRow]
    ) -> FileNode? {
        guard let current else { return nil }

        switch SidebarTreeFlattener.lookup(
            current.url,
            rootNodes: rootNodes
        ) {
        case .present(let freshNode):
            return freshNode
        case .deferred:
            return current
        case .absent:
            break
        }

        return nearestVisibleAncestor(
            startingAt: SidebarPathIdentity(current.url).parent,
            rows: rows
        )
    }

    // MARK: - Helpers

    func scroll(to node: FileNode) {
        scrollToNode?(node.id, scrollMotion)
    }

    private func indexOf(_ node: FileNode?, in rows: [SidebarVisibleRow]) -> Int? {
        guard let node else { return nil }
        let identity = SidebarPathIdentity(node.url)
        return rows.firstIndex {
            SidebarPathIdentity($0.node.url) == identity
        }
    }

    private func visibleNode(
        matching node: FileNode?,
        in rows: [SidebarVisibleRow]
    ) -> FileNode? {
        guard let index = indexOf(node, in: rows) else { return nil }
        return rows[index].node
    }

    /// Finds the parent of ``node`` by searching backwards for the nearest
    /// visible row at depth ``node.depth - 1``.
    private func parent(of node: FileNode, in rows: [SidebarVisibleRow]) -> FileNode? {
        let identity = SidebarPathIdentity(node.url)
        guard let nodeIndex = rows.firstIndex(where: {
            SidebarPathIdentity($0.node.url) == identity
        }) else {
            return nil
        }
        let targetDepth = rows[nodeIndex].depth - 1
        guard targetDepth >= 0 else { return nil }
        for index in stride(from: nodeIndex - 1, through: 0, by: -1) where rows[index].depth == targetDepth {
            return rows[index].node
        }
        return nil
    }

    private func nearestVisibleAncestor(
        startingAt initialAncestor: SidebarPathIdentity?,
        rows: [SidebarVisibleRow]
    ) -> FileNode? {
        var ancestor = initialAncestor
        while let currentAncestor = ancestor {
            if let row = rows.first(where: {
                $0.node.isDirectory
                    && SidebarPathIdentity($0.node.url) == currentAncestor
            }) {
                return row.node
            }
            ancestor = currentAncestor.parent
        }
        return nil
    }
}
