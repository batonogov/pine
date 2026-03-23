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

/// Block comment delimiters (e.g. `/* */`, `<!-- -->`).
struct BlockCommentDelimiters: Codable {
    let open: String
    let close: String
}

/// Грамматика языка, загружаемая из JSON-файла.
struct Grammar: Codable {
    let name: String             // "Swift", "Python" и т.д.
    let extensions: [String]     // ["swift"], ["py", "pyw"]
    let rules: [GrammarRule]     // Правила подсветки
    var fileNames: [String]?     // Точные имена файлов: ["Dockerfile", "Makefile"]
    var filePatterns: [String]?  // Glob-паттерны: ["Dockerfile.*", "*.Dockerfile"]
    var lineComment: String?     // Символ однострочного комментария: "//", "#" и т.д.
    var blockComment: BlockCommentDelimiters? // Блочный комментарий: {"open": "/*", "close": "*/"}
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
/// Thread-safe generation counter for cancelling stale highlight requests.
final class HighlightGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int = 0

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

/// A single match found by regex computation (value type, safe to pass between threads).
struct HighlightMatch: Sendable {
    let range: NSRange
    let scope: String
    let priority: Int
}

/// Result of background match computation.
struct HighlightMatchResult: Sendable {
    let matches: [HighlightMatch]
    let repaintRange: NSRange
    let multilineFingerprint: [Int]
}

final class SyntaxHighlighter: @unchecked Sendable {
    /// Singleton — один экземпляр на всё приложение (грамматики загружаются один раз).
    static let shared = SyntaxHighlighter()

    /// Все загруженные грамматики, индексированные по расширению файла.
    /// ["swift": Grammar(...), "py": Grammar(...), "pyw": Grammar(...), ...]
    private var grammarsByExtension: [String: Grammar] = [:]

    /// Грамматики по точному имени файла (Dockerfile, Makefile и т.д.)
    private var grammarsByFileName: [String: Grammar] = [:]

