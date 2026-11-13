import CoreFoundation
import Dispatch
import Foundation
import SwiftUI

/// Validate identity before SwiftUI constructs AppDelegate and shared settings.
@main
@MainActor
enum PineEntryPoint {
    static func main() {
        guard PineStorageContext.launchIsSafe(
            testHost: PineStorageContext.isTestHost,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            arguments: CommandLine.arguments,
            environment: ProcessInfo.processInfo.environment
        ) else {
            FileHandle.standardError.write(Data(
                "State-reset tests require the isolated Testing configuration\n".utf8
            ))
            exit(78)
        }
        // All subsequent initialization can safely open recovery/task stores.
        if PineStorageContext.isTestHost {
            prepareTestStorage()
        }
        // AppKit's permanent run loop must start outside an async-main task or
        // dispatched block, so it can drain main-queue XCTest/SwiftUI work.
        PineApp.main()
    }

    private static func prepareTestStorage() {
        let runLoop = CFRunLoopGetMain()
        var context = CFRunLoopSourceContext(
            version: 0, info: nil, retain: nil, release: nil, copyDescription: nil,
            equal: nil, hash: nil, schedule: nil, cancel: nil, perform: { _ in }
        )
        guard let source = CFRunLoopSourceCreate(nil, 0, &context), let runLoop else {
            exit(78)
        }
        CFRunLoopAddSource(runLoop, source, .defaultMode)
        defer {
            CFRunLoopRemoveSource(runLoop, source, .defaultMode)
            CFRunLoopSourceInvalidate(source)
        }
        let preparation = StoragePreparation(runLoop: runLoop, source: source)
        DispatchQueue.global(qos: .userInitiated).async {
            autoreleasepool {
                _ = PineStorageContext.applicationSupportDirectory
            }
            preparation.finish()
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
        while !preparation.isFinished {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                FileHandle.standardError.write(Data("Private test storage preparation timed out\n".utf8))
                exit(78)
            }
            // Process events while the worker performs filesystem I/O. The
            // source keeps this temporary loop alive and retains completion
            // signals even when preparation finishes before this call starts.
            let remaining = Double(deadline - now) / 1_000_000_000
            CFRunLoopRunInMode(.defaultMode, remaining, true)
        }
    }

    /// Immutable CF handles support cross-thread signaling; only completion is
    /// mutable, and its lock never covers filesystem work or event processing.
    nonisolated private final class StoragePreparation: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private let runLoop: CFRunLoop
        private let source: CFRunLoopSource

        init(runLoop: CFRunLoop, source: CFRunLoopSource) {
            self.runLoop = runLoop
            self.source = source
        }

        var isFinished: Bool { lock.withLock { finished } }

        func finish() {
            lock.withLock { finished = true }
            CFRunLoopSourceSignal(source)
            CFRunLoopWakeUp(runLoop)
        }
    }
}
