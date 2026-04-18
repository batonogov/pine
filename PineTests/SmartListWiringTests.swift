//
//  SmartListWiringTests.swift
//  PineTests
//
//  Tests for GutterTextView.insertNewline smart list continuation wiring (issue #843).
//

import Testing
import AppKit
@testable import Pine

@Suite("Smart List Continuation Wiring")
@MainActor
struct SmartListWiringTests {

    private func makeTextView(text: String = "") -> GutterTextView {
        let textStorage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        )
        layoutManager.addTextContainer(textContainer)
        let textView = GutterTextView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 500),
            textContainer: textContainer
        )
        textView.smartListContinuationEnabled = true
        return textView
    }

    // MARK: - Bullet continuation

    @Test("Pressing Enter after '- hello' inserts '\\n- '")
    func continuesDashBullet() {
        let tv = makeTextView(text: "- hello")
        tv.setSelectedRange(NSRange(location: 7, length: 0))
        tv.insertNewline(nil)
        #expect(tv.string == "- hello\n- ")
    }

    @Test("Pressing Enter after '* item' inserts '\\n* '")
    func continuesAsteriskBullet() {
        let tv = makeTextView(text: "* item")
        tv.setSelectedRange(NSRange(location: 6, length: 0))
        tv.insertNewline(nil)
        #expect(tv.string == "* item\n* ")
    }

    @Test("Pressing Enter after '+ stuff' inserts '\\n+ '")
    func continuesPlusBullet() {
        let tv = makeTextView(text: "+ stuff")
        tv.setSelectedRange(NSRange(location: 7, length: 0))
        tv.insertNewline(nil)
        #expect(tv.string == "+ stuff\n+ ")
    }

    // MARK: - Ordered list continuation

    @Test("Pressing Enter after '1. first' inserts '\\n2. '")
    func continuesOrderedList() {
        let tv = makeTextView(text: "1. first")
        tv.setSelectedRange(NSRange(location: 8, length: 0))
        tv.insertNewline(nil)
        #expect(tv.string == "1. first\n2. ")
    }

    @Test("Pressing Enter after '9) nine' inserts '\\n10) '")
    func continuesOrderedParen() {
        let tv = makeTextView(text: "9) nine")
        tv.setSelectedRange(NSRange(location: 7, length: 0))
        tv.insertNewline(nil)
        #expect(tv.string == "9) nine\n10) ")
    }

    // MARK: - Indentation preservation

    @Test("Preserves indentation in continued list")
    func preservesIndent() {
        let tv = makeTextView(text: "    - nested")
        tv.setSelectedRange(NSRange(location: 12, length: 0))
        tv.insertNewline(nil)
        #expect(tv.string == "    - nested\n    - ")
    }

    // MARK: - Task list continuation

    @Test("Task list: checked task resets checkbox to unchecked")
    func taskListResetsCheckbox() {
        let tv = makeTextView(text: "- [x] done")
        tv.setSelectedRange(NSRange(location: 10, length: 0))
        tv.insertNewline(nil)
        #expect(tv.string == "- [x] done\n- [ ] ")
    }

    @Test("Task list: unchecked task continues unchecked")
    func taskListContinuesUnchecked() {
        let tv = makeTextView(text: "- [ ] todo")
        tv.setSelectedRange(NSRange(location: 10, length: 0))
        tv.insertNewline(nil)
        #expect(tv.string == "- [ ] todo\n- [ ] ")
    }

    // MARK: - Blockquote

    @Test("Blockquote list continuation preserves prefix")
    func blockquoteContinuation() {
        let tv = makeTextView(text: "> - quoted")
        tv.setSelectedRange(NSRange(location: 10, length: 0))
        tv.insertNewline(nil)
        #expect(tv.string == "> - quoted\n> - ")
    }

    // MARK: - Termination

    @Test("Empty bullet terminates list — replaces line with empty")
    func terminatesOnEmptyBullet() {
        let tv = makeTextView(text: "- hello\n- ")
        tv.setSelectedRange(NSRange(location: 10, length: 0))
        tv.insertNewline(nil)
        #expect(tv.string == "- hello\n\n")
    }

    @Test("Empty ordered item terminates list")
    func terminatesOnEmptyOrdered() {
        let tv = makeTextView(text: "1. first\n2. ")
        tv.setSelectedRange(NSRange(location: 12, length: 0))
        tv.insertNewline(nil)
        #expect(tv.string == "1. first\n\n")
    }

    @Test("Empty task list terminates")
    func terminatesOnEmptyTask() {
        let tv = makeTextView(text: "- [ ] ")
        tv.setSelectedRange(NSRange(location: 6, length: 0))
        tv.insertNewline(nil)
        #expect(tv.string == "\n")
    }

    // MARK: - Non-list falls through to auto-indent

    @Test("Non-list line falls through to normal auto-indent")
    func fallsThroughForPlainText() {
        let tv = makeTextView(text: "    hello")
        tv.setSelectedRange(NSRange(location: 9, length: 0))
        tv.insertNewline(nil)
        // Should produce normal auto-indent behavior
        #expect(tv.string.contains("\n    "), "Should preserve indent via auto-indent fallback")
    }

    @Test("Auto-indent after brace still works when smart list enabled")
    func autoIndentAfterBraceStillWorks() {
        let tv = makeTextView(text: "func test() {")
        tv.setSelectedRange(NSRange(location: 13, length: 0))
        tv.insertNewline(nil)
        #expect(tv.string.contains("\n    "), "Should add indent after {")
    }

    // MARK: - Feature flag

    @Test("Smart list disabled: bullet line falls through to auto-indent")
    func disabledFallsThrough() {
        let tv = makeTextView(text: "- hello")
        tv.smartListContinuationEnabled = false
        tv.setSelectedRange(NSRange(location: 7, length: 0))
        tv.insertNewline(nil)
        // Should NOT insert "- " prefix; just regular newline
        #expect(!tv.string.hasSuffix("- "), "Should not continue list when feature is off")
    }

    // MARK: - Cursor not at end of line

    @Test("Cursor in middle of list line falls through to auto-indent")
    func cursorMiddleFallsThrough() {
        let tv = makeTextView(text: "- hello world")
        // Cursor after "he" — not at end of line
        tv.setSelectedRange(NSRange(location: 4, length: 0))
        tv.insertNewline(nil)
        // Should use auto-indent, not smart list (cursor not at end)
        #expect(tv.string == "- he\nllo world")
        #expect(!tv.string.contains("\n- "))
    }

    // MARK: - Multi-line context

    @Test("Smart list works with multiple lines, cursor on last")
    func multiLineContinuation() {
        let tv = makeTextView(text: "# Title\n- first\n- second")
        tv.setSelectedRange(NSRange(location: 24, length: 0))
        tv.insertNewline(nil)
        #expect(tv.string == "# Title\n- first\n- second\n- ")
    }

    // MARK: - Edge cases

    @Test("Emoji in list body continues correctly (UTF-16 safety)")
    func emojiInListBody() {
        let text = "- hello 😀"
        let tv = makeTextView(text: text)
        // NSString length for proper UTF-16 offset
        tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        tv.insertNewline(nil)
        #expect(tv.string == "- hello 😀\n- ")
    }

    @Test("Tab-indented list continues with tab indent")
    func tabIndentedList() {
        let tv = makeTextView(text: "\t- tabbed")
        tv.setSelectedRange(NSRange(location: 9, length: 0))
        tv.insertNewline(nil)
        #expect(tv.string == "\t- tabbed\n\t- ")
    }

    @Test("Spaces after marker with content continues list")
    func spacesAfterMarker() {
        let tv = makeTextView(text: "-   spaced")
        tv.setSelectedRange(NSRange(location: 10, length: 0))
        tv.insertNewline(nil)
        #expect(tv.string == "-   spaced\n- ")
    }

    @Test("Multiple emoji characters in list (UTF-16 multi-unit)")
    func multipleEmoji() {
        let text = "- 🇯🇵🏳️‍🌈 flags"
        let tv = makeTextView(text: text)
        tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        tv.insertNewline(nil)
        #expect(tv.string == "- 🇯🇵🏳️‍🌈 flags\n- ")
    }

    @Test("Empty bullet termination with emoji prefix line")
    func emojiTermination() {
        let text = "- 😀\n- "
        let tv = makeTextView(text: text)
        tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        tv.insertNewline(nil)
        #expect(tv.string == "- 😀\n\n")
    }

    // MARK: - EditorSettings integration

    @Test("EditorSettings.smartListContinuation defaults to true")
    func settingsDefault() {
        let suiteName = "SmartListWiringTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.removePersistentDomain(forName: suiteName)
        let settings = EditorSettings(defaults: defaults)
        #expect(settings.smartListContinuation == true)
    }

    @Test("EditorSettings.smartListContinuation persists to UserDefaults")
    func settingsPersistence() {
        let suiteName = "SmartListWiringTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.removePersistentDomain(forName: suiteName)
        let settings = EditorSettings(defaults: defaults)
        settings.smartListContinuation = false
        #expect(defaults.bool(forKey: EditorSettings.Keys.smartListContinuation) == false)
        let reloaded = EditorSettings(defaults: defaults)
        #expect(reloaded.smartListContinuation == false)
    }
}
