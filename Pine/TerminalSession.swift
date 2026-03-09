//
//  TerminalSession.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import Foundation
import Darwin

/// Управляет одним процессом /bin/zsh через pseudo-terminal (PTY).
///
/// PTY — пара виртуальных устройств (master/slave), имитирующих настоящий терминал.
/// Slave подключается к zsh, master остаётся у нас для чтения/записи.
@Observable
final class TerminalSession {
    /// Строки вывода терминала. Массив строк вместо одной большой строки —
    /// проще обрабатывать \r (carriage return = перезаписать текущую строку).
    var lines: [String] = []

    /// Собранный текст для отображения (computed из lines)
    var displayText: String {
        lines.joined(separator: "\n")
    }

    var isRunning = false

    private var process: Process?
    private var masterHandle: FileHandle?

    // Буфер для неполных данных (PTY может прислать полсимвола UTF-8)
    private var pendingData = Data()

    // MARK: - Запуск

    func start(workingDirectory: URL?) {
        guard !isRunning else { return }

        // ── Создаём PTY ──
        var master: Int32 = 0
        var slave: Int32 = 0
        var winSize = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)

        guard openpty(&master, &slave, nil, nil, &winSize) == 0 else {
            lines = ["Error: Failed to create PTY"]
            return
        }

        let masterFH = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let slaveFH = FileHandle(fileDescriptor: slave, closeOnDealloc: false)

        // ── Настраиваем Process ──
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // --no-rcs: не загружаем .zshrc (он источник escape-мусора от oh-my-zsh и т.п.)
        // --no-globalrcs: не загружаем /etc/zshrc
        proc.arguments = ["--no-globalrcs", "--no-rcs"]

        // Минимальное окружение:
        var env: [String: String] = [:]
        env["TERM"] = "dumb"           // "Тупой" терминал — никаких escape-кодов
        env["HOME"] = ProcessInfo.processInfo.environment["HOME"] ?? ""
        env["PATH"] = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
        env["USER"] = ProcessInfo.processInfo.environment["USER"] ?? ""
        env["LANG"] = "en_US.UTF-8"
        // Простой промпт: "папка $ "
        env["PS1"] = "%1~ $ "
        // Отключаем правый промпт (RPS1) и continuation промпт
        env["RPS1"] = ""
        env["PS2"] = "> "
        proc.environment = env

        if let dir = workingDirectory {
            proc.currentDirectoryURL = dir
        }

        proc.standardInput = slaveFH
        proc.standardOutput = slaveFH
        proc.standardError = slaveFH

        // ── Читаем вывод ──
        masterFH.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            DispatchQueue.main.async {
                self?.processOutput(data)
            }
        }

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.lines.append("[Process completed]")
                self?.masterHandle?.readabilityHandler = nil
            }
        }

        // ── Запуск ──
        do {
            try proc.run()
            close(slave)
            self.process = proc
            self.masterHandle = masterFH
            self.isRunning = true
            self.lines = []
        } catch {
            lines = ["Error: \(error.localizedDescription)"]
            close(master)
            close(slave)
        }
    }

    // MARK: - Обработка вывода

    /// Обрабатывает сырые данные из PTY.
    private func processOutput(_ data: Data) {
        pendingData.append(data)

        guard var text = String(data: pendingData, encoding: .utf8) else { return }
        pendingData = Data()

        // Убираем ANSI escape-коды
        text = stripANSI(text)

        // ── Ключевой момент: нормализация переносов строк ──
        // Терминалы шлют \r\n (CR+LF) как перенос строки.
        // Сначала заменяем \r\n на \n, чтобы не путать с одиночным \r.
        text = text.replacingOccurrences(of: "\r\n", with: "\n")

        // Теперь обрабатываем текст посимвольно
        for char in text {
            switch char {
            case "\n":
                // Перенос строки — добавляем новую строку
                lines.append("")
            case "\r":
                // Одиночный \r (без \n) = вернуть курсор в начало текущей строки.
                // Используется для прогресс-баров, спиннеров и т.п.
                if !lines.isEmpty {
                    lines[lines.count - 1] = ""
                }
            case "\u{08}":
                // Backspace (BS, 0x08): удаляем последний символ
                if !lines.isEmpty && !lines[lines.count - 1].isEmpty {
                    lines[lines.count - 1].removeLast()
                }
            default:
                // Обычный символ — добавляем к текущей строке
                if lines.isEmpty {
                    lines.append(String(char))
                } else {
                    lines[lines.count - 1].append(char)
                }
            }
        }

        // Ограничиваем историю
        let maxLines = 10000
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    // MARK: - Очистка ANSI

    private func stripANSI(_ string: String) -> String {
        string.replacingOccurrences(
            // CSI sequences: \e[ ... letter
            // OSC sequences:  \e] ... BEL(\x07) or ST(\e\\)
            // Other escapes:  \e followed by various chars
            of: "\\x1B\\[[0-9;?]*[A-Za-z]|\\x1B\\][^\\x07\\x1B]*(?:\\x07|\\x1B\\\\)|\\x1B[^\\[\\]][A-Za-z0-9]?",
            with: "",
            options: .regularExpression
        )
    }

    // MARK: - Ввод

    func send(_ text: String) {
        guard isRunning, let data = text.data(using: .utf8) else { return }
        masterHandle?.write(data)
    }

    // MARK: - Остановка

    func stop() {
        process?.terminate()
        masterHandle?.readabilityHandler = nil
        process = nil
        masterHandle = nil
        isRunning = false
    }

    deinit {
        stop()
    }
}
