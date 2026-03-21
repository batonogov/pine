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
    /// Scrolls to the first match if any are found.
    ///
    /// - Note: Uses SwiftTerm's `Terminal.buffer` for text extraction.
    ///   `terminal.buffer.lines` is a `CircularList<BufferLine>` and
    ///   `BufferLine.translateToString(trimRight:)` extracts the line as a String.
    func search(for query: String, caseSensitive: Bool = false) {
        guard !query.isEmpty else {
            searchMatches = []
            currentMatchIndex = -1
            return
        }

        let terminal = terminalView.getTerminal()
        let buffer = terminal.buffer
        let totalRows = buffer.lines.count
        let searchText = caseSensitive ? query : query.lowercased()

        var matches: [TerminalSearchMatch] = []

        for row in 0..<totalRows {
            let lineText: String = {
                let raw = buffer.lines[row].translateToString(trimRight: true)
                return caseSensitive ? raw : raw.lowercased()
            }()

            var searchStart = lineText.startIndex
            while let range = lineText.range(of: searchText, range: searchStart..<lineText.endIndex) {
                let col = lineText.distance(from: lineText.startIndex, to: range.lowerBound)
                matches.append(TerminalSearchMatch(row: row, col: col, length: query.count))
                searchStart = range.upperBound
            }
        }

        searchMatches = matches
        if matches.isEmpty {
            currentMatchIndex = -1
        } else {
            currentMatchIndex = 0
            scrollToCurrentMatch()
        }
    }

    /// Advances to the next match and scrolls to it.
    func nextMatch() {
        guard !searchMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % searchMatches.count
        scrollToCurrentMatch()
    }

    /// Goes back to the previous match and scrolls to it.
    func previousMatch() {
        guard !searchMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + searchMatches.count) % searchMatches.count
        scrollToCurrentMatch()
    }

    /// Clears search results and resets state.
    func clearSearch() {
        searchMatches = []
        currentMatchIndex = -1
    }

    /// Scrolls the terminal view to show the row of the current match.
    ///
    /// - Note: Uses SwiftTerm's `Buffer.yDisp` to control the scroll offset.
    ///   `yDisp` is the index of the first visible line in the scrollback buffer.
    ///   Setting it and triggering a redraw scrolls the terminal to the target row.
    private func scrollToCurrentMatch() {
        guard currentMatchIndex >= 0, currentMatchIndex < searchMatches.count else { return }
        let targetRow = searchMatches[currentMatchIndex].row
        let terminal = terminalView.getTerminal()
        let buffer = terminal.buffer
        let halfRows = max(1, terminal.rows / 2)
        // Place the match in the middle of the viewport
        let targetDisp = max(0, min(targetRow - halfRows, buffer.lines.count - terminal.rows))
        buffer.yDisp = targetDisp
        terminalView.setNeedsDisplay(terminalView.bounds)
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
