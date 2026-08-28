//
//  EditorTabAccessibilityValueTests.swift
//  PineTests
//
//  #1528 — an editor tab's unsaved state must be perceivable without the
//  visual dirty dot: the tab's accessibility value names the state, and the
//  overflow menu entry says it in words instead of a ● glyph.
//

import Testing

@testable import Pine

@Suite("Editor tab accessibility value (#1528)")
struct EditorTabAccessibilityValueTests {
    @Test("A clean tab keeps the pre-#1528 empty value")
    func cleanTabHasNoValue() {
        #expect(
            EditorTabAccessibilityValue.compose(
                isDirty: false,
                isTransientPreview: false
            ) == nil
        )
    }

    @Test("The value flips with the dirty flag")
    func dirtyTabAnnouncesUnsavedChanges() {
        #expect(
            EditorTabAccessibilityValue.compose(
                isDirty: true,
                isTransientPreview: false
            ) == Strings.a11yDirtyTab
        )
        #expect(
            EditorTabAccessibilityValue.compose(
                isDirty: false,
                isTransientPreview: false
            ) == nil
        )
    }

    @Test("A preview-only tab keeps the exact pre-#1528 value")
    func previewOnlyTabIsUnchanged() {
        // PineUITests/EditorTabNavigationTests asserts the value equals
        // "Preview" exactly — the composer must not grow that string.
        #expect(
            EditorTabAccessibilityValue.compose(
                isDirty: false,
                isTransientPreview: true
            ) == Strings.a11yTransientPreviewTab
        )
    }

    @Test("A dirty preview announces both states in a stable order")
    func dirtyPreviewAnnouncesBoth() {
        #expect(
            EditorTabAccessibilityValue.compose(
                isDirty: true,
                isTransientPreview: true
            )
            == Strings.a11yTransientPreviewTab + ", " + Strings.a11yDirtyTab
        )
    }

    @Test("The dirty string is localized, non-empty, and menu-ready")
    func dirtyStringIsPresentable() {
        #expect(!Strings.a11yDirtyTab.isEmpty)
        #expect(!Strings.a11yDirtyTab.contains("\u{25CF}"))
    }

    @Test("The overflow menu entry says the state in words, not a glyph")
    func overflowMenuTitleNamesTheState() {
        #expect(
            EditorTabOverflowTitle.make(fileName: "main.swift", isDirty: false)
                == "main.swift"
        )
        #expect(
            EditorTabOverflowTitle.make(fileName: "main.swift", isDirty: true)
                == "main.swift — " + Strings.a11yDirtyTab
        )
        #expect(
            !EditorTabOverflowTitle.make(
                fileName: "main.swift", isDirty: true
            ).contains("\u{25CF}")
        )
    }
}
