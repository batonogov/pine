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
    var lineComment: String?     // Символ однострочного комментария: "//", "#" и т.д.
    var filePatterns: [String]?  // Glob-паттерны: ["Dockerfile.*", "*.Dockerfile", ".bashrc"]
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

    /// Грамматики с glob-паттернами (regex прекомпилирован при загрузке).
    private var grammarPatterns: [(regex: NSRegularExpression, grammar: Grammar)] = []

    /// Кэш результатов pattern matching по имени файла.
    private var patternMatchCache: [String: Grammar] = [:]
    /// Имена файлов, для которых ни один паттерн не подошёл.
    private var patternMatchNegativeCache: Set<String> = []

    /// Скомпилированное правило подсветки.
    struct CompiledRule {
        let regex: NSRegularExpression
        let scope: String
        /// true для правил, способных матчить через переносы строк
        /// (паттерн содержит `[\s\S]` или опция dotMatchesLineSeparators).
        let isMultiline: Bool
    }

    /// Скомпилированные regex для каждой грамматики (кэшируем для производительности).
    /// Ключ — имя языка.
    private var compiledRules: [String: [CompiledRule]] = [:]

    /// Кэш «отпечатка» многострочных токенов по ObjectIdentifier текстового хранилища.
    /// Отпечаток — упорядоченный массив длин матчей (без позиций).
    /// Вставка/удаление выше токена сдвигает location, но не меняет длину,
    /// поэтому обычные правки не вызывают ложных полных перекрасок.
    /// Изменение границы токена (добавление/удаление `/*`, `"""` и т.д.)
    /// меняет количество или длину матчей → обнаруживается и запускает full repaint.
    private var multilineMatchCache: [ObjectIdentifier: [Int]] = [:]

    /// Текущая тема
    var theme: Theme = .default

    private init() {
        loadGrammars()
    }

    /// Регистрирует грамматику напрямую (для тестов через @testable import).
    func registerGrammar(_ grammar: Grammar) {
        for ext in grammar.extensions {
            grammarsByExtension[ext.lowercased()] = grammar
        }
        if let fileNames = grammar.fileNames {
            for name in fileNames {
                grammarsByFileName[name] = grammar
            }
        }
        if let patterns = grammar.filePatterns {
            for pattern in patterns {
                if let regex = Self.compileGlob(pattern) {
                    grammarPatterns.append((regex: regex, grammar: grammar))
                }
            }
        }
        patternMatchCache.removeAll()
        patternMatchNegativeCache.removeAll()
        compileRules(for: grammar)
    }

    /// Сбрасывает состояние и перезагружает грамматики из бандла (для тестов).
    func resetForTesting() {
        grammarsByExtension.removeAll()
        grammarsByFileName.removeAll()
        grammarPatterns.removeAll()
        compiledRules.removeAll()
        multilineMatchCache.removeAll()
        patternMatchCache.removeAll()
        patternMatchNegativeCache.removeAll()
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
                registerGrammar(grammar)
            } catch {
                // Пропускаем файлы, которые не являются грамматиками (например Assets JSON)
                continue
            }
        }

        print("SyntaxHighlighter: Loaded \(Set(grammarsByExtension.values.map(\.name)).count) grammars")
    }

    /// Компилирует regex-паттерны грамматики в NSRegularExpression.
    private func compileRules(for grammar: Grammar) {
        var rules: [CompiledRule] = []

        for rule in grammar.rules {
            var opts: NSRegularExpression.Options = []
            var isMultiline = false

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
                        isMultiline = true
                    default:
                        break
                    }
                }
            }

            // Паттерны с [\s\S] матчат через переносы строк
            if rule.pattern.contains("[\\s\\S]") || rule.pattern.contains("[\\S\\s]") {
                isMultiline = true
            }

            if let regex = try? NSRegularExpression(pattern: rule.pattern, options: opts) {
                rules.append(CompiledRule(regex: regex, scope: rule.scope, isMultiline: isMultiline))
            } else {
                print("SyntaxHighlighter: Invalid regex in \(grammar.name): \(rule.pattern)")
            }
        }

        compiledRules[grammar.name] = rules
    }

    // MARK: - Line comment lookup

    /// Returns the line comment prefix for a file extension (e.g. "swift" → "//").
    func lineComment(forExtension ext: String) -> String? {
        grammarsByExtension[ext.lowercased()]?.lineComment
    }

    /// Returns the line comment prefix for a file name (e.g. "Dockerfile" → "#").
    /// Checks exact name first, then glob patterns.
    func lineComment(forFileName name: String) -> String? {
        grammarsByFileName[name]?.lineComment ?? matchFilePattern(name)?.lineComment
    }

    // MARK: - Подсветка

    /// Количество строк контекста вокруг изменённого региона для инкрементальной подсветки.
    private let contextLines = 20

    /// Приоритеты scopes: comment и string перекрывают остальные
    private let scopePriority: [String: Int] = [
        "comment": 100,
        "string": 90
    ]

    /// Применяет подсветку ко всему NSTextStorage и обновляет кэш многострочных матчей.
    func highlight(
        textStorage: NSTextStorage,
        language: String,
        fileName: String? = nil,
        font: NSFont
    ) {
        guard let (_, rules) = resolveGrammar(language: language, fileName: fileName) else {
            resetAttributes(textStorage: textStorage,
                            range: NSRange(location: 0, length: textStorage.length),
                            font: font)
            return
        }

        let fullRange = NSRange(location: 0, length: textStorage.length)
        applyRules(rules, to: textStorage, repaintRange: fullRange, searchRange: fullRange, font: font)

        // Обновляем кэш отпечатка многострочных матчей
        let key = ObjectIdentifier(textStorage)
        multilineMatchCache[key] = collectMultilineFingerprint(
            rules: rules, source: textStorage.string, searchRange: fullRange
        )
    }

    /// Инкрементальная подсветка: подсвечивает только изменённый регион.
    ///
    /// Стратегия:
    /// 1. Многострочные правила (2–3 на грамматику) запускаются по всему тексту,
    ///    чтобы обнаружить токены, начинающиеся за пределами окна.
    ///    Результат сравнивается с кэшем — если границы изменились
    ///    (добавлен/удалён `/*`, `"""` и т.д.), запускается полная перекраска.
    /// 2. Однострочные правила (keyword, type, function и т.д.) запускаются
    ///    только в пределах расширенного диапазона.
    func highlightEdited(
        textStorage: NSTextStorage,
        editedRange: NSRange,
        language: String,
        fileName: String? = nil,
        font: NSFont
    ) {
        let totalLength = textStorage.length
        guard totalLength > 0 else { return }

        guard let (_, rules) = resolveGrammar(language: language, fileName: fileName) else {
            resetAttributes(textStorage: textStorage,
                            range: NSRange(location: 0, length: totalLength),
                            font: font)
            return
        }

        let source = textStorage.string
        let fullRange = NSRange(location: 0, length: totalLength)

        // Сканируем многострочные правила по всему тексту
        let currentFingerprint = collectMultilineFingerprint(
            rules: rules, source: source, searchRange: fullRange
        )

        let key = ObjectIdentifier(textStorage)
        let cachedFingerprint = multilineMatchCache[key]

        // Если структура многострочных токенов изменилась — полная перекраска
        if cachedFingerprint != currentFingerprint {
            multilineMatchCache[key] = currentFingerprint
            applyRules(rules, to: textStorage, repaintRange: fullRange, searchRange: fullRange, font: font)
            return
        }

        // Границы не изменились — инкрементальная подсветка
        let repaintRange = expandToContext(editedRange, in: source as NSString, totalLength: totalLength)
        applyRules(rules, to: textStorage, repaintRange: repaintRange, searchRange: repaintRange, font: font)
    }

    /// Удаляет кэш для textStorage (вызывать при смене файла).
    func invalidateCache(for textStorage: NSTextStorage) {
        multilineMatchCache.removeValue(forKey: ObjectIdentifier(textStorage))
    }

    /// Возвращает диапазоны комментариев и строк для данного текста.
    /// Используется для пропуска скобок при bracket matching.
    func commentAndStringRanges(
        in text: String,
        language: String,
        fileName: String? = nil
    ) -> [NSRange] {
        guard let (_, rules) = resolveGrammar(language: language, fileName: fileName) else {
            return []
        }

        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        var ranges: [NSRange] = []

        for rule in rules where rule.scope == "comment" || rule.scope == "string" {
            rule.regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                if let range = match?.range {
                    ranges.append(range)
                }
            }
        }

        return ranges
    }

    // MARK: - Private helpers

    private func resolveGrammar(language: String, fileName: String?) -> (Grammar, [CompiledRule])? {
        let grammar: Grammar?
        if let name = fileName, let g = grammarsByFileName[name] {
            // 1. Exact fileName match (highest priority)
            grammar = g
        } else if let g = grammarsByExtension[language.lowercased()], !language.isEmpty {
            // 2. Extension match
            grammar = g
        } else if let name = fileName, let g = matchFilePattern(name) {
            // 3. Glob pattern match (lowest priority)
            grammar = g
        } else {
            grammar = nil
        }
        guard let grammar, let rules = compiledRules[grammar.name] else { return nil }
        return (grammar, rules)
    }

    /// Matches a filename against registered glob patterns (with caching).
    private func matchFilePattern(_ fileName: String) -> Grammar? {
        if let cached = patternMatchCache[fileName] {
            return cached
        }
        if patternMatchNegativeCache.contains(fileName) {
            return nil
        }
        let range = NSRange(location: 0, length: (fileName as NSString).length)
        for entry in grammarPatterns where entry.regex.firstMatch(in: fileName, range: range) != nil {
            patternMatchCache[fileName] = entry.grammar
            return entry.grammar
        }
        patternMatchNegativeCache.insert(fileName)
        return nil
    }

    /// Compiles a glob pattern to NSRegularExpression.
    /// `*` matches any sequence of characters (no path separators needed).
    static func compileGlob(_ pattern: String) -> NSRegularExpression? {
        var regex = "^"
        for char in pattern {
            switch char {
            case "*":
                regex += ".*"
            case ".":
                regex += "\\."
            case "\\", "(", ")", "[", "]", "{", "}", "^", "$", "+", "?", "|":
                regex += "\\\(char)"
            default:
                regex += String(char)
            }
        }
        regex += "$"
        return try? NSRegularExpression(pattern: regex)
    }

    /// Simple glob matching (convenience for testing).
    static func fileNameMatchesGlob(_ fileName: String, pattern: String) -> Bool {
        guard let regex = compileGlob(pattern) else { return false }
        let range = NSRange(location: 0, length: (fileName as NSString).length)
        return regex.firstMatch(in: fileName, range: range) != nil
    }

    /// Собирает отпечаток многострочных матчей — упорядоченный массив длин.
    /// Длины инвариантны к вставкам/удалениям выше токена (location сдвигается,
    /// length — нет), поэтому обычные правки не вызывают ложного full repaint.
    private func collectMultilineFingerprint(
        rules: [CompiledRule],
        source: String,
        searchRange: NSRange
    ) -> [Int] {
        var lengths: [Int] = []
        for rule in rules where rule.isMultiline {
            rule.regex.enumerateMatches(in: source, range: searchRange) { match, _, _ in
                if let r = match?.range {
                    lengths.append(r.length)
                }
            }
        }
        return lengths
    }

    /// Расширяет диапазон до границ строк + contextLines контекста.
    private func expandToContext(_ range: NSRange, in source: NSString, totalLength: Int) -> NSRange {
        let expanded = source.lineRange(for: range)

        var linesAdded = 0
        var start = expanded.location
        while start > 0 && linesAdded < contextLines {
            start -= 1
            if source.character(at: start) == 0x0A { linesAdded += 1 }
        }
        if start > 0 { start += 1 }

        linesAdded = 0
        var end = NSMaxRange(expanded)
        while end < totalLength && linesAdded < contextLines {
            if source.character(at: end) == 0x0A { linesAdded += 1 }
            end += 1
        }

        return NSRange(location: start, length: end - start)
    }

    /// Сбрасывает атрибуты на базовый стиль (без грамматики).
    private func resetAttributes(textStorage: NSTextStorage, range: NSRange, font: NSFont) {
        textStorage.beginEditing()
        textStorage.addAttributes([
            .foregroundColor: NSColor.textColor,
            .font: font
        ], range: range)
        textStorage.endEditing()
    }

    /// Применяет правила подсветки.
    ///
    /// - `repaintRange`: диапазон, в котором сбрасываются и перекрашиваются атрибуты.
    /// - `searchRange`: диапазон поиска для однострочных правил.
    ///   Многострочные правила всегда ищут по всему тексту (через fullRange),
    ///   чтобы обнаружить токены, начинающиеся до repaintRange.
    private func applyRules(
        _ rules: [CompiledRule],
        to textStorage: NSTextStorage,
        repaintRange: NSRange,
        searchRange: NSRange,
        font: NSFont
    ) {
        let source = textStorage.string
        let fullRange = NSRange(location: 0, length: textStorage.length)

        textStorage.beginEditing()
        textStorage.addAttributes([
            .foregroundColor: NSColor.textColor,
            .font: font
        ], range: repaintRange)

        var highlightedRanges: [(range: NSRange, priority: Int)] = []

        for rule in rules {
            let priority = scopePriority[rule.scope] ?? 0
            guard let color = theme.color(for: rule.scope) else { continue }

            // Многострочные правила ищут по всему тексту,
            // однострочные — только в searchRange
            let scanRange = rule.isMultiline ? fullRange : searchRange

            rule.regex.enumerateMatches(in: source, range: scanRange) { match, _, _ in
                guard let matchRange = match?.range else { return }

                // Красим только пересечение с repaintRange
                let clipped = NSIntersectionRange(matchRange, repaintRange)
                guard clipped.length > 0 else { return }

                let isOverridden = highlightedRanges.contains { existing in
                    existing.priority > priority &&
                    NSIntersectionRange(existing.range, clipped).length > 0
                }

                if !isOverridden {
                    textStorage.addAttribute(.foregroundColor, value: color, range: clipped)
                    highlightedRanges.append((range: clipped, priority: priority))
                }
            }
        }

        textStorage.endEditing()
    }
}
