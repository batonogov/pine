//
//  FileSystemWatcher.swift
//  Pine
//
//  Watches a directory tree for filesystem changes using FSEvents
//  and fires a debounced callback on the main thread when files
//  are created, deleted, renamed, or modified.
//

import Foundation

final class FileSystemWatcher {
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

        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        retainedSelf = nil
    }

    /// Called from the FSEvents callback on self.queue.
    /// Debounces on the serial queue, then dispatches the callback to main.
    fileprivate func handleEvents() {
        debounceWorkItem?.cancel()
        let cb = callback
        let work = DispatchWorkItem {
            DispatchQueue.main.async { cb() }
        }
        debounceWorkItem = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}

private func fsEventCallback(
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
