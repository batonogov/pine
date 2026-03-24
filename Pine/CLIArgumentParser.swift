//
//  CLIArgumentParser.swift
//  Pine
//
//  Parses command-line arguments for the `pine` CLI tool.
//  Pure logic — no side effects, fully testable.
//

import Foundation

enum CLIArgumentParser {
    /// Possible outcomes of parsing CLI arguments.
    enum Result: Equatable {
        case showHelp
        case showVersion
        case openDirectory(URL)
        case openFile(URL, line: Int?)
    }

    /// Help text displayed for `pine --help` or `pine` with no arguments.
    static let helpText = """
        USAGE: pine [file|directory] [options]

        Open files and folders in Pine from the terminal.

        ARGUMENTS:
          <path>              File or directory to open (default: current directory)
          <path>:<line>       Open file at specific line number
          <path>:<line>:<col> Open file at specific line and column

        OPTIONS:
          -h, --help          Show this help message
          -v, --version       Show Pine version

        EXAMPLES:
          pine .              Open current directory
          pine ~/projects     Open a directory
          pine file.swift     Open a file
          pine file.swift:42  Open file at line 42
        """

    /// Extracts an optional line number from a path string with `:line` or `:line:col` suffix.
    /// Returns the cleaned path and line number (1-based, or nil if absent/invalid).
    static func extractLineNumber(from argument: String) -> (path: String, line: Int?) {
        // Try matching path:line:col or path:line
        // Be careful with paths that might contain colons (rare on macOS, but possible)
        guard let lastColonRange = argument.range(of: ":", options: .backwards) else {
            return (argument, nil)
        }

        let afterLastColon = String(argument[lastColonRange.upperBound...])

        // Check if the part after last colon is a valid positive integer
        if let number = Int(afterLastColon), number >= 1 {
            let beforeLastColon = String(argument[..<lastColonRange.lowerBound])

            // Check if there's another colon (path:line:col format)
            if let secondLastColonRange = beforeLastColon.range(of: ":", options: .backwards) {
                let afterSecondColon = String(beforeLastColon[secondLastColonRange.upperBound...])
                if let lineNumber = Int(afterSecondColon), lineNumber >= 1 {
                    // path:line:col — return line number, ignore column
                    let path = String(beforeLastColon[..<secondLastColonRange.lowerBound])
                    return (path, lineNumber)
                }
            }

            // path:line format
            return (beforeLastColon, number)
        }

        return (argument, nil)
    }

    /// Parses command-line arguments into a Result.
    /// First element of `arguments` is expected to be the program name.
    static func parse(_ arguments: [String]) -> Result {
        // No arguments beyond program name -> help
        guard arguments.count > 1 else {
            return .showHelp
        }

        let arg = arguments[1]

        // Flags
        switch arg {
        case "-h", "--help":
            return .showHelp
        case "-v", "--version":
            return .showVersion
        default:
            break
        }

        // Expand tilde
        let expanded: String
        if arg.hasPrefix("~") {
            expanded = NSString(string: arg).expandingTildeInPath
        } else {
            expanded = arg
        }

        // Extract optional line number before resolving path
        let (pathString, line) = extractLineNumber(from: expanded)

        let url = URL(fileURLWithPath: pathString)

        // Determine if it's a directory or file
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue {
                return .openDirectory(url)
            } else {
                return .openFile(url, line: line)
            }
        }

        // Path doesn't exist — check if it's a file path (has extension) or directory
        if url.pathExtension.isEmpty {
            return .openDirectory(url)
        } else {
            return .openFile(url, line: line)
        }
    }

    /// Generates the `open` command arguments for a given parse result.
    /// Returns nil for help/version (those are handled by printing text).
    static func openCommand(for result: Result) -> [String]? {
        switch result {
        case .showHelp, .showVersion:
            return nil
        case .openDirectory(let url):
            return ["open", "-a", "Pine", url.path]
        case .openFile(let url, let line):
            if let line {
                return ["open", "-a", "Pine", "--args", "--line", "\(line)", url.path]
            }
            return ["open", "-a", "Pine", url.path]
        }
    }
}
