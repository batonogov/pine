//
//  FileSystemWatcher.swift
//  Pine
//
//  Watches a directory tree for filesystem changes using FSEvents
//  and fires a debounced callback on the main thread when files
//  are created, deleted, renamed, or modified.
//

import Foundation

nonisolated final class FileSystemWatcher {
    private var stream: FSEventStreamRef?
    private let callback: @MainActor () -> Void
    private let debounceInterval: TimeInterval

    /// Serial queue that owns all mutable state (stream, debounceWorkItem).
    /// FSEvents callbacks are delivered here too.
    private let queue = DispatchQueue(label: "pine.fswatcher", qos: .utility)
    private var debounceWorkItem: DispatchWorkItem?

    /// Strong self-reference kept while the stream is active.
    /// Prevents deallocation while FSEvents holds an unretained pointer.
    /// Broken in stopOnQueue() when the stream is torn down.
    private var retainedSelf: FileSystemWatcher?

    /// Token incremented on every stop so that a main.async callback
    /// that was already enqueued before stop() can detect staleness
    /// and skip delivery. Read/written on queue; captured by value
    /// into the main.async block and compared on main via the
    /// thread-safe isActive(generation:) check.
    private var activeGeneration: Int = 0

    init(debounceInterval: TimeInterval = 0.5, callback: @escaping @MainActor () -> Void) {
        self.debounceInterval = debounceInterval
        self.callback = callback
    }

    func watch(directory: URL) {
        queue.sync { self.watchOnQueue(directory: directory) }
    }

    /// Must be called before dropping the last external reference.
    func stop() {
        queue.sync { self.stopOnQueue() }
    }

    // MARK: - Private (must run on self.queue)

    private func watchOnQueue(directory: URL) {
        stopOnQueue()

        let path = directory.path as CFString
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        guard let stream = FSEventStreamCreate(
            nil,
            fsEventCallback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounceInterval,
            UInt32(
                kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
            )
        ) else { return }

        self.stream = stream
        retainedSelf = self
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    private func stopOnQueue() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        activeGeneration += 1

        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        retainedSelf = nil
    }

    /// Thread-safe check: returns true only if no stop() has occurred
    /// since the given generation was captured.
    private func isActive(generation: Int) -> Bool {
        queue.sync { activeGeneration == generation }
    }

    /// Called from the FSEvents callback on self.queue.
    /// Applies a short debounce (`debounceInterval`) on main thread to coalesce
    /// rapid FSEvents bursts (e.g. npm install, git checkout) into a single
    /// callback. Previous work items are cancelled so only the last one fires.
    fileprivate func handleEvents() {
        debounceWorkItem?.cancel()
        let cb = callback
        let generation = activeGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // If stop() was called between enqueue and delivery,
            // the generation will have changed — skip the callback.
            guard self.isActive(generation: generation) else { return }
            MainActor.assumeIsolated { cb() }
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}

// swiftlint:disable:next function_parameter_count
nonisolated private func fsEventCallback(
    _ streamRef: ConstFSEventStreamRef,
    _ clientCallBackInfo: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
    watcher.handleEvents()
}
