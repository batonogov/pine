//
//  SmartListContinuationTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("SmartListContinuation.parse")
@MainActor
struct SmartListContinuationParseTests {

    @Test("Parses simple dash bullet")
    func simpleDash() {
        let item = SmartListContinuation.parse(line: "- hello")
        #expect(item?.indent == "")
        #expect(item?.blockquote == "")
        #expect(item?.marker == .unordered("-"))
        #expect(item?.checkbox == "")
        #expect(item?.body == "hello")
    }

    @Test("Parses asterisk and plus bullets")
    func otherUnorderedMarkers() {
        #expect(SmartListContinuation.parse(line: "* x")?.marker == .unordered("*"))
        #expect(SmartListContinuation.parse(line: "+ x")?.marker == .unordered("+"))
    }

    @Test("Parses ordered list with period")
    func orderedPeriod() {
        let item = SmartListContinuation.parse(line: "1. first")
        #expect(item?.marker == .ordered(1, "."))
        #expect(item?.body == "first")
    }

    @Test("Parses ordered list with parenthesis")
    func orderedParen() {
        let item = SmartListContinuation.parse(line: "42) item")
        #expect(item?.marker == .ordered(42, ")"))
        #expect(item?.body == "item")
    }

    @Test("Parses indented bullet")
    func indentedBullet() {
        let item = SmartListContinuation.parse(line: "    - nested")
        #expect(item?.indent == "    ")
        #expect(item?.marker == .unordered("-"))
    }

    @Test("Parses tab-indented bullet")
    func tabIndentedBullet() {
        let item = SmartListContinuation.parse(line: "\t- nested")
        #expect(item?.indent == "\t")
    }

    @Test("Parses blockquote prefix")
    func blockquote() {
        let item = SmartListContinuation.parse(line: "> - quoted")
        #expect(item?.blockquote == "> ")
        #expect(item?.marker == .unordered("-"))
        #expect(item?.body == "quoted")
    }

    @Test("Parses nested blockquote prefix")
    func nestedBlockquote() {
        let item = SmartListContinuation.parse(line: "> > - deep")
        #expect(item?.blockquote == "> > ")
        #expect(item?.body == "deep")
    }

    @Test("Parses unchecked task list")
    func uncheckedTask() {
        let item = SmartListContinuation.parse(line: "- [ ] todo")
        #expect(item?.checkbox == "[ ] ")
        #expect(item?.body == "todo")
    }

    @Test("Parses checked task list (lowercase)")
    func checkedTaskLower() {
        let item = SmartListContinuation.parse(line: "- [x] done")
        #expect(item?.checkbox == "[x] ")
    }

    @Test("Parses checked task list (uppercase)")
    func checkedTaskUpper() {
        let item = SmartListContinuation.parse(line: "* [X] done")
        #expect(item?.checkbox == "[X] ")
        #expect(item?.marker == .unordered("*"))
    }

    @Test("Returns nil for plain text")
    func plainText() {
        #expect(SmartListContinuation.parse(line: "not a list") == nil)
    }

    @Test("Returns nil for empty line")
    func emptyLine() {
        #expect(SmartListContinuation.parse(line: "") == nil)
    }

    @Test("Returns nil for bare dash with no space")
    func bareDash() {
        #expect(SmartListContinuation.parse(line: "-") == nil)
    }

    @Test("Returns nil for marker with no body and no trailing space")
    func markerOnly() {
        #expect(SmartListContinuation.parse(line: "1.") == nil)
    }

    @Test("Accepts marker with trailing space and empty body")
    func markerWithEmptyBody() {
        let item = SmartListContinuation.parse(line: "- ")
        #expect(item != nil)
        #expect(item?.body == "")
    }

    @Test("Returns nil for number without delimiter")
    func numberOnly() {
        #expect(SmartListContinuation.parse(line: "1 hello") == nil)
    }

    @Test("Handles multi-digit ordered markers")
    func multiDigitOrdered() {
        let item = SmartListContinuation.parse(line: "100. hundred")
        #expect(item?.marker == .ordered(100, "."))
    }
}

