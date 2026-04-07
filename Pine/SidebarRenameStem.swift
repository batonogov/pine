//
//  SidebarRenameStem.swift
//  Pine
//
//  Computes the "stem" portion of a filename — the part before the file
//  extension — for Finder-style inline rename selection. When the user
//  triggers rename on `foo.swift`, only `foo` should be selected so they
//  can type a new stem without re-typing the extension.
//
//  Rules:
//  - Files with an extension: select characters up to (but not including)
//    the last dot. `foo.swift` → (0, 3), `archive.tar.gz` → (0, 11).
//  - Hidden files starting with a dot and no further extension
//    (`.gitignore`, `.env`): select the entire name.
//  - Files with no extension (`Makefile`, `README`): select the entire name.
//  - Directories: callers should pass `isDirectory: true` to get the full
//    range regardless of dots in the folder name (e.g. `my.app`).
//  - Empty string: zero-length range at offset 0.
//

import Foundation

enum SidebarRenameStem {
    /// Returns the NSRange (UTF-16 units, matching NSTextView's selectedRange)
    /// that should be selected in the rename text field for the given name.
    ///
    /// - Parameters:
    ///   - name: The filename or folder name to compute the stem for.
    ///   - isDirectory: When true, returns the full range (folders have no extension).
    static func stemRange(for name: String, isDirectory: Bool = false) -> NSRange {
        let fullRange = NSRange(location: 0, length: (name as NSString).length)

        if isDirectory {
            return fullRange
        }

        if name.isEmpty {
            return NSRange(location: 0, length: 0)
        }

        // Hidden file with no further extension: ".gitignore", ".env"
        // The leading dot is part of the name, not an extension separator.
        // We detect this by checking if the only dot is the leading one.
        let nsName = name as NSString
        let lastDot = nsName.range(of: ".", options: .backwards)

        // No dot at all → no extension → select full name (Makefile, README)
        if lastDot.location == NSNotFound {
            return fullRange
        }

        // Leading dot is the only dot → hidden file with no extension → select all
        if lastDot.location == 0 {
            return fullRange
        }

        // Trailing dot ("foo.") → degenerate; select up to the dot
        // Stem = characters before the last dot
        return NSRange(location: 0, length: lastDot.location)
    }

    /// Validates a proposed filename for inline rename.
    ///
    /// - Returns: `nil` when the name is acceptable, or a localized error string.
    static func validationError(
        for proposedName: String,
        oldURL: URL,
        existingNames: Set<String>
    ) -> String? {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return Strings.renameErrorEmpty
        }

        // POSIX path separator and macOS HFS-style colon are forbidden in filenames.
        if trimmed.contains("/") || trimmed.contains(":") {
            return Strings.renameErrorInvalidCharacters
        }

        // Same name as before — caller should treat as no-op, not an error.
        if trimmed == oldURL.lastPathComponent {
            return nil
        }

        if existingNames.contains(trimmed) {
            return Strings.renameErrorDuplicate(trimmed)
        }

        return nil
    }
}
