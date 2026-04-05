# Root-Level Drop Zones for Full-Width/Height Pane Splits

**Issue:** #712
**Date:** 2026-04-05

## Problem

Drop zones exist only on leaf panes. Dragging a terminal tab to the edge of one editor creates a split inside that editor, not a full-width/height split at the root level. There is no way to create a terminal pane spanning the full width/height of the window.

## Solution

Add a transparent overlay at the `PaneTreeView` root level with thin edge-only drop zones (10% threshold). When a terminal tab is dropped on a root-level edge zone, wrap the entire `PaneNode` root in a new split, producing a full-width/height terminal pane.

## Scope

- Terminal tabs only. Editor tabs are not supported for root-level drops.
- All 4 edges: top, bottom, left, right.

## New Components

### RootDropZone (enum)

Defined in a new file `Pine/RootDropZone.swift`.

```
enum RootDropZone {
    case top, bottom, left, right
}
```

Detection logic:
- Threshold: 10% of the container dimension (width for left/right, height for top/bottom).
- If cursor is within 10% of an edge, that edge's zone activates.
- Corner conflict resolution: same as `PaneDropZone` — compare distance to nearest horizontal vs vertical edge, pick closest.
- Center area (no zone): returns `nil`.

Static method: `detect(location: CGPoint, in size: CGSize) -> RootDropZone?`

### RootDropOverlay (SwiftUI View)

Defined in `Pine/RootDropZone.swift` (same file).

- Overlay on top of `PaneTreeView` content.
- When `dropZone` is non-nil, renders a semi-transparent rectangle spanning the full width or height of the container:
  - `.top` / `.bottom`: full width, 30% height, positioned at top/bottom edge.
  - `.left` / `.right`: full height, 30% width, positioned at left/right edge.
- Color: system accent with 0.2 opacity (same style as `PaneDropOverlay` but visually distinguishable by covering the full span).
- `allowsHitTesting(false)` to avoid blocking drop events.

### RootPaneSplitDropDelegate (DropDelegate)

Defined in `Pine/RootDropZone.swift` (same file).

**Validation:**
- Accepts only `.paneTabDrag` UTType.
- Reads `paneManager.activeDrag` — rejects if `contentType != .terminal`.
- Rejects if tree has only 1 leaf (nowhere to move from).

**Drop zone tracking:**
- Uses `paneManager.rootDropZone: RootDropZone?` (new property) for overlay state.
- `dropEntered` / `dropUpdated`: compute zone from cursor location and pane size, update `paneManager.rootDropZone`.
- `dropExited`: clear `paneManager.rootDropZone`.

**performDrop:**
1. Snapshot `rootDropZone`, clear it.
2. Read `paneManager.activeDrag`, clear it.
3. Call `paneManager.wrapRootWithTerminal(at: zone, from: sourcePaneID, tabID: tabID)`.

## PaneManager Changes

### New property

```swift
var rootDropZone: RootDropZone?
```

Cleared by mouse-up NSEvent monitor (same as existing `clearAllDropZones()`).

### New method: wrapRootWithTerminal

```swift
func wrapRootWithTerminal(at zone: RootDropZone, from sourcePaneID: PaneID, tabID: UUID)
```

Logic:
1. Create new `PaneID` for the terminal leaf.
2. Create new `TerminalPaneState` for the new pane.
3. Move the terminal tab from source pane's `TerminalPaneState` to new pane's state.
4. If source pane's terminal state is now empty, remove source pane via `removePane()`.
5. Wrap root based on zone:
   - `.bottom` -> `.split(.vertical, first: currentRoot, second: .leaf(newID, .terminal), ratio: 0.7)`
   - `.top` -> `.split(.vertical, first: .leaf(newID, .terminal), second: currentRoot, ratio: 0.3)`
   - `.right` -> `.split(.horizontal, first: currentRoot, second: .leaf(newID, .terminal), ratio: 0.7)`
   - `.left` -> `.split(.horizontal, first: .leaf(newID, .terminal), second: currentRoot, ratio: 0.3)`
6. Set `activePaneID` to the new terminal pane.

The existing `createTerminalPaneAtBottom()` should be refactored to call `wrapRootWithTerminal(at: .bottom, ...)` internally (or kept as-is if the signature difference makes refactoring awkward).

## PaneTreeView Integration

In `PaneTreeView`, add at the top level:

```swift
var body: some View {
    nodeView
        .overlay {
            RootDropOverlay(dropZone: paneManager.rootDropZone)
        }
        .onDrop(of: [.paneTabDrag], delegate: RootPaneSplitDropDelegate(
            paneManager: paneManager,
            containerSize: containerSize
        ))
}
```

Container size captured via `GeometryReader` / preference key.

**Z-order / priority:** The root overlay is rendered on top of leaf overlays. Since `.onDrop` delegates fire from outermost to innermost, and the root delegate only activates within the 10% edge threshold (rejecting via `dropUpdated` returning nil zone otherwise), leaf delegates handle the interior. When cursor is in the 10% edge zone, the root delegate takes priority because it's the outermost handler and will set `rootDropZone`, visually overriding leaf overlays.

If z-order conflict arises (both root and leaf showing overlays), the root delegate should clear `paneManager.dropZones` for all leaves when `rootDropZone` is non-nil.

## Testing

### Unit Tests (PineTests/)

**RootDropZoneTests:**
- `testDetectTopZone` — cursor at (50%, 5%) in 1000x800 -> `.top`
- `testDetectBottomZone` — cursor at (50%, 95%) -> `.bottom`
- `testDetectLeftZone` — cursor at (5%, 50%) -> `.left`
- `testDetectRightZone` — cursor at (95%, 50%) -> `.right`
- `testDetectNoZone` — cursor at (50%, 50%) -> `nil`
- `testCornerResolution` — cursor at (5%, 5%) -> closest edge wins
- `testEdgeThreshold` — cursor at exactly 10% boundary

**PaneManagerRootDropTests:**
- `testWrapRootBottom` — verify tree structure: `.split(.vertical, first: originalRoot, second: newTerminal, ratio: 0.7)`
- `testWrapRootTop` — `.split(.vertical, first: newTerminal, second: originalRoot, ratio: 0.3)`
- `testWrapRootRight` — `.split(.horizontal, first: originalRoot, second: newTerminal, ratio: 0.7)`
- `testWrapRootLeft` — `.split(.horizontal, first: newTerminal, second: originalRoot, ratio: 0.3)`
- `testTerminalTabMovedToNewPane` — tab removed from source, present in new pane
- `testSourcePaneRemovedWhenEmpty` — source pane cleaned up after last tab moved
- `testSourcePaneKeptWhenNotEmpty` — source pane kept if it has remaining tabs
- `testActivePaneSetToNewTerminal` — `activePaneID` updated
- `testRejectsEditorTabs` — editor content type rejected by delegate validation

## Files Changed

| File | Change |
|------|--------|
| `Pine/RootDropZone.swift` | **New** — RootDropZone enum, RootDropOverlay, RootPaneSplitDropDelegate |
| `Pine/PaneManager.swift` | Add `rootDropZone` property, `wrapRootWithTerminal()` method, clear rootDropZone in mouse-up monitor |
| `Pine/PaneTreeView.swift` | Add root overlay and onDrop delegate |
| `PineTests/RootDropZoneTests.swift` | **New** — zone detection tests |
| `PineTests/PaneManagerRootDropTests.swift` | **New** — wrapRootWithTerminal tests |
