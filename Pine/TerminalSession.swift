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
/// Каждое окно-таб (native macOS window tab) создаёт свой экземпляр контейнера,
/// но LocalProcessTerminalView — один NSView, который может быть только в одном superview.
/// Поэтому только активное (main) окно владеет terminal view.
class TerminalContainerView: NSView {
    var terminal: TerminalManager?
    private var currentTabID: UUID?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeMain),
            name: NSWindow.didBecomeMainNotification,
            object: window
        )
        // Если окно уже main — сразу забираем terminal view
        if window.isMainWindow {
            reclaimIfNeeded()
        }
    }

    @objc private func windowDidBecomeMain() {
        reclaimIfNeeded()
    }

    func showTab(_ tab: TerminalTab?) {
        guard let tab else {
            subviews.forEach { $0.removeFromSuperview() }
            currentTabID = nil
            return
        }
        // Если terminal view уже у нас и таб тот же — ничего не делаем
        guard tab.id != currentTabID || tab.terminalView.superview !== self else { return }
        // Забираем terminal view только если мы в main window
        guard window?.isMainWindow == true else {
            currentTabID = tab.id
            return
        }
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
        } else if window?.isMainWindow == true {
            // Мы main window, но terminal view у другого контейнера — забираем
            showTab(tab)
            tab.terminalView.needsLayout = true
            tab.startIfNeeded()
        }
    }

    private func reclaimIfNeeded() {
        guard let terminal, let tab = terminal.activeTerminalTab else { return }
        if tab.terminalView.superview !== self {
            subviews.forEach { $0.removeFromSuperview() }
            currentTabID = tab.id
            tab.terminalView.frame = bounds
            addSubview(tab.terminalView)
            needsLayout = true
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }
}

// MARK: - Модель вкладки терминала

/// Одна вкладка терминала. Содержит SwiftTerm LocalProcessTerminalView.
/// class (не struct), чтобы view не копировался при передаче.
@Observable
final class TerminalTab: Identifiable, Hashable {
    let id = UUID()
    var name: String
    let terminalView: LocalProcessTerminalView

    private let delegate: TerminalTabDelegate
    private var processStarted = false
    private var workingDirectory: URL?

    init(name: String) {
        self.name = name
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
            executable: "/bin/zsh",
            args: ["--login"],
            environment: envStrings,
            execName: nil,
            currentDirectory: dir
        )
    }

    func stop() {
        // SwiftTerm завершает процесс при деинициализации view
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

    func processTerminated(source: TerminalView, exitCode: Int32?) {}
}
