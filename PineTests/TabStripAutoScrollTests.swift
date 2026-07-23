//
//  TabStripAutoScrollTests.swift
//  PineTests
//
//  Deterministic edge, progression, and generation tests for #1196.
//

import CoreGraphics
import Foundation
import Testing

@testable import Pine

@Suite("Tab Strip Auto-Scroll Geometry")
struct TabStripAutoScrollGeometryTests {
    @Test("Only points inside a visible edge zone select a direction")
    func edgeDirection() {
        let width: CGFloat = 100
        let inset: CGFloat = 36

        #expect(TabStripAutoScrollGeometry.direction(
            atX: -1,
            viewportWidth: width,
            edgeInset: inset
        ) == nil)
        #expect(TabStripAutoScrollGeometry.direction(
            atX: 0,
            viewportWidth: width,
            edgeInset: inset
        ) == .leading)
        #expect(TabStripAutoScrollGeometry.direction(
            atX: 35,
            viewportWidth: width,
            edgeInset: inset
        ) == .leading)
        #expect(TabStripAutoScrollGeometry.direction(
            atX: 36,
            viewportWidth: width,
            edgeInset: inset
        ) == nil)
        #expect(TabStripAutoScrollGeometry.direction(
            atX: 64,
            viewportWidth: width,
            edgeInset: inset
        ) == nil)
        #expect(TabStripAutoScrollGeometry.direction(
            atX: 65,
            viewportWidth: width,
            edgeInset: inset
        ) == .trailing)
        #expect(TabStripAutoScrollGeometry.direction(
            atX: 100,
            viewportWidth: width,
            edgeInset: inset
        ) == .trailing)
        #expect(TabStripAutoScrollGeometry.direction(
            atX: 101,
            viewportWidth: width,
            edgeInset: inset
        ) == nil)
    }

    @Test("Narrow viewports split around a neutral midpoint")
    func narrowViewportDirection() {
        #expect(TabStripAutoScrollGeometry.direction(
            atX: 29,
            viewportWidth: 60
        ) == .leading)
        #expect(TabStripAutoScrollGeometry.direction(
            atX: 30,
            viewportWidth: 60
        ) == nil)
        #expect(TabStripAutoScrollGeometry.direction(
            atX: 31,
            viewportWidth: 60
        ) == .trailing)
    }

    @Test("Invalid viewport geometry never starts scrolling")
    func invalidViewportDirection() {
        let values: [(CGFloat, CGFloat, CGFloat)] = [
            (10, 0, 36),
            (10, -1, 36),
            (.infinity, 100, 36),
            (10, .infinity, 36),
            (10, 100, 0),
            (10, 100, CGFloat.nan),
        ]

        for (location, width, inset) in values {
            #expect(TabStripAutoScrollGeometry.direction(
                atX: location,
                viewportWidth: width,
                edgeInset: inset
            ) == nil)
        }
    }

    @Test("The nearest clipped tab is the next target in each direction")
    func nearestClippedTarget() {
        let ids = [UUID(), UUID(), UUID(), UUID()]
        let frames = [
            ids[0]: CGRect(x: -122, y: 0, width: 80, height: 30),
            ids[1]: CGRect(x: -40, y: 0, width: 80, height: 30),
            ids[2]: CGRect(x: 42, y: 0, width: 80, height: 30),
            ids[3]: CGRect(x: 204, y: 0, width: 80, height: 30),
        ]

        #expect(TabStripAutoScrollGeometry.nextTarget(
            direction: .leading,
            orderedTabIDs: ids,
            frames: frames,
            viewportWidth: 200
        ) == ids[1])
        #expect(TabStripAutoScrollGeometry.nextTarget(
            direction: .trailing,
            orderedTabIDs: ids,
            frames: frames,
            viewportWidth: 200
        ) == ids[3])
    }

    @Test("Fully visible, empty, missing, and malformed frames cannot progress")
    func noTargetForIncompleteOrVisibleGeometry() {
        let ids = [UUID(), UUID()]
        let visibleFrames = [
            ids[0]: CGRect(x: 4, y: 0, width: 80, height: 30),
            ids[1]: CGRect(x: 86, y: 0, width: 80, height: 30),
        ]

        for direction in [
            TabStripAutoScrollDirection.leading,
            .trailing,
        ] {
            #expect(TabStripAutoScrollGeometry.nextTarget(
                direction: direction,
                orderedTabIDs: [],
                frames: [:],
                viewportWidth: 200
            ) == nil)
            #expect(TabStripAutoScrollGeometry.nextTarget(
                direction: direction,
                orderedTabIDs: ids,
                frames: visibleFrames,
                viewportWidth: 200
            ) == nil)
            #expect(TabStripAutoScrollGeometry.nextTarget(
                direction: direction,
                orderedTabIDs: ids,
                frames: [
                    ids[0]: CGRect(x: 4, y: 0, width: 80, height: 30),
                ],
                viewportWidth: 200
            ) == nil)
            #expect(TabStripAutoScrollGeometry.nextTarget(
                direction: direction,
                orderedTabIDs: ids,
                frames: [
                    ids[0]: CGRect(x: CGFloat.nan, y: 0, width: 80, height: 30),
                    ids[1]: CGRect(x: 86, y: 0, width: 80, height: 30),
                ],
                viewportWidth: 200
            ) == nil)
        }
    }
}

