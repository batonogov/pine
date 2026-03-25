//
//  TerminalSession.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import SwiftUI
import SwiftTerm

// MARK: - NSViewRepresentable обёртка для SwiftTerm

/// Единый NSViewRepresentable для терминала.
/// Создаётся один раз и никогда не пересоздаётся SwiftUI.
/// Переключение терминальных табов происходит на уровне AppKit.
struct TerminalContentView: NSViewRepresentable {
    let terminal: TerminalManager

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        container.terminal = terminal
        container.showTab(terminal.activeTerminalTab)
        return container
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        container.showTab(terminal.activeTerminalTab)
    }
}

/// Контейнер NSView, который управляет размером LocalProcessTerminalView.
/// SwiftTerm ожидает ручное управление frame (как в официальном примере),
/// а не Auto Layout constraints.
///
/// With internal editor tabs there is only one window,
/// so no multi-window reclaim logic is needed.
class TerminalContainerView: NSView {
    var terminal: TerminalManager?
    private var currentTabID: UUID?

    func showTab(_ tab: TerminalTab?) {
        guard let tab else {
            subviews.forEach { $0.removeFromSuperview() }
            currentTabID = nil
            return
        }
        // Если terminal view уже у нас и таб тот же — ничего не делаем
        guard tab.id != currentTabID || tab.terminalView.superview !== self else { return }
        subviews.forEach { $0.removeFromSuperview() }
        currentTabID = tab.id
        tab.terminalView.frame = bounds
        addSubview(tab.terminalView)
    }

    override func layout() {
        super.layout()
        guard let terminal, let tab = terminal.activeTerminalTab else { return }
        if tab.terminalView.superview === self {
            tab.terminalView.frame = bounds
            tab.terminalView.needsLayout = true
            tab.startIfNeeded()
        } else {
            showTab(tab)
            tab.terminalView.needsLayout = true
            tab.startIfNeeded()
        }
    }

    override var isFlipped: Bool { true }

    // MARK: - Scroll wheel forwarding to TUI apps

    /// Intercepts scroll wheel events and forwards them as mouse button events
    /// when a TUI app has enabled mouse reporting (e.g. k9s, htop, lazygit).
    ///
    /// SwiftTerm's `scrollWheel(with:)` always performs scrollback navigation
    /// and does not check `mouseMode`. This override sends VT100 mouse button 4/5
    /// events when mouse reporting is active, falling back to SwiftTerm's default
    /// scrollback behavior otherwise.
    override func scrollWheel(with event: NSEvent) {
        guard event.deltaY != 0,
              let tab = terminal?.activeTerminalTab else {
            super.scrollWheel(with: event)
            return
        }

        let term = tab.terminalView.getTerminal()

        // When mouse reporting is off, let SwiftTerm handle scrollback
        guard term.mouseMode != .off else {
            super.scrollWheel(with: event)
            return
        }

        let modifiers = event.modifierFlags
        let buttonFlags = MouseScrollForwarder.encodeScrollButton(
            deltaY: event.deltaY,
            shift: modifiers.contains(.shift),
            option: modifiers.contains(.option),
            control: modifiers.contains(.control)
        )

        let locationInTerminal = tab.terminalView.convert(event.locationInWindow, from: nil)
        let pos = MouseScrollForwarder.gridPosition(
            point: locationInTerminal,
            viewBounds: tab.terminalView.bounds,
            cols: term.cols,
            rows: term.rows,
            isFlipped: tab.terminalView.isFlipped
        )

        // Send multiple events for scroll velocity (matching SwiftTerm's velocity logic)
        let velocity = MouseScrollForwarder.scrollVelocity(delta: event.deltaY)
        for _ in 0..<velocity {
            term.sendEvent(buttonFlags: buttonFlags, x: pos.col, y: pos.row)
        }
    }
}

// MARK: - Terminal search

/// A match found in the terminal scrollback buffer.
struct TerminalSearchMatch {
    let row: Int
    let col: Int
    let length: Int
}

