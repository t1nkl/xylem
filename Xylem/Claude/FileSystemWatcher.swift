//
//  FileSystemWatcher.swift
//  Xylem
//
//  Watches a set of files and directories on disk, invoking a callback when
//  anything underneath them changes. Backed by DispatchSource's `vnode`
//  monitor - one source per path. Notifications are coalesced through a 400ms
//  debounce so a burst of writes results in a single reload.
//

import Foundation

// `nonisolated` + `@unchecked Sendable`: all mutable state is confined to
// `queue`; the handler is invoked on that queue, never on the main actor.
nonisolated final class FileSystemWatcher: @unchecked Sendable {
    private struct Entry {
        let source: DispatchSourceFileSystemObject
        let fileDescriptor: Int32
    }

    private let queue: DispatchQueue
    private let debounceInterval: TimeInterval
    private var entries: [String: Entry] = [:]
    private var pendingWork: DispatchWorkItem?
    private var onChange: (@Sendable () -> Void)?

    init(
        queue: DispatchQueue = DispatchQueue(label: "com.xylem.fswatcher", qos: .utility),
        debounceInterval: TimeInterval = 0.4
    ) {
        self.queue = queue
        self.debounceInterval = debounceInterval
    }

    deinit {
        for entry in entries.values {
            entry.source.cancel()
        }
    }

    func setHandler(_ handler: @escaping @Sendable () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.onChange = handler
        }
    }

    /// Replaces the set of watched paths. Paths that no longer exist are
    /// silently skipped; adding or removing entries is cheap (O(n)) because
    /// underlying descriptors are re-used when possible.
    func watch(paths: [String]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.replaceEntries(with: paths)
        }
    }

    // MARK: - Private

    private func replaceEntries(with paths: [String]) {
        let desired = Set(paths)
        let current = Set(entries.keys)

        for stale in current.subtracting(desired) {
            if let entry = entries.removeValue(forKey: stale) {
                entry.source.cancel()
            }
        }

        for added in desired.subtracting(current) {
            guard let entry = makeEntry(for: added) else { continue }
            entries[added] = entry
        }
    }

    private func makeEntry(for path: String) -> Entry? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        // No `.attrib`: reading a file can bump its atime, and git reading
        // `.git/index` during a status refresh would then re-trigger that
        // refresh. Content changes arrive as write/extend/rename/delete.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .link, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            if let events = source?.data, !events.isDisjoint(with: [.delete, .rename]) {
                self.rearm(path)
            }
            self.scheduleCallback()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        return Entry(source: source, fileDescriptor: fd)
    }

    /// Atomic writers (git's `index.lock` → `index`, editors saving
    /// settings.json) replace the file, so the descriptor we hold now points
    /// at an unlinked inode and would never fire again. Re-open the path.
    private func rearm(_ path: String) {
        guard let old = entries.removeValue(forKey: path) else { return }
        old.source.cancel()
        if let fresh = makeEntry(for: path) {
            entries[path] = fresh
        }
    }

    private func scheduleCallback() {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange?()
        }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
