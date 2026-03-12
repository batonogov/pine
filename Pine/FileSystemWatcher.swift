//
//  FileSystemWatcher.swift
//  Pine
//
//  Watches a directory tree for filesystem changes using FSEvents
//  and fires a debounced callback when files are created, deleted,
//  renamed, or modified.
//

import Foundation

final class FileSystemWatcher {
    private var stream: FSEventStreamRef?
    private let callback: () -> Void
    private let debounceInterval: TimeInterval

    /// Serial queue that owns all mutable state (stream, debounceWorkItem)
    /// and receives FSEvents callbacks, eliminating races between
    /// event delivery, debounce scheduling, and stop/deinit.
    private let queue = DispatchQueue(label: "pine.fswatcher", qos: .utility)
    private var debounceWorkItem: DispatchWorkItem?

    init(debounceInterval: TimeInterval = 0.5, callback: @escaping () -> Void) {
        self.debounceInterval = debounceInterval
        self.callback = callback
    }

    deinit {
        stopOnQueue()
    }

    func watch(directory: URL) {
        queue.sync { self.watchOnQueue(directory: directory) }
    }

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
    }

    /// Called from the FSEvents callback on self.queue.
    fileprivate func handleEvents() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.callback()
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
