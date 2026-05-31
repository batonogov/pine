//
//  GitParser.swift
//  Pine
//
//  Pure, stateless git output parsers. No side effects, no Foundation Process.
//

import Foundation

/// Namespace for pure git output parsing functions.
/// Marked `nonisolated` to opt out of `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
nonisolated enum GitParser {

    // MARK: - Path Unquoting

    /// Strips C-style quoting that git applies to paths containing spaces,
    /// non-ASCII characters, or special characters.
    /// `"examples copy/"` -> `examples copy/`
    /// `"\320\241\320\275\320\270\320\274\320\276\320\272.png"` -> `Снимок.png`
    static func unquoteGitPath(_ path: String) -> String {
        guard path.hasPrefix("\"") && path.hasSuffix("\"") && path.count >= 2 else {
            return path
        }
        // Strip surrounding quotes
        let inner = path.dropFirst().dropLast()
        var bytes: [UInt8] = []
        var i = inner.startIndex
        while i < inner.endIndex {
            if inner[i] == "\\" {
                let next = inner.index(after: i)
                guard next < inner.endIndex else {
                    bytes.append(UInt8(ascii: "\\"))
                    break
                }
                switch inner[next] {
                case "\\":
                    bytes.append(UInt8(ascii: "\\"))
                    i = inner.index(after: next)
                case "\"":
                    bytes.append(UInt8(ascii: "\""))
                    i = inner.index(after: next)
                case "n":
                    bytes.append(UInt8(ascii: "\n"))
                    i = inner.index(after: next)
                case "t":
                    bytes.append(UInt8(ascii: "\t"))
                    i = inner.index(after: next)
                case "a":
                    bytes.append(0x07)
                    i = inner.index(after: next)
                case "b":
                    bytes.append(0x08)
                    i = inner.index(after: next)
                case "f":
                    bytes.append(0x0C)
                    i = inner.index(after: next)
                case "r":
                    bytes.append(UInt8(ascii: "\r"))
                    i = inner.index(after: next)
                case "v":
                    bytes.append(0x0B)
                    i = inner.index(after: next)
                case "0"..."3":
                    // Octal escape: 1-3 digits
                    var octal = String(inner[next])
                    var end = inner.index(after: next)
                    for _ in 0..<2 {
                        guard end < inner.endIndex, inner[end] >= "0", inner[end] <= "7" else { break }
                        octal.append(inner[end])
                        end = inner.index(after: end)
                    }
                    if let value = UInt8(octal, radix: 8) {
                        bytes.append(value)
                    }
                    i = end
                default:
                    bytes.append(UInt8(ascii: "\\"))
                    i = next
                }
            } else {
                for byte in String(inner[i]).utf8 {
                    bytes.append(byte)
                }
                i = inner.index(after: i)
            }
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    // MARK: - Status Parsing

    /// Parses `git status --porcelain` output into a dictionary of file paths to statuses.
    static func parseStatusOutput(_ output: String) -> [String: GitFileStatus] {
        var statuses: [String: GitFileStatus] = [:]

        for line in output.components(separatedBy: "\n") {
            guard line.count >= 3 else { continue }
            // Skip ignored entries (!! prefix) from --ignored output
            guard !line.hasPrefix("!!") else { continue }
            let indexChar = line[line.startIndex]
            let workTreeChar = line[line.index(after: line.startIndex)]
            var path = String(line.dropFirst(3))

            // git status --porcelain C-quotes paths containing spaces,
            // non-ASCII, or special characters (e.g. "examples copy/"
            // or "\320\241\320\275\320\270\320\274\320\276\320\272.png").
            path = unquoteGitPath(path)

            // Handle renames: "R  old -> new"
            if path.contains(" -> ") {
                let parts = path.components(separatedBy: " -> ")
                if parts.count == 2 { path = parts[1] }
            }

            let status: GitFileStatus
            switch (indexChar, workTreeChar) {
            case ("?", "?"):
                status = .untracked
            case ("U", _), (_, "U"), ("A", "A"), ("D", "D"):
                status = .conflict
            case ("A", " "):
                status = .added
            case ("D", " "), (" ", "D"):
                status = .deleted
            case ("M", " "), ("R", " "):
                status = .staged
            case (" ", "M"):
                status = .modified
            case ("M", "M"):
                status = .mixed
            default:
                if indexChar != " " && indexChar != "?" {
                    status = workTreeChar != " " && workTreeChar != "?" ? .mixed : .staged
                } else {
                    status = .modified
                }
            }

            statuses[path] = status
        }

        return statuses
    }

    /// Parses ignored file paths from `git status --porcelain --ignored` output.
    static func parseIgnoredOutput(_ output: String) -> Set<String> {
        var paths: Set<String> = []
        for line in output.components(separatedBy: "\n") {
            guard line.hasPrefix("!! ") else { continue }
            var path = String(line.dropFirst(3))
            // Git C-quotes ignored paths containing spaces, non-ASCII, or special characters
            path = unquoteGitPath(path)
            // Remove trailing slash for directories to normalize
            if path.hasSuffix("/") { path = String(path.dropLast()) }
            paths.insert(path)
        }
        return paths
    }

    // MARK: - Blame Parser

    /// Parses `git blame --porcelain` output into an array of `GitBlameLine`.
    ///
    /// Porcelain format:
    /// ```
    /// <hash> <orig-line> <final-line> [<num-lines>]   <- first occurrence of commit
    /// author <name>
    /// author-time <unix-timestamp>
    /// summary <text>
    /// \t<content>
    ///
    /// <hash> <orig-line> <final-line>                  <- subsequent lines from same commit
    /// \t<content>
    /// ```
    static func parseBlame(_ output: String) -> [GitBlameLine] {
        guard !output.isEmpty else { return [] }

        var result: [GitBlameLine] = []
        let lines = output.components(separatedBy: "\n")

        // Cache: hash -> (author, authorTime, summary)
        var commitCache: [String: (author: String, authorTime: Date, summary: String)] = [:]

        var i = 0
        while i < lines.count {
            let line = lines[i]

            // Skip empty lines
            guard !line.isEmpty else {
                i += 1
                continue
            }

            // Commit header line: <40-char-hash> <orig> <final> [<count>]
            let parts = line.split(separator: " ", maxSplits: 4)
            guard parts.count >= 3,
                  parts[0].count == 40,
                  parts[0].allSatisfy({ $0.isHexDigit }),
                  let finalLine = Int(parts[2]) else {
                i += 1
                continue
            }

            let hash = String(parts[0])
            i += 1

            // If this is the first occurrence, read header fields
            var author = ""
            var authorTime = Date(timeIntervalSince1970: 0)
            var summary = ""
            var hasHeaders = false

            while i < lines.count {
                let headerLine = lines[i]
                if headerLine.hasPrefix("\t") {
                    // Content line - end of headers
                    break
                } else if headerLine.hasPrefix("author ") {
                    author = String(headerLine.dropFirst(7))
                    hasHeaders = true
                } else if headerLine.hasPrefix("author-time ") {
                    if let ts = TimeInterval(headerLine.dropFirst(12)) {
                        authorTime = Date(timeIntervalSince1970: ts)
                    }
                } else if headerLine.hasPrefix("summary ") {
                    summary = String(headerLine.dropFirst(8))
                }
                i += 1
            }

            // Skip the content line (starts with \t)
            if i < lines.count && lines[i].hasPrefix("\t") {
                i += 1
            }

            if hasHeaders {
                commitCache[hash] = (author, authorTime, summary)
            } else if let cached = commitCache[hash] {
                author = cached.author
                authorTime = cached.authorTime
                summary = cached.summary
            }

            result.append(GitBlameLine(
                hash: hash,
                author: author,
                authorTime: authorTime,
                summary: summary,
                finalLine: finalLine
            ))
        }

        return result
    }

    // MARK: - Diff Parser

    /// Parses `git diff --unified=0` output into an array of line diffs.
    static func parseDiff(_ diffOutput: String) -> [GitLineDiff] {
        var diffs: [GitLineDiff] = []
        let lines = diffOutput.components(separatedBy: "\n")

        var i = 0
        while i < lines.count {
            let line = lines[i]

            guard line.hasPrefix("@@") else {
                i += 1
                continue
            }

            // Parse @@ -old[,count] +new[,count] @@
            guard let newStart = parseHunkNewStart(line) else {
                i += 1
                continue
            }

            i += 1
            var newLine = newStart

            while i < lines.count && !lines[i].hasPrefix("@@") && !lines[i].hasPrefix("diff ") {
                let hl = lines[i]

                if hl.hasPrefix("-") || hl.hasPrefix("+") {
                    // Collect consecutive block of -/+ lines
                    var deletions = 0
                    var additions = 0
                    let blockNewLine = newLine

                    while i < lines.count && lines[i].hasPrefix("-") {
                        deletions += 1
                        i += 1
                    }
                    // Skip "\ No newline at end of file"
                    while i < lines.count && lines[i].hasPrefix("\\") { i += 1 }

                    while i < lines.count && lines[i].hasPrefix("+") {
                        additions += 1
                        i += 1
                    }
                    while i < lines.count && lines[i].hasPrefix("\\") { i += 1 }

                    let modifiedCount = min(deletions, additions)
                    let addedCount = additions - modifiedCount

                    for j in 0..<modifiedCount {
                        diffs.append(GitLineDiff(line: blockNewLine + j, kind: .modified))
                    }
                    for j in 0..<addedCount {
                        diffs.append(GitLineDiff(line: blockNewLine + modifiedCount + j, kind: .added))
                    }
                    if deletions > 0 && additions == 0 {
                        diffs.append(GitLineDiff(line: blockNewLine, kind: .deleted))
                    }

                    newLine = blockNewLine + additions
                } else if hl.hasPrefix("\\") {
                    i += 1
                } else {
                    // Context line
                    newLine += 1
                    i += 1
                }
            }
        }

        return diffs
    }

    /// Parses the new-file start line number from a diff hunk header.
    /// Format: `@@ -old[,count] +new[,count] @@`
    static func parseHunkNewStart(_ header: String) -> Int? {
        // Format: @@ -old[,count] +new[,count] @@
        guard let plusIndex = header.firstIndex(of: "+") else { return nil }
        let afterPlus = header[header.index(after: plusIndex)...]
        guard let endIndex = afterPlus.firstIndex(where: { $0 == "," || $0 == " " }) else { return nil }
        return Int(afterPlus[..<endIndex])
    }
}
