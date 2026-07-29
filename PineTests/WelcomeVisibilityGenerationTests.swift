//
//  WelcomeVisibilityGenerationTests.swift
//  PineTests
//

import Testing

@testable import Pine

@Suite("Welcome Visibility Generation Tests")
@MainActor
struct WelcomeVisibilityGenerationTests {
    @Test func hideBeforeDelayedEnsureDoesNotShowWelcomeAgain() async {
        let delegate = AppDelegate()
        delegate.openNamedWindow = { _ in }
        let (gate, continuation) = AsyncStream.makeStream(of: Void.self)
        var ensureCount = 0

        delegate.showWelcome(
            waitBeforeEnsure: {
                for await _ in gate {
                    return
                }
            },
            ensureVisible: {
                ensureCount += 1
            }
        )
        delegate.hideWelcome()

        continuation.yield(())
        continuation.finish()
        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(ensureCount == 0)
    }
}
