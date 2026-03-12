//
//  SyntaxHighlighter.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import AppKit

// MARK: - Модели грамматики

/// Одно правило подсветки из JSON.
struct GrammarRule: Codable {
    let pattern: String      // Regex-паттерн
    let scope: String        // Семантический scope: "keyword", "string", "comment" и т.д.
    var options: [String]?   // Опции regex: ["anchorsMatchLines"]
}

/// Грамматика языка, загружаемая из JSON-файла.
struct Grammar: Codable {
    let name: String             // "Swift", "Python" и т.д.
    let extensions: [String]     // ["swift"], ["py", "pyw"]
    let rules: [GrammarRule]     // Правила подсветки
    var fileNames: [String]?     // Точные имена файлов: ["Dockerfile", "Makefile"]
}

// MARK: - Тема (маппинг scope → цвет)

/// Тема определяет цвета для каждого scope.
/// Отделена от грамматик — можно менять тему, не трогая правила.
struct Theme {
    let colors: [String: NSColor]

    /// Тема по умолчанию — адаптируется к light/dark mode.
    static let `default` = Theme(colors: [
        "comment": dynamicColor(light: (0.35, 0.55, 0.33), dark: (0.42, 0.68, 0.40)),
        "string": dynamicColor(light: (0.76, 0.32, 0.18), dark: (0.89, 0.49, 0.33)),
        "keyword": dynamicColor(light: (0.72, 0.20, 0.45), dark: (0.89, 0.36, 0.60)),
        "number": dynamicColor(light: (0.64, 0.58, 0.20), dark: (0.82, 0.76, 0.42)),
        "type": dynamicColor(light: (0.22, 0.55, 0.60), dark: (0.40, 0.78, 0.82)),
        "attribute": dynamicColor(light: (0.52, 0.35, 0.70), dark: (0.68, 0.51, 0.85)),
        "function": dynamicColor(light: (0.25, 0.42, 0.75), dark: (0.40, 0.60, 0.90)),
    ])

    private static func dynamicColor(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat)
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(red: dark.0, green: dark.1, blue: dark.2, alpha: 1)
            } else {
                return NSColor(red: light.0, green: light.1, blue: light.2, alpha: 1)
            }
        }
    }

    func color(for scope: String) -> NSColor? {
        colors[scope]
    }
}

// MARK: - SyntaxHighlighter

/// Единый движок подсветки синтаксиса.
/// Загружает грамматики из JSON-файлов в папке Grammars/ в бандле приложения.
/// При подсветке выбирает грамматику по расширению файла и применяет правила.
final class SyntaxHighlighter {
    /// Singleton — один экземпляр на всё приложение (грамматики загружаются один раз).
    static let shared = SyntaxHighlighter()

    /// Все загруженные грамматики, индексированные по расширению файла.
    /// ["swift": Grammar(...), "py": Grammar(...), "pyw": Grammar(...), ...]
    private var grammarsByExtension: [String: Grammar] = [:]

    /// Грамматики по точному имени файла (Dockerfile, Makefile и т.д.)
    private var grammarsByFileName: [String: Grammar] = [:]

    /// Скомпилированные regex для каждой грамматики (кэшируем для производительности).
    /// Ключ — имя языка, значение — массив пар (regex, scope).
    private var compiledRules: [String: [(regex: NSRegularExpression, scope: String)]] = [:]

    /// Текущая тема
    var theme: Theme = .default

    private init() {
        loadGrammars()
    }

    // MARK: - Загрузка грамматик

    /// Ищет все .json файлы в папке Grammars/ внутри бандла и загружает их.
    private func loadGrammars() {
        // Bundle.main — бандл текущего приложения.
        // .urls(forResourcesWithExtension:subdirectory:) — ищет файлы по расширению в подпапке.
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) else {
            print("SyntaxHighlighter: No grammar files found in bundle")
            return
        }

        let decoder = JSONDecoder()

        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                let grammar = try decoder.decode(Grammar.self, from: data)

                // Индексируем по каждому расширению
                for ext in grammar.extensions {
                    grammarsByExtension[ext.lowercased()] = grammar
                }

                // Индексируем по имени файла (если указано)
                if let fileNames = grammar.fileNames {
                    for name in fileNames {
                        grammarsByFileName[name] = grammar
                    }
                }

