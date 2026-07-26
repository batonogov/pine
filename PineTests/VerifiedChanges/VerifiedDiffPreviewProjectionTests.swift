//
//  VerifiedDiffPreviewProjectionTests.swift
//  PineTests
//
//  Fail-closed display sanitization for prepared inverse previews.
//

import Foundation
import Testing

@testable import Pine

@Suite("Prepared Inverse Preview Projection")
struct VerifiedDiffPreviewProjectionTests {
    @Test("A single CRLF terminator is removed without trimming content")
    func exactLineTerminatorRemoval() {
        #expect(sanitizedLine("visible\r\n") == "visible")
        #expect(sanitizedLine("visible\r\r\n") == "visible\\u{D}")
        #expect(sanitizedLine("visible") == "visible")
        #expect(sanitizedLine("\n\n") == "\\u{A}")
    }

    @Test("Invalid UTF-8 fails closed instead of rendering an empty line")
    func invalidUTF8FailsClosed() {
        #expect(
            VerifiedDiffDisplaySanitizer.sanitizedLine(
                Data([0xFF, 0x0A])
            ) == nil
        )
        #expect(
            VerifiedDiffDisplaySanitizer.sanitizedLine(
                Data([0xC0, 0xAF, 0x0A])
            ) == nil
        )
    }

    @Test("Every control, format, and visual separator category is escaped")
    func unsafeScalarCategoriesAreEscaped() {
        let unsafe: [Unicode.Scalar] = [
            "\u{0000}", // C0 control
            "\t",       // layout-spoofing C0 control
            "\u{0085}", // C1 control
            "\u{00AD}", // format
            "\u{200D}", // zero-width format
            "\u{202E}", // bidi override format
            "\u{2066}", // bidi isolate format
            "\u{FEFF}", // BOM / zero-width no-break format
            "\u{2028}", // line separator
            "\u{2029}"  // paragraph separator
        ]

        for scalar in unsafe {
            let escaped = VerifiedDiffDisplaySanitizer
                .escapeUnsafeScalars(in: String(scalar))
            let hexadecimal = String(
                scalar.value,
                radix: 16,
                uppercase: true
            )
            #expect(
                escaped == "\\u{\(hexadecimal)}"
            )
        }
    }

    @Test("Visible Unicode remains intact around escaped spoofing scalars")
    func visibleUnicodeRemainsIntact() {
        let value = "Sources/é.swift → α\u{202E}evil\u{2069}"

        #expect(
            VerifiedDiffDisplaySanitizer.escapeUnsafeScalars(in: value)
                == "Sources/é.swift → α\\u{202E}evil\\u{2069}"
        )
    }

    private func sanitizedLine(_ value: String) -> String? {
        VerifiedDiffDisplaySanitizer.sanitizedLine(Data(value.utf8))
    }
}
