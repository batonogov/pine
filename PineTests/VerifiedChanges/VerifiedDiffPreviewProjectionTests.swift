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
    @Test("LF, CRLF, and missing final newline remain distinct")
    func exactLineTerminatorsArePreserved() {
        #expect(sanitizedLine("visible\n") == VerifiedDiffSanitizedLine(
            text: "visible",
            lineEnding: .lf
        ))
        #expect(sanitizedLine("visible\r\n") == VerifiedDiffSanitizedLine(
            text: "visible",
            lineEnding: .crlf
        ))
        #expect(sanitizedLine("visible") == VerifiedDiffSanitizedLine(
            text: "visible",
            lineEnding: .noFinalNewline
        ))
        #expect(sanitizedLine("visible\r\r\n") == VerifiedDiffSanitizedLine(
            text: "visible\\u{D}",
            lineEnding: .crlf
        ))
        #expect(sanitizedLine("\n\n") == VerifiedDiffSanitizedLine(
            text: "\\u{A}",
            lineEnding: .lf
        ))
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

    @Test("Literal escape syntax cannot collide with unsafe scalars")
    func escapingIsInjectiveForLinesAndPaths() {
        let literalLine = sanitizedLine("\\u{202E}\n")
        let scalarLine = sanitizedLine("\u{202E}\n")
        #expect(literalLine?.text == "\\u{5C}u{202E}")
        #expect(scalarLine?.text == "\\u{202E}")
        #expect(literalLine != scalarLine)

        let literalPath = "Sources/\\u{202E}.swift"
        let scalarPath = "Sources/\u{202E}.swift"
        let escapedLiteralPath = VerifiedDiffDisplaySanitizer
            .escapeUnsafeScalars(in: literalPath)
        let escapedScalarPath = VerifiedDiffDisplaySanitizer
            .escapeUnsafeScalars(in: scalarPath)
        #expect(escapedLiteralPath == "Sources/\\u{5C}u{202E}.swift")
        #expect(escapedScalarPath == "Sources/\\u{202E}.swift")
        #expect(escapedLiteralPath != escapedScalarPath)
    }

    private func sanitizedLine(
        _ value: String
    ) -> VerifiedDiffSanitizedLine? {
        VerifiedDiffDisplaySanitizer.sanitizedLine(Data(value.utf8))
    }
}