// MARK: - Модель вкладки терминала

/// Одна вкладка терминала. Содержит SwiftTerm LocalProcessTerminalView.
/// class (не struct), чтобы view не копировался при передаче.
@Observable
final class TerminalTab: Identifiable, Hashable {
    let id = UUID()
    var name: String
    let terminalView: LocalProcessTerminalView
    fileprivate(set) var isTerminated = false

    // MARK: - Search state

    /// All matches found by the most recent search.
    var searchMatches: [TerminalSearchMatch] = []
    /// Index into `searchMatches` for the currently highlighted match, or -1 if none.
    var currentMatchIndex: Int = -1
    /// Total number of lines from the last search (used for scroll positioning).
    private var searchTotalRows: Int = 0

    private let delegate: TerminalTabDelegate
    private let shellSettings: ShellSettings
    private var processStarted = false
    private var workingDirectory: URL?

    init(name: String, shellSettings: ShellSettings = .shared) {
        self.name = name
        self.shellSettings = shellSettings
        self.terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        self.delegate = TerminalTabDelegate()
        self.delegate.tab = self
        self.terminalView.processDelegate = self.delegate

        // Настраиваем внешний вид сразу — шрифт определяет размер ячейки
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.nativeForegroundColor = .textColor
        terminalView.nativeBackgroundColor = .textBackgroundColor

        // Terminal.app color palette — color 8 (bright black) is a subdued gray
        // so zsh-autosuggestions (fg=8) appear dimmed, not bright.
        func c(_ r: UInt16, _ g: UInt16, _ b: UInt16) -> SwiftTerm.Color {
            SwiftTerm.Color(red: r * 257, green: g * 257, blue: b * 257)
        }
        terminalView.installColors([
            c(0, 0, 0),         // 0: black
            c(194, 54, 33),     // 1: red
            c(37, 188, 36),     // 2: green
            c(173, 173, 39),    // 3: yellow
            c(73, 46, 225),     // 4: blue
            c(211, 56, 211),    // 5: magenta
            c(51, 187, 200),    // 6: cyan
            c(203, 204, 205),   // 7: white
            c(80, 80, 80),       // 8: bright black (dim gray — for autosuggestions)
            c(252, 57, 31),     // 9: bright red
            c(49, 231, 34),     // 10: bright green
            c(234, 236, 35),    // 11: bright yellow
            c(88, 51, 255),     // 12: bright blue
            c(249, 53, 248),    // 13: bright magenta
            c(20, 240, 240),    // 14: bright cyan
            c(233, 235, 235),   // 15: bright white
        ])
    }

    /// Сохраняет рабочую директорию для отложенного запуска
    func configure(workingDirectory: URL?) {
        self.workingDirectory = workingDirectory
    }

    /// Запускает процесс если ещё не запущен и view добавлен в иерархию
    func startIfNeeded() {
        guard !processStarted else { return }
        processStarted = true

        var env = ProcessInfo.processInfo.environment
        env["PINE_TERMINAL"] = "1"
        env["TERM"] = "xterm-256color"

        let envStrings = env.map { "\($0.key)=\($0.value)" }
        let dir = workingDirectory?.path ?? (env["HOME"] ?? "/")

        terminalView.startProcess(
            executable: shellSettings.resolvedShellPath,
            args: shellSettings.shellArgs,
            environment: envStrings,
            execName: nil,
            currentDirectory: dir
        )
    }

    func stop() {
        guard !isTerminated else { return }
        isTerminated = true
        terminalView.terminate()
    }

    /// Whether the shell process is still running.
    var isProcessRunning: Bool {
        !isTerminated && processStarted && terminalView.process.running
    }

    /// Whether a foreground process (child of the shell) is currently running.
    /// Returns true if tcgetpgrp reports a different process group than the shell.
    var hasForegroundProcess: Bool {
        guard isProcessRunning else { return false }
        let fd = terminalView.process.childfd
        guard fd >= 0 else { return false }
        let foregroundPgid = tcgetpgrp(fd)
        let shellPid = terminalView.process.shellPid
        return foregroundPgid > 0 && foregroundPgid != shellPid
    }