@Suite("Tab Strip Auto-Scroll Session")
@MainActor
struct TabStripAutoScrollSessionTests {
    @Test("Hover starts only when the edge has clipped content")
    func hoverRequiresReachableTarget() {
        let session = TabStripAutoScrollSession()
        let dragID = UUID()
        let owner = TabStripAutoScrollOwner(
            dragID: dragID,
            destinationPaneID: PaneID().id
        )
        let ids = [UUID(), UUID()]
        let frames = [
            ids[0]: CGRect(x: 0, y: 0, width: 80, height: 30),
            ids[1]: CGRect(x: 202, y: 0, width: 80, height: 30),
        ]

        session.updateHover(
            owner: owner,
            locationX: 100,
            viewportWidth: 200,
            orderedTabIDs: ids,
            frames: frames
        )
        #expect(session.request == nil)
        #expect(session.targetID == nil)

        session.updateHover(
            owner: owner,
            locationX: 190,
            viewportWidth: 200,
            orderedTabIDs: ids,
            frames: frames
        )
        #expect(session.request == TabStripAutoScrollRequest(
            owner: owner,
            direction: .trailing
        ))
        #expect(session.targetID == ids[1])
    }

    @Test("Updated frames advance trailing targets without restarting the drag")
    func geometryAdvancesTarget() {
        let session = TabStripAutoScrollSession()
        let dragID = UUID()
        let owner = TabStripAutoScrollOwner(
            dragID: dragID,
            destinationPaneID: PaneID().id
        )
        let ids = [UUID(), UUID(), UUID(), UUID()]
        session.updateHover(
            owner: owner,
            locationX: 190,
            viewportWidth: 200,
            orderedTabIDs: ids,
            frames: [
                ids[0]: CGRect(x: 0, y: 0, width: 80, height: 30),
                ids[1]: CGRect(x: 82, y: 0, width: 80, height: 30),
                ids[2]: CGRect(x: 164, y: 0, width: 80, height: 30),
                ids[3]: CGRect(x: 246, y: 0, width: 80, height: 30),
            ]
        )
        let request = session.request
        #expect(session.targetID == ids[2])

        session.updateGeometry(
            viewportWidth: 200,
            orderedTabIDs: ids,
            frames: [
                ids[0]: CGRect(x: -44, y: 0, width: 80, height: 30),
                ids[1]: CGRect(x: 38, y: 0, width: 80, height: 30),
                ids[2]: CGRect(x: 120, y: 0, width: 80, height: 30),
                ids[3]: CGRect(x: 202, y: 0, width: 80, height: 30),
            ]
        )

        #expect(session.request == request)
        #expect(session.targetID == ids[3])

        session.updateGeometry(
            viewportWidth: 200,
            orderedTabIDs: ids,
            frames: [
                ids[0]: CGRect(x: -128, y: 0, width: 80, height: 30),
                ids[1]: CGRect(x: -46, y: 0, width: 80, height: 30),
                ids[2]: CGRect(x: 36, y: 0, width: 80, height: 30),
                ids[3]: CGRect(x: 118, y: 0, width: 80, height: 30),
            ]
        )

        #expect(session.request == nil)
        #expect(session.targetID == nil)
    }

    @Test("Updated frames advance leading targets without restarting the drag")
    func geometryAdvancesLeadingTarget() {
        let session = TabStripAutoScrollSession()
        let dragID = UUID()
        let owner = TabStripAutoScrollOwner(
            dragID: dragID,
            destinationPaneID: PaneID().id
        )
        let ids = [UUID(), UUID(), UUID(), UUID()]
        session.updateHover(
            owner: owner,
            locationX: 10,
            viewportWidth: 200,
            orderedTabIDs: ids,
            frames: [
                ids[0]: CGRect(x: -164, y: 0, width: 80, height: 30),
                ids[1]: CGRect(x: -82, y: 0, width: 80, height: 30),
                ids[2]: CGRect(x: 0, y: 0, width: 80, height: 30),
                ids[3]: CGRect(x: 82, y: 0, width: 80, height: 30),
            ]
        )
        let request = session.request
        #expect(session.targetID == ids[1])

        session.updateGeometry(
            viewportWidth: 200,
            orderedTabIDs: ids,
            frames: [
                ids[0]: CGRect(x: -82, y: 0, width: 80, height: 30),
                ids[1]: CGRect(x: 0, y: 0, width: 80, height: 30),
                ids[2]: CGRect(x: 82, y: 0, width: 80, height: 30),
                ids[3]: CGRect(x: 164, y: 0, width: 80, height: 30),
            ]
        )

        #expect(session.request == request)
        #expect(session.targetID == ids[0])
    }

    @Test("Cancellation and generation replacement clear every hover field")
    func lifecycleStopsScrolling() {
        let session = TabStripAutoScrollSession()
        let dragID = UUID()
        let owner = TabStripAutoScrollOwner(
            dragID: dragID,
            destinationPaneID: PaneID().id
        )
        let targetID = UUID()
        session.updateHover(
            owner: owner,
            locationX: 99,
            viewportWidth: 100,
            orderedTabIDs: [targetID],
            frames: [targetID: CGRect(x: 120, y: 0, width: 80, height: 30)]
        )
        #expect(session.request != nil)

        session.activeOwnerDidChange(to: TabStripAutoScrollOwner(
            dragID: UUID(),
            destinationPaneID: owner.destinationPaneID
        ))
        #expect(session.request == nil)
        #expect(session.targetID == nil)
        #expect(session.hoverLocationX == nil)
        #expect(session.hoveredDragID == nil)

        session.updateHover(
            owner: owner,
            locationX: 99,
            viewportWidth: 100,
            orderedTabIDs: [targetID],
            frames: [targetID: CGRect(x: 120, y: 0, width: 80, height: 30)]
        )
        session.activeOwnerDidChange(to: owner)
        #expect(session.request != nil)

        session.activeOwnerDidChange(to: nil)
        #expect(session.request == nil)
        #expect(session.targetID == nil)
        #expect(session.hoverLocationX == nil)
        #expect(session.hoveredDragID == nil)
    }

    @Test("Destination replacement stops an old strip without an exit callback")
    func destinationReplacementStopsOldStrip() throws {
        let session = TabStripAutoScrollSession()
        let dragID = UUID()
        let drag = TabDragInfo(
            dragID: dragID,
            paneID: PaneID().id,
            tabID: UUID(),
            contentType: .editor
        )
        let key = TabDragKey(drag)
        let oldOwner = try #require(TabStripAutoScrollOwner.current(
            activeDrag: drag,
            previewIntent: .insert(
                drag: key,
                destinationPaneID: PaneID(),
                insertionIndex: 0
            )
        ))
        let targetID = UUID()
        session.updateHover(
            owner: oldOwner,
            locationX: 99,
            viewportWidth: 100,
            orderedTabIDs: [targetID],
            frames: [targetID: CGRect(x: 120, y: 0, width: 80, height: 30)]
        )
        #expect(session.request != nil)

        let replacementOwner = try #require(TabStripAutoScrollOwner.current(
            activeDrag: drag,
            previewIntent: .insert(
                drag: key,
                destinationPaneID: PaneID(),
                insertionIndex: 0
            )
        ))
        session.activeOwnerDidChange(to: replacementOwner)

        #expect(session.request == nil)
        #expect(session.targetID == nil)
        #expect(session.hoverLocationX == nil)
        #expect(session.hoveredOwner == nil)
        #expect(TabStripAutoScrollOwner.current(
            activeDrag: drag,
            previewIntent: .merge(
                drag: key,
                destinationPaneID: PaneID(id: oldOwner.destinationPaneID)
            )
        ) == nil)
    }

    @Test("Exit, drop, and disappearance share an idempotent terminal state")
    func explicitEndIsIdempotent() {
        let session = TabStripAutoScrollSession()
        let dragID = UUID()
        let owner = TabStripAutoScrollOwner(
            dragID: dragID,
            destinationPaneID: PaneID().id
        )
        let targetID = UUID()
        session.updateHover(
            owner: owner,
            locationX: 99,
            viewportWidth: 100,
            orderedTabIDs: [targetID],
            frames: [targetID: CGRect(x: 120, y: 0, width: 80, height: 30)]
        )
        #expect(session.request != nil)

        session.end()
        session.end()
        #expect(session.request == nil)
        #expect(session.targetID == nil)
        #expect(session.hoverLocationX == nil)
        #expect(session.hoveredDragID == nil)
    }
}
