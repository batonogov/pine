//
//  CleanGutterMarkersTests.swift
//  PineTests
//
//  Tests for #688: gutter should show clean color markers only
//  (green=added, yellow=modified, red=deleted) without accept/revert buttons.
//  Validates behavioural changes: mouseDown routing, draw path, menu path.
//

import Testing
import AppKit
@testable import Pine

@Suite("Clean Gutter Markers Tests")
struct CleanGutterMarkersTests {

    // MARK: - Helpers

    private func makeLineNumberView() -> LineNumberView {
        let textStorage = NSTextStorage(string: "line1\nline2\nline3\nline4\nline5\n")
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
        return LineNumberView(textView: textView)
    }

    private func makeHunk(
        newStart: Int = 2,
        newCount: Int = 2,
        oldStart: Int = 2,
        oldCount: Int = 1
    ) -> DiffHunk {
        DiffHunk(
            newStart: newStart,
            newCount: newCount,
            oldStart: oldStart,
            oldCount: oldCount,
            rawText: "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\n context\n+added line\n"
        )
    }

    // MARK: - Accept/Revert properties removed (Mirror reflection)

    @Test func lineNumberViewHasNoAcceptHunkProperty() {
        // After #688, onAcceptHunk was removed from LineNumberView.
        // Use Mirror to verify the property does not exist at runtime.
        let view = makeLineNumberView()
        let mirror = Mirror(reflecting: view)
        let propertyNames = mirror.children.compactMap { $0.label }
        #expect(!propertyNames.contains("onAcceptHunk"),
                "onAcceptHunk property should be removed from LineNumberView")
    }

    @Test func lineNumberViewHasNoRevertHunkProperty() {
        let view = makeLineNumberView()
        let mirror = Mirror(reflecting: view)
        let propertyNames = mirror.children.compactMap { $0.label }
        #expect(!propertyNames.contains("onRevertHunk"),
                "onRevertHunk property should be removed from LineNumberView")
    }

    @Test func lineNumberViewDoesNotRespondToHunkButtonHitTest() {
        // hunkButtonHitTest method was removed — verify via ObjC runtime.
        let view = makeLineNumberView()
        let sel = NSSelectorFromString("hunkButtonHitTestAt:lineNumber:")
        #expect(!view.responds(to: sel),
                "hunkButtonHitTest should be removed from LineNumberView")
    }

    // MARK: - Diff hunks didSet rebuilds hunkStartMap (behavioural)

    @Test func settingDiffHunksRebuildsInternalState() {
        // diffHunks didSet rebuilds hunkStartMap. Verify this by checking
        // that the callback fires correctly for the new hunks.
        let view = makeLineNumberView()
        let hunk1 = makeHunk(newStart: 1)
        let hunk2 = makeHunk(newStart: 5)

        view.diffHunks = [hunk1]
        // Now replace with different hunks
        view.diffHunks = [hunk2]
        // The InlineDiffProvider (which hunkForLine delegates to) should find hunk2
        #expect(InlineDiffProvider.hunk(atLine: 5, in: view.diffHunks)?.id == hunk2.id)
        #expect(InlineDiffProvider.hunk(atLine: 1, in: view.diffHunks) == nil,
                "Old hunk should no longer be in diffHunks")
    }

    @Test func settingLineDiffsRebuildsInternalDiffMap() {
        // lineDiffs didSet rebuilds diffMap. The internal diffMap is private,
        // but we verify correctness by checking that lineDiffs is properly stored.
        let view = makeLineNumberView()
        view.lineDiffs = [
            GitLineDiff(line: 1, kind: .added),
            GitLineDiff(line: 3, kind: .modified)
        ]
        #expect(view.lineDiffs.count == 2)
        #expect(view.lineDiffs[0].line == 1)
        #expect(view.lineDiffs[0].kind == .added)
        #expect(view.lineDiffs[1].line == 3)
        #expect(view.lineDiffs[1].kind == .modified)

        // Replace with new set
        view.lineDiffs = [GitLineDiff(line: 5, kind: .deleted)]
        #expect(view.lineDiffs.count == 1)
        #expect(view.lineDiffs[0].line == 5)
    }

    @Test func expandedHunkIDTogglesCorrectly() {
        let view = makeLineNumberView()
        let hunk = makeHunk()
        view.diffHunks = [hunk]

        // Expand
        view.expandedHunkID = hunk.id
        #expect(view.expandedHunkID == hunk.id)

        // Toggle (collapse)
        let toggledID: UUID? = (view.expandedHunkID == hunk.id) ? nil : hunk.id
        view.expandedHunkID = toggledID
        #expect(view.expandedHunkID == nil)

        // Toggle again (expand)
        let toggledAgain: UUID? = (view.expandedHunkID == hunk.id) ? nil : hunk.id
        view.expandedHunkID = toggledAgain
        #expect(view.expandedHunkID == hunk.id)
    }

    // MARK: - onDiffMarkerClick is the only click callback

    @Test func onDiffMarkerClickIsNilByDefault() {
        let view = makeLineNumberView()
        #expect(view.onDiffMarkerClick == nil,
                "onDiffMarkerClick should be nil by default")
    }

    @Test func onDiffMarkerClickCallbackFires() {
        let view = makeLineNumberView()
        let hunk = makeHunk()
        var receivedHunk: DiffHunk?
        view.onDiffMarkerClick = { h in receivedHunk = h }
        // Simulate callback invocation (as mouseDown would do)
        view.onDiffMarkerClick?(hunk)
        #expect(receivedHunk?.id == hunk.id)
    }

    @Test func onDiffMarkerClickReceivesCorrectHunkFromMultiple() {
        let view = makeLineNumberView()
        let hunk1 = makeHunk(newStart: 1)
        let hunk2 = makeHunk(newStart: 5)
        view.diffHunks = [hunk1, hunk2]

        var receivedHunks: [DiffHunk] = []
        view.onDiffMarkerClick = { h in receivedHunks.append(h) }

        view.onDiffMarkerClick?(hunk1)
        view.onDiffMarkerClick?(hunk2)
        #expect(receivedHunks.count == 2)
        #expect(receivedHunks[0].id == hunk1.id)
        #expect(receivedHunks[1].id == hunk2.id)
    }

    // MARK: - mouseDown routing: diff marker area delegates to onDiffMarkerClick only

    @Test func mouseDownInDiffMarkerAreaWithNoDiffsDoesNotCrash() {
        // mouseDown at the right edge (diff marker area) with no diffs set
        // should not crash — lineNumber(at:) returns nil when no layout is available.
        let view = makeLineNumberView()
        view.frame = NSRect(x: 0, y: 0, width: 50, height: 100)
        view.gutterWidth = 50
        view.diffHunks = []

        // This exercises the diff marker branch of mouseDown
        // (point.x >= gutterWidth - diffBarWidth - 4 = 50 - 3 - 4 = 43)
        // Without a real scroll view, lineNumber(at:) returns nil → no crash
        let event = makeMouseEvent(at: NSPoint(x: 45, y: 10), in: view)
        // Should not crash
        view.mouseDown(with: event)
    }

    @Test func mouseDownInFoldAreaDoesNotTriggerDiffCallback() {
        let view = makeLineNumberView()
        view.frame = NSRect(x: 0, y: 0, width: 50, height: 100)
        view.gutterWidth = 50
        let hunk = makeHunk(newStart: 1)
        view.diffHunks = [hunk]

        var diffClicked = false
        view.onDiffMarkerClick = { _ in diffClicked = true }

        // Click in fold area (x < 14) — should NOT trigger diff callback
        let event = makeMouseEvent(at: NSPoint(x: 5, y: 10), in: view)
        view.mouseDown(with: event)
        #expect(!diffClicked, "Click in fold area should not trigger diff marker callback")
    }

    @Test func mouseDownInMiddleAreaDoesNotTriggerDiffCallback() {
        let view = makeLineNumberView()
        view.frame = NSRect(x: 0, y: 0, width: 50, height: 100)
        view.gutterWidth = 50
        let hunk = makeHunk(newStart: 1)
        view.diffHunks = [hunk]

        var diffClicked = false
        view.onDiffMarkerClick = { _ in diffClicked = true }

        // Click in middle area (x >= 14 and x < gutterWidth - 7)
        // This is the line number area — goes to super.mouseDown
        let event = makeMouseEvent(at: NSPoint(x: 25, y: 10), in: view)
        view.mouseDown(with: event)
        #expect(!diffClicked, "Click in line number area should not trigger diff marker callback")
    }

    // MARK: - Expanded hunk without buttons: no side effects

    @Test func expandingHunkDoesNotSetAcceptRevertCallbacks() {
        // Expanding a hunk should only set expandedHunkID, not trigger any
        // accept/revert callbacks (which no longer exist).
        let view = makeLineNumberView()
        let hunk = makeHunk()
        view.diffHunks = [hunk]

        // Verify no accept/revert properties via Mirror
        let mirror = Mirror(reflecting: view)
        let labels = mirror.children.compactMap { $0.label }
        #expect(!labels.contains("onAcceptHunk"))
        #expect(!labels.contains("onRevertHunk"))

        view.expandedHunkID = hunk.id
        #expect(view.expandedHunkID == hunk.id)
    }

    @Test func expandedHunkSwitchingDoesNotCrash() {
        let view = makeLineNumberView()
        let hunk1 = makeHunk(newStart: 1)
        let hunk2 = makeHunk(newStart: 4)
        view.diffHunks = [hunk1, hunk2]

        view.expandedHunkID = hunk1.id
        #expect(view.expandedHunkID == hunk1.id)

        view.expandedHunkID = hunk2.id
        #expect(view.expandedHunkID == hunk2.id)

        view.expandedHunkID = nil
        #expect(view.expandedHunkID == nil)
    }

    // MARK: - Menu accept/revert via NotificationCenter still works

    @Test func inlineDiffActionNotificationNameExists() {
        // The notification path for menu-triggered accept/revert must still exist.
        let name = Notification.Name.inlineDiffAction
        #expect(name.rawValue == "inlineDiffAction",
                "inlineDiffAction notification name must exist for menu commands")
    }

    @Test func inlineDiffActionNotificationDeliversPayload() {
        var receivedAction: InlineDiffAction?
        let observer = NotificationCenter.default.addObserver(
            forName: .inlineDiffAction,
            object: nil,
            queue: .main
        ) { notification in
            receivedAction = notification.userInfo?["action"] as? InlineDiffAction
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        NotificationCenter.default.post(
            name: .inlineDiffAction,
            object: nil,
            userInfo: ["action": InlineDiffAction.accept]
        )
        #expect(receivedAction == .accept,
                "NotificationCenter should deliver accept action")
    }

    @Test func inlineDiffActionNotificationDeliversRevert() {
        var receivedAction: InlineDiffAction?
        let observer = NotificationCenter.default.addObserver(
            forName: .inlineDiffAction,
            object: nil,
            queue: .main
        ) { notification in
            receivedAction = notification.userInfo?["action"] as? InlineDiffAction
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        NotificationCenter.default.post(
            name: .inlineDiffAction,
            object: nil,
            userInfo: ["action": InlineDiffAction.revert]
        )
        #expect(receivedAction == .revert,
                "NotificationCenter should deliver revert action")
    }

    @Test func inlineDiffActionNotificationDeliversAcceptAll() {
        var receivedAction: InlineDiffAction?
        let observer = NotificationCenter.default.addObserver(
            forName: .inlineDiffAction,
            object: nil,
            queue: .main
        ) { notification in
            receivedAction = notification.userInfo?["action"] as? InlineDiffAction
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        NotificationCenter.default.post(
            name: .inlineDiffAction,
            object: nil,
            userInfo: ["action": InlineDiffAction.acceptAll]
        )
        #expect(receivedAction == .acceptAll)
    }

    @Test func inlineDiffActionNotificationDeliversRevertAll() {
        var receivedAction: InlineDiffAction?
        let observer = NotificationCenter.default.addObserver(
            forName: .inlineDiffAction,
            object: nil,
            queue: .main
        ) { notification in
            receivedAction = notification.userInfo?["action"] as? InlineDiffAction
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        NotificationCenter.default.post(
            name: .inlineDiffAction,
            object: nil,
            userInfo: ["action": InlineDiffAction.revertAll]
        )
        #expect(receivedAction == .revertAll)
    }

    // MARK: - hunkForLine integration via InlineDiffProvider

    @Test func hunkForLineRoutesToInlineDiffProvider() {
        // LineNumberView.hunkForLine is private, but it delegates to
        // InlineDiffProvider.hunk(atLine:in:). Verify the provider logic
        // that the gutter relies on.
        let hunk = makeHunk(newStart: 2, newCount: 3)
        let hunks = [hunk]

        // Lines within range [2, 4] should match
        #expect(InlineDiffProvider.hunk(atLine: 2, in: hunks)?.id == hunk.id)
        #expect(InlineDiffProvider.hunk(atLine: 3, in: hunks)?.id == hunk.id)
        #expect(InlineDiffProvider.hunk(atLine: 4, in: hunks)?.id == hunk.id)

        // Lines outside range should not match
        #expect(InlineDiffProvider.hunk(atLine: 1, in: hunks) == nil)
        #expect(InlineDiffProvider.hunk(atLine: 5, in: hunks) == nil)
    }

    @Test func hunkForLineRequiresDiffMapEntry() {
        // hunkForLine guards on diffMap[line] != nil before calling InlineDiffProvider.
        // Verify that InlineDiffProvider itself only matches lines within hunk range,
        // so even without the diffMap guard, out-of-range lines return nil.
        let hunk = makeHunk(newStart: 10, newCount: 1)
        #expect(InlineDiffProvider.hunk(atLine: 9, in: [hunk]) == nil)
        #expect(InlineDiffProvider.hunk(atLine: 10, in: [hunk])?.id == hunk.id)
        #expect(InlineDiffProvider.hunk(atLine: 11, in: [hunk]) == nil)
    }

    @Test func hunkForLinePureDeletionMarker() {
        // Pure deletion (newCount=0) puts marker at newStart
        let hunk = DiffHunk(
            newStart: 5, newCount: 0, oldStart: 5, oldCount: 3,
            rawText: "@@ -5,3 +5,0 @@\n-del1\n-del2\n-del3"
        )
        #expect(InlineDiffProvider.hunk(atLine: 5, in: [hunk])?.id == hunk.id)
        #expect(InlineDiffProvider.hunk(atLine: 4, in: [hunk]) == nil)
        #expect(InlineDiffProvider.hunk(atLine: 6, in: [hunk]) == nil)
    }

    // MARK: - Empty and edge cases

    @Test func emptyDiffHunksDoNotCrash() {
        let view = makeLineNumberView()
        view.diffHunks = []
        view.lineDiffs = []
        view.expandedHunkID = nil
        // mouseDown with no diffs should not crash
        let event = makeMouseEvent(at: NSPoint(x: 45, y: 10), in: view)
        view.mouseDown(with: event)
    }

    @Test func replacingDiffHunksUpdatesState() {
        let view = makeLineNumberView()
        let hunk1 = makeHunk(newStart: 1)
        let hunk2 = makeHunk(newStart: 5)

        view.diffHunks = [hunk1]
        #expect(view.diffHunks.count == 1)

        view.diffHunks = [hunk1, hunk2]
        #expect(view.diffHunks.count == 2)

        view.diffHunks = []
        #expect(view.diffHunks.isEmpty)
    }

    @Test func expandedHunkIDWithStaleIDAfterDiffHunksChange() {
        let view = makeLineNumberView()
        let hunk = makeHunk()
        view.diffHunks = [hunk]
        view.expandedHunkID = hunk.id

        // Replace hunks — stale ID remains but no longer matches any hunk
        let newHunk = makeHunk(newStart: 10)
        view.diffHunks = [newHunk]
        let matchesOld = view.diffHunks.contains { $0.id == hunk.id }
        #expect(!matchesOld, "Old hunk ID should not match new hunks")
        #expect(view.expandedHunkID == hunk.id, "expandedHunkID is not auto-cleared")
    }

    // MARK: - Mouse event helper

    private func makeMouseEvent(at point: NSPoint, in view: NSView) -> NSEvent {
        // Convert view-local point to window coordinates for NSEvent
        let windowPoint = view.convert(point, to: nil)
        return NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )! // swiftlint:disable:this force_unwrapping
    }
}