    // MARK: - Search

    /// Searches the terminal scrollback buffer for `query` and stores matches.
    /// The heavy work runs off the main actor; only the final state update
    /// and scroll happen on main.
    ///
    /// Uses SwiftTerm's public `getBufferAsData()` to extract the full buffer
    /// content without accessing internal `buffer.lines`.
    @MainActor
    func search(for query: String, caseSensitive: Bool = false) async {
        guard !query.isEmpty else {
            searchMatches = []
            currentMatchIndex = -1
            searchTotalRows = 0
            return
        }

        // Store for SwiftTerm findNext/findPrevious highlight calls
        lastSearchQuery = query
        lastSearchOptions = SearchOptions(caseSensitive: caseSensitive)

        // Extract full buffer text via public API on main thread
        let terminal = terminalView.getTerminal()
        let bufferData = terminal.getBufferAsData()

        // Search off main thread
        let searchQuery = query
        let isCaseSensitive = caseSensitive
        let (matches, totalRows) = await Task.detached(priority: .userInitiated) {
            guard let bufferText = String(data: bufferData, encoding: .utf8) else {
                return ([TerminalSearchMatch](), 0)
            }
            let lines = bufferText.split(separator: "\n", omittingEmptySubsequences: false)
            let needle = isCaseSensitive ? searchQuery : searchQuery.lowercased()
            var result: [TerminalSearchMatch] = []
            for (row, line) in lines.enumerated() {
                let haystack = isCaseSensitive ? String(line) : String(line).lowercased()
                var searchStart = haystack.startIndex
                while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
                    let col = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
                    let length = haystack.distance(from: range.lowerBound, to: range.upperBound)
                    result.append(TerminalSearchMatch(row: row, col: col, length: length))
                    searchStart = range.upperBound
                }
            }
            return (result, lines.count)
        }.value

        guard !Task.isCancelled else { return }

        searchMatches = matches
        searchTotalRows = totalRows
        if matches.isEmpty {
            currentMatchIndex = -1
            terminalView.clearSearch()
        } else {
            currentMatchIndex = 0
            highlightCurrentMatch()
        }
    }

    /// Advances to the next match, highlights it via SwiftTerm selection, and scrolls to it.
    func nextMatch() {
        guard !searchMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % searchMatches.count
        highlightCurrentMatch()
    }

    /// Goes back to the previous match, highlights it, and scrolls to it.
    func previousMatch() {
        guard !searchMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + searchMatches.count) % searchMatches.count
        terminalView.findPrevious(lastSearchQuery, options: lastSearchOptions)
    }

    /// Clears search results, resets state, and removes selection highlight.
    func clearSearch() {
        searchMatches = []
        currentMatchIndex = -1
        searchTotalRows = 0
        lastSearchQuery = ""
        terminalView.clearSearch()
    }

    /// Last query/options used for findNext/findPrevious calls.
    private var lastSearchQuery = ""
    private var lastSearchOptions = SearchOptions()

    /// Highlights the current match using SwiftTerm's built-in find (which sets selection)
    /// and scrolls to it.
    private func highlightCurrentMatch() {
        guard currentMatchIndex >= 0, currentMatchIndex < searchMatches.count else { return }
        // SwiftTerm's findNext/findPrevious iterates through matches and highlights via selection.
        // We call the appropriate one to move SwiftTerm's internal cursor to our target match.
        terminalView.findNext(lastSearchQuery, options: lastSearchOptions)
    }

    static func == (lhs: TerminalTab, rhs: TerminalTab) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Делегат SwiftTerm

class TerminalTabDelegate: NSObject, LocalProcessTerminalViewDelegate {
    weak var tab: TerminalTab?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        tab?.name = title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        tab?.isTerminated = true
    }
}
