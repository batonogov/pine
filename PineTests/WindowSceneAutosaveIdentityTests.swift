//
//  WindowSceneAutosaveIdentityTests.swift
//  PineTests
//

import Testing

@testable import Pine

/// #1543 (second defect): AppKit builds `NSSplitView` autosave keys out of
/// `_typeName` of the SwiftUI scene's content type. A `private` (or otherwise
/// file-scoped) type has no stable mangled name — the runtime prints
/// `(unknown context at $<address>)`, and the address moves with ASLR — so the
/// key was different on every launch. Two consequences on Fedor's machine:
/// the sidebar width never survived a relaunch, and
/// `io.github.batonogov.pine` had accumulated 746 dead
/// `NSSplitView Subview Frames …` keys across 707 distinct launches.
@Suite("Window Scene Autosave Identity")
struct WindowSceneAutosaveIdentityTests {
    @Test("the project scene's content type has a launch-stable name")
    func projectSceneTypeNameIsStable() {
        #expect(_typeName(ProjectWindowView.self) == "Pine.ProjectWindowView")
    }

    /// The autosave key embeds the scene content type inside the generic
    /// `Optional<…>` `WindowGroup(for:)` wraps it in, which is the exact
    /// substring that carried the address in the leaked keys. Asserting the
    /// wrapped form too catches a regression that leaves the type itself
    /// nameable but moves it under a file-scoped parent.
    @Test("the wrapped scene type name matches the autosave key shape")
    func wrappedSceneTypeNameIsStable() {
        #expect(
            _typeName(ProjectWindowView?.self)
                == "Swift.Optional<Pine.ProjectWindowView>"
        )
    }

    /// Proves the assertion above can fail: the exact mangling that caused the
    /// leak is still detectable, so this suite is not asserting a tautology.
    @Test("a file-scoped type still mangles to an address-bearing name")
    func fileScopedTypeNameCarriesLaunchVaryingContext() {
        let name = _typeName(FileScopedControlView.self)
        #expect(name.contains("unknown context at"))
        #expect(name != "PineTests.FileScopedControlView")
    }
}

private struct FileScopedControlView {}
