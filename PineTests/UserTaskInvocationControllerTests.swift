//
//  UserTaskInvocationControllerTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("User task invocation safety")
struct UserTaskInvocationControllerTests {
    @Test("Output replacement requires the same unchanged editor buffer")
    func replacementRequiresSameUnchangedBuffer() {
        let tabID = UUID()

        #expect(UserTaskInvocationController.canApplyReplacement(
            capturedTabID: tabID,
            capturedContent: "before",
            currentTabID: tabID,
            currentContent: "before"
        ))
        #expect(!UserTaskInvocationController.canApplyReplacement(
            capturedTabID: tabID,
            capturedContent: "before",
            currentTabID: UUID(),
            currentContent: "before"
        ))
        #expect(!UserTaskInvocationController.canApplyReplacement(
            capturedTabID: tabID,
            capturedContent: "before",
            currentTabID: tabID,
            currentContent: "human edit"
        ))
    }

    @Test("Missing capture data always fails closed", arguments: [
        (nil, "before", UUID(), "before"),
        (UUID(), nil, UUID(), "before"),
        (nil, nil, nil, nil),
    ] as [(UUID?, String?, UUID?, String?)])
    func missingCaptureFailsClosed(
        capturedTabID: UUID?,
        capturedContent: String?,
        currentTabID: UUID?,
        currentContent: String?
    ) {
        #expect(!UserTaskInvocationController.canApplyReplacement(
            capturedTabID: capturedTabID,
            capturedContent: capturedContent,
            currentTabID: currentTabID,
            currentContent: currentContent
        ))
    }
}