@Suite("SmartListContinuation.handleReturn")
@MainActor
struct SmartListContinuationReturnTests {

    @Test("Continues an unordered list")
    func continuesUnordered() {
        let result = SmartListContinuation.handleReturn(currentLine: "- first")
        #expect(result == .continue(continuation: "- "))
    }

    @Test("Continues an ordered list, incrementing the counter")
    func continuesOrderedIncrement() {
        let result = SmartListContinuation.handleReturn(currentLine: "3. third")
        #expect(result == .continue(continuation: "4. "))
    }

    @Test("Continues ordered parenthesis style")
    func continuesOrderedParen() {
        let result = SmartListContinuation.handleReturn(currentLine: "9) nine")
        #expect(result == .continue(continuation: "10) "))
    }

    @Test("Preserves indentation when continuing")
    func preservesIndent() {
        let result = SmartListContinuation.handleReturn(currentLine: "    - nested")
        #expect(result == .continue(continuation: "    - "))
    }

    @Test("Preserves blockquote prefix when continuing")
    func preservesBlockquote() {
        let result = SmartListContinuation.handleReturn(currentLine: "> - quoted")
        #expect(result == .continue(continuation: "> - "))
    }

    @Test("Terminates when body is empty")
    func terminatesOnEmptyBody() {
        let result = SmartListContinuation.handleReturn(currentLine: "- ")
        #expect(result == .terminate(replacement: ""))
    }

    @Test("Terminates when body is only whitespace")
    func terminatesOnWhitespaceBody() {
        let result = SmartListContinuation.handleReturn(currentLine: "-    ")
        #expect(result == .terminate(replacement: ""))
    }

    @Test("Terminates empty ordered item")
    func terminatesEmptyOrdered() {
        let result = SmartListContinuation.handleReturn(currentLine: "1. ")
        #expect(result == .terminate(replacement: ""))
    }

    @Test("Terminates empty task-list item")
    func terminatesEmptyTask() {
        let result = SmartListContinuation.handleReturn(currentLine: "- [ ] ")
        #expect(result == .terminate(replacement: ""))
    }

    @Test("Continues a checked task: new task starts unchecked")
    func taskResetsCheckbox() {
        let result = SmartListContinuation.handleReturn(currentLine: "- [x] done")
        #expect(result == .continue(continuation: "- [ ] "))
    }

    @Test("Continues an unchecked task")
    func taskContinuesUnchecked() {
        let result = SmartListContinuation.handleReturn(currentLine: "- [ ] todo")
        #expect(result == .continue(continuation: "- [ ] "))
    }

    @Test("Returns nil for non-list plain text")
    func nilForPlain() {
        #expect(SmartListContinuation.handleReturn(currentLine: "hello world") == nil)
    }

    @Test("Returns nil for empty line")
    func nilForEmpty() {
        #expect(SmartListContinuation.handleReturn(currentLine: "") == nil)
    }

    @Test("Handles ordered list body that starts with digits")
    func orderedBodyWithDigits() {
        let result = SmartListContinuation.handleReturn(currentLine: "1. 2 apples")
        #expect(result == .continue(continuation: "2. "))
    }

    @Test("Handles deep indentation (tabs + spaces)")
    func deepIndent() {
        let result = SmartListContinuation.handleReturn(currentLine: "\t    - mix")
        #expect(result == .continue(continuation: "\t    - "))
    }

    @Test("Handles blockquote empty item: terminates (but preserves quote prefix is not the point — the list dies)")
    func blockquoteEmptyTerminates() {
        let result = SmartListContinuation.handleReturn(currentLine: "> - ")
        #expect(result == .terminate(replacement: ""))
    }

    @Test("Idempotence check: parsing the continuation line produces a parseable empty item")
    func continuationIsParseable() {
        guard let outcome = SmartListContinuation.handleReturn(currentLine: "- a"),
              case .continue(let cont) = outcome else {
            Issue.record("expected continue")
            return
        }
        // The continuation should itself be a parseable list line.
        let parsed = SmartListContinuation.parse(line: cont)
        #expect(parsed != nil)
        #expect(parsed?.body == "")
    }
}