    /// Грамматики с glob-паттернами для имён файлов.
    /// Каждый элемент: (паттерн, грамматика). Проверяются после exact match.
    private var grammarsByFilePattern: [(pattern: String, grammar: Grammar)] = []

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
                grammarsByFilePattern.append((pattern: pattern, grammar: grammar))
            }
        }
        compileRules(for: grammar)
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

                // Индексируем glob-паттерны
                if let patterns = grammar.filePatterns {
                    for pattern in patterns {
                        grammarsByFilePattern.append((pattern: pattern, grammar: grammar))
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

    /// Returns the line comment prefix for an exact file name (e.g. "Dockerfile" → "#").
    func lineComment(forFileName name: String) -> String? {
        grammarsByFileName[name]?.lineComment ?? matchFilePattern(name)?.lineComment
    }

    // MARK: - Comment info lookup

    /// Resolved comment style for a file — line comment preferred, block comment as fallback.
    enum CommentStyle {
        case line(String)
        case block(open: String, close: String)
    }

    /// Returns the preferred comment style for a file, resolving by exact name first, then extension.
    /// Line comments take priority over block comments.
    func commentStyle(forExtension ext: String?, fileName: String?) -> CommentStyle? {
        let grammar: Grammar?
        if let name = fileName, let g = grammarsByFileName[name] {
            grammar = g
        } else if let ext, let g = grammarsByExtension[ext.lowercased()] {
            grammar = g
        } else {
            grammar = nil
        }
        guard let grammar else { return nil }

        if let lc = grammar.lineComment {
            return .line(lc)
        } else if let bc = grammar.blockComment {
            return .block(open: bc.open, close: bc.close)
        }
        return nil
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
        let result = applyRules(
            rules, to: textStorage, repaintRange: fullRange, searchRange: fullRange, font: font
        )
        multilineMatchCache[ObjectIdentifier(textStorage)] = result.multilineFingerprint
    }

    /// Количество строк контекста для viewport-based подсветки (больше, чем для edit).
    private let viewportContextLines = 100
    /// Extra context lines for multiline rules (block comments, multiline strings).
    /// 500 lines in each direction is enough to catch most multiline constructs
    /// without scanning the entire file.
    private let multilineContextLines = 500

    /// Подсветка только видимой области + буфер.
    /// Используется для больших файлов вместо полного `highlight()`.
    func highlightVisibleRange(
        textStorage: NSTextStorage,
        visibleCharRange: NSRange,
        language: String,
        fileName: String? = nil,
        font: NSFont
    ) {
        let totalLength = textStorage.length
        guard totalLength > 0 else { return }

        guard let (_, rules) = resolveGrammar(language: language, fileName: fileName) else {
            resetAttributes(textStorage: textStorage,
                            range: visibleCharRange,
                            font: font)
            return
        }

        let source = textStorage.string as NSString

        // Expand visible range by viewportContextLines
        let expanded = expandToContext(
            visibleCharRange, in: source, totalLength: totalLength, lines: viewportContextLines
        )

        // Multiline rules (block comments, multiline strings) use an expanded range
        // (±500 lines) instead of the full text, so they catch constructs starting
        // above the viewport without scanning the entire file.
        let result = applyRules(
            rules, to: textStorage, repaintRange: expanded, searchRange: expanded, font: font
        )

        // Build multiline match cache (needed for subsequent highlightEdited calls)
        let key = ObjectIdentifier(textStorage)
        if multilineMatchCache[key] == nil {
            multilineMatchCache[key] = result.multilineFingerprint
        }
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
            let result = applyRules(
                rules, to: textStorage, repaintRange: fullRange, searchRange: fullRange, font: font
            )
            multilineMatchCache[key] = result.multilineFingerprint
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
            // Приоритет 1: точное совпадение имени файла
            grammar = g
        } else if let g = grammarsByExtension[language.lowercased()] {
            // Приоритет 2: совпадение по расширению
            grammar = g
        } else if let name = fileName, let g = matchFilePattern(name) {
            // Приоритет 3: glob-паттерн имени файла
            grammar = g
        } else {
            grammar = nil
        }
        guard let grammar, let rules = compiledRules[grammar.name] else { return nil }
        return (grammar, rules)
    }

    /// Проверяет имя файла по glob-паттернам. `*` матчит любые символы.
    private func matchFilePattern(_ fileName: String) -> Grammar? {
        for entry in grammarsByFilePattern where globMatch(pattern: entry.pattern, string: fileName) {
            return entry.grammar
        }
        return nil
    }

    /// Простой glob-matching: `*` матчит любую последовательность символов (кроме пустой, если не в начале/конце).
    private func globMatch(pattern: String, string: String) -> Bool {
        // Конвертируем glob в regex: экранируем спецсимволы, заменяем * на .*
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        let regexPattern = "^" + escaped + "$"
        guard let regex = try? NSRegularExpression(pattern: regexPattern) else { return false }
        let range = NSRange(location: 0, length: (string as NSString).length)
        return regex.firstMatch(in: string, range: range) != nil
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

    /// Расширяет диапазон до границ строк + N строк контекста.
    private func expandToContext(
        _ range: NSRange,
        in source: NSString,
        totalLength: Int,
        lines: Int? = nil
    ) -> NSRange {
        let contextCount = lines ?? contextLines
        let expanded = source.lineRange(for: range)

        var linesAdded = 0
        var start = expanded.location
        while start > 0 && linesAdded < contextCount {
            start -= 1
            if source.character(at: start) == 0x0A { linesAdded += 1 }
        }
        if start > 0 { start += 1 }

        linesAdded = 0
        var end = NSMaxRange(expanded)
        while end < totalLength && linesAdded < contextCount {
            if source.character(at: end) == 0x0A { linesAdded += 1 }
            end += 1
        }

        return NSRange(location: start, length: end - start)
    }

    /// Сбрасывает атрибуты на базовый стиль (без грамматики).
    /// Clamps range to textStorage.length to avoid crash if text changed.
    private func resetAttributes(textStorage: NSTextStorage, range: NSRange, font: NSFont) {
        let currentLength = textStorage.length
        guard currentLength > 0 else { return }
        let safeRange = NSRange(
            location: min(range.location, currentLength),
            length: min(range.length, currentLength - min(range.location, currentLength))
        )
        guard safeRange.length > 0 else { return }

        let undoManager = textStorage.layoutManagers.first?.firstTextView?.undoManager
        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }
        textStorage.beginEditing()
        textStorage.addAttributes([
            .foregroundColor: NSColor.textColor,
            .font: font
        ], range: safeRange)
        textStorage.endEditing()
    }

    /// Применяет правила подсветки.
    /// Делегирует в `computeMatches` + `applyMatches` для единой логики.
    ///
    /// - `repaintRange`: диапазон, в котором сбрасываются и перекрашиваются атрибуты.
    /// - `searchRange`: диапазон поиска для однострочных правил.
    ///   Многострочные правила всегда ищут по всему тексту (через fullRange),
    ///   чтобы обнаружить токены, начинающиеся до repaintRange.
    @discardableResult
    private func applyRules(
        _ rules: [CompiledRule],
        to textStorage: NSTextStorage,
        repaintRange: NSRange,
        searchRange: NSRange,
        font: NSFont
    ) -> HighlightMatchResult {
        let result = computeMatchesWithRules(
            rules, text: textStorage.string, repaintRange: repaintRange, searchRange: searchRange
        )
        applyMatches(result, to: textStorage, font: font)
        return result
    }

    // MARK: - Async highlighting (background computation)

    /// Background queue for regex computation.
    private let highlightQueue = DispatchQueue(
        label: "com.pine.syntax-highlight",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Pure computation: finds regex matches without touching NSTextStorage.
    /// Thread-safe — operates only on the provided String snapshot.
    ///
    /// - Parameters:
    ///   - text: snapshot of the text to search
    ///   - language: file extension for grammar lookup
    ///   - fileName: optional file name for grammar lookup
    ///   - repaintRange: range to clip matches to
    ///   - searchRange: range to search for single-line rules
    /// - Returns: match results, or nil if no grammar found
    func computeMatches(
        text: String,
        language: String,
        fileName: String? = nil,
        repaintRange: NSRange,
        searchRange: NSRange
    ) -> HighlightMatchResult? {
        guard let (_, rules) = resolveGrammar(language: language, fileName: fileName) else {
            return nil
        }
        return computeMatchesWithRules(rules, text: text, repaintRange: repaintRange, searchRange: searchRange)
    }

    /// Core match computation — used by both `computeMatches` and `applyRules`.
    /// Thread-safe: only reads immutable compiled rules and the provided text snapshot.
    private func computeMatchesWithRules(
        _ rules: [CompiledRule],
        text: String,
        repaintRange: NSRange,
        searchRange: NSRange
    ) -> HighlightMatchResult {
        let source = text as NSString
        let totalLength = source.length
        let fullRange = NSRange(location: 0, length: totalLength)

        // Expanded range for multiline rules: ±500 lines around searchRange,
        // clamped to the full text. Catches block comments/strings that start
        // above the viewport without scanning the entire file.
        let multilineRange = expandToContext(
            searchRange, in: source, totalLength: totalLength, lines: multilineContextLines
        )

        var matches: [HighlightMatch] = []
        var highlightedRanges: [(range: NSRange, priority: Int)] = []

        for rule in rules {
            let priority = scopePriority[rule.scope] ?? 0
            guard theme.color(for: rule.scope) != nil else { continue }

            let scanRange = rule.isMultiline ? multilineRange : searchRange

            rule.regex.enumerateMatches(in: text, range: scanRange) { match, _, _ in
                guard let matchRange = match?.range else { return }

                let clipped = NSIntersectionRange(matchRange, repaintRange)
                guard clipped.length > 0 else { return }

                let isOverridden = highlightedRanges.contains { existing in
                    existing.priority > priority &&
                    NSIntersectionRange(existing.range, clipped).length > 0
                }

                if !isOverridden {
                    matches.append(HighlightMatch(
                        range: clipped, scope: rule.scope, priority: priority
                    ))
                    highlightedRanges.append((range: clipped, priority: priority))
                }
            }
        }

        let fingerprint = collectMultilineFingerprint(
            rules: rules, source: text, searchRange: fullRange
        )

        return HighlightMatchResult(
            matches: matches,
            repaintRange: repaintRange,
            multilineFingerprint: fingerprint
        )
    }

    /// Applies pre-computed matches to NSTextStorage. Must be called on main thread.
    /// Validates that ranges are still valid — text may have changed between
    /// computation and application.
    func applyMatches(
        _ result: HighlightMatchResult,
        to textStorage: NSTextStorage,
        font: NSFont
    ) {
        let currentLength = textStorage.length
        // Discard if text changed and repaintRange is now out of bounds
        guard result.repaintRange.location + result.repaintRange.length <= currentLength else {
            return
        }

        let undoManager = textStorage.layoutManagers.first?.firstTextView?.undoManager
        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }

        textStorage.beginEditing()
        textStorage.addAttributes([
            .foregroundColor: NSColor.textColor,
            .font: font
        ], range: result.repaintRange)

        for match in result.matches {
            guard match.range.location + match.range.length <= currentLength else { continue }
            guard let color = theme.color(for: match.scope) else { continue }
            textStorage.addAttribute(.foregroundColor, value: color, range: match.range)
        }

        textStorage.endEditing()
    }

    /// Async full highlight: computes on background queue, applies on main thread.
    func highlightAsync(
        textStorage: NSTextStorage,
        language: String,
        fileName: String? = nil,
        font: NSFont,
        generation: HighlightGeneration? = nil
    ) async {
        // Explicit copy — NSTextStorage.string returns a reference to the internal
        // NSMutableString which may mutate while background work is in progress.
        let text = String(textStorage.string)
        let textLength = (text as NSString).length
        guard textLength > 0 else { return }

        let fullRange = NSRange(location: 0, length: textLength)
        let gen = generation?.current ?? 0

        let result: HighlightMatchResult? = await withCheckedContinuation { continuation in
            highlightQueue.async {
                let r = self.computeMatches(
                    text: text,
                    language: language,
                    fileName: fileName,
                    repaintRange: fullRange,
                    searchRange: fullRange
                )
                continuation.resume(returning: r)
            }
        }

        // Check generation — if bumped, discard stale results
        if let generation, generation.current != gen { return }

        if let result {
            applyMatches(result, to: textStorage, font: font)
            multilineMatchCache[ObjectIdentifier(textStorage)] = result.multilineFingerprint
        } else {
            resetAttributes(
                textStorage: textStorage,
                range: fullRange,
                font: font
            )
        }
    }

    /// Async incremental highlight after an edit.
    func highlightEditedAsync(
        textStorage: NSTextStorage,
        editedRange: NSRange,
        language: String,
        fileName: String? = nil,
        font: NSFont,
        generation: HighlightGeneration? = nil
    ) async {
        let text = String(textStorage.string)
        let textLength = (text as NSString).length
        guard textLength > 0 else { return }

        let fullRange = NSRange(location: 0, length: textLength)
        let key = ObjectIdentifier(textStorage)
        let cachedFingerprint = multilineMatchCache[key]
        let gen = generation?.current ?? 0

        // Compute on background
        let bgResult: (HighlightMatchResult?, Bool) = await withCheckedContinuation { continuation in
            highlightQueue.async {
                let currentFingerprint = self.collectMultilineFingerprint(
                    rules: self.resolveGrammar(language: language, fileName: fileName)?.1 ?? [],
                    source: text,
                    searchRange: fullRange
                )

                let needsFullRepaint = (cachedFingerprint != currentFingerprint)

                let repaintRange: NSRange
                let searchRange: NSRange
                if needsFullRepaint {
                    repaintRange = fullRange
                    searchRange = fullRange
                } else {
                    let expanded = self.expandToContext(
                        editedRange, in: text as NSString, totalLength: textLength
                    )
                    repaintRange = expanded
                    searchRange = expanded
                }

                let result = self.computeMatches(
                    text: text,
                    language: language,
                    fileName: fileName,
                    repaintRange: repaintRange,
                    searchRange: searchRange
                )

                continuation.resume(returning: (result, needsFullRepaint))
            }
        }

        if let generation, generation.current != gen { return }

        let (result, _) = bgResult
        if let result {
            applyMatches(result, to: textStorage, font: font)
            multilineMatchCache[key] = result.multilineFingerprint
        } else {
            resetAttributes(textStorage: textStorage, range: fullRange, font: font)
        }
    }

    /// Async viewport-based highlight.
    func highlightVisibleRangeAsync(
        textStorage: NSTextStorage,
        visibleCharRange: NSRange,
        language: String,
        fileName: String? = nil,
        font: NSFont,
        generation: HighlightGeneration? = nil
    ) async {
        let text = String(textStorage.string)
        let textLength = (text as NSString).length
        guard textLength > 0 else { return }

        let key = ObjectIdentifier(textStorage)
        let gen = generation?.current ?? 0

        let result: HighlightMatchResult? = await withCheckedContinuation { continuation in
            highlightQueue.async {
                let source = text as NSString
                let expanded = self.expandToContext(
                    visibleCharRange, in: source,
                    totalLength: textLength, lines: self.viewportContextLines
                )

                let r = self.computeMatches(
                    text: text,
                    language: language,
                    fileName: fileName,
                    repaintRange: expanded,
                    searchRange: expanded
                )
                continuation.resume(returning: r)
            }
        }

        if let generation, generation.current != gen { return }

        if let result {
            applyMatches(result, to: textStorage, font: font)
            if multilineMatchCache[key] == nil {
                multilineMatchCache[key] = result.multilineFingerprint
            }
        } else {
            resetAttributes(
                textStorage: textStorage,
                range: visibleCharRange,
                font: font
            )
        }
    }
}