                // Компилируем regex один раз при загрузке
                compileRules(for: grammar)

            } catch {
                // Пропускаем файлы, которые не являются грамматиками (например Assets JSON)
                continue
            }
        }

        print("SyntaxHighlighter: Loaded \(Set(grammarsByExtension.values.map(\.name)).count) grammars")
    }

    /// Компилирует regex-паттерны грамматики в NSRegularExpression.
    private func compileRules(for grammar: Grammar) {
        var rules: [(regex: NSRegularExpression, scope: String)] = []

        for rule in grammar.rules {
            var opts: NSRegularExpression.Options = []

            // Преобразуем строковые опции в NSRegularExpression.Options
            if let options = rule.options {
                for opt in options {
                    switch opt {
                    case "anchorsMatchLines":
                        opts.insert(.anchorsMatchLines)
                    case "caseInsensitive":
                        opts.insert(.caseInsensitive)
                    case "dotMatchesLineSeparators":
                        opts.insert(.dotMatchesLineSeparators)
                    default:
                        break
                    }
                }
            }

            if let regex = try? NSRegularExpression(pattern: rule.pattern, options: opts) {
                rules.append((regex: regex, scope: rule.scope))
            } else {
                print("SyntaxHighlighter: Invalid regex in \(grammar.name): \(rule.pattern)")
            }
        }

        compiledRules[grammar.name] = rules
    }

    // MARK: - Подсветка

    /// Количество строк контекста вокруг изменённого региона для инкрементальной подсветки.
    /// Нужно для корректной обработки многострочных конструкций (комментарии, строки).
    private let contextLines = 20

    /// Применяет подсветку ко всему NSTextStorage.
    func highlight(
        textStorage: NSTextStorage,
        language: String,
        fileName: String? = nil,
        font: NSFont
    ) {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        highlightRange(textStorage: textStorage, range: fullRange, language: language, fileName: fileName, font: font)
    }

    /// Инкрементальная подсветка: подсвечивает только изменённый регион
    /// с расширением до границ строк + контекст для многострочных конструкций.
    func highlightEdited(
        textStorage: NSTextStorage,
        editedRange: NSRange,
        language: String,
        fileName: String? = nil,
        font: NSFont
    ) {
        let source = textStorage.string as NSString
        let totalLength = textStorage.length
        guard totalLength > 0 else { return }

        // Расширяем editedRange до границ строк
        var expandedRange = source.lineRange(for: editedRange)

        // Добавляем contextLines строк контекста с каждой стороны
        var linesAdded = 0
        var start = expandedRange.location
        while start > 0 && linesAdded < contextLines {
            start -= 1
            if source.character(at: start) == 0x0A { // '\n'
                linesAdded += 1
            }
        }
        if start > 0 { start += 1 } // не включаем '\n' предыдущей строки

        linesAdded = 0
        var end = NSMaxRange(expandedRange)
        while end < totalLength && linesAdded < contextLines {
            if source.character(at: end) == 0x0A {
                linesAdded += 1
            }
            end += 1
        }

        expandedRange = NSRange(location: start, length: end - start)
        highlightRange(textStorage: textStorage, range: expandedRange, language: language, fileName: fileName, font: font)
    }

    /// Применяет подсветку к указанному диапазону NSTextStorage.
    private func highlightRange(
        textStorage: NSTextStorage,
        range: NSRange,
        language: String,
        fileName: String? = nil,
        font: NSFont
    ) {
        // Ищем грамматику: сначала по имени файла, потом по расширению
        let grammar: Grammar?
        if let name = fileName, let g = grammarsByFileName[name] {
            grammar = g
        } else {
            grammar = grammarsByExtension[language.lowercased()]
        }

        let source = textStorage.string

        // Сбрасываем на базовый стиль в указанном диапазоне
        textStorage.beginEditing()
        textStorage.addAttributes([
            .foregroundColor: NSColor.textColor,
            .font: font
        ], range: range)

        // Если грамматика не найдена — оставляем plain text
        guard let grammar,
              let rules = compiledRules[grammar.name]
        else {
            textStorage.endEditing()
            return
        }

        // Создаём массив "занятых" диапазонов — чтобы comment перекрывал всё
        var highlightedRanges: [(range: NSRange, priority: Int)] = []

        // Приоритеты scopes: comment и string перекрывают остальные
        let scopePriority: [String: Int] = [
            "comment": 100,
            "string": 90
        ]

        for rule in rules {
            let priority = scopePriority[rule.scope] ?? 0
            guard let color = theme.color(for: rule.scope) else { continue }

            rule.regex.enumerateMatches(in: source, range: range) { match, _, _ in
                guard let matchRange = match?.range else { return }

                // Проверяем, не занят ли диапазон более приоритетным scope
                let isOverridden = highlightedRanges.contains { existing in
                    existing.priority > priority &&
                    NSIntersectionRange(existing.range, matchRange).length > 0
                }

                if !isOverridden {
                    textStorage.addAttribute(.foregroundColor, value: color, range: matchRange)
                    highlightedRanges.append((range: matchRange, priority: priority))
                }
            }
        }

        textStorage.endEditing()
    }
}
