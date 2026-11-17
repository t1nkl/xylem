//
//  IncrementalJSONLCache.swift
//  Xylem
//
//  Claude Code session jsonl files are append-only and grow to many MB.
//  Readers that fold a whole file into a small result (stats, last prompt) keep their fold state here per file, together with the byte
//  offset already consumed, so each poll parses only the appended bytes -
//  and does no reading at all when size and mtime are unchanged.
//
//  State resets when the file is replaced (different inode or birth time)
//  or shrinks below the consumed offset.
//

import Foundation

/// Accumulated result of folding jsonl objects in file order.
nonisolated protocol JSONLFoldState {
    init()
    /// Called for every decoded line, in file order.
    mutating func consume(_ object: [String: Any])
    /// Called once after each batch of new lines (possibly empty), before
    /// the state is read. For work that only needs the latest value.
    mutating func finishBatch()
}

nonisolated extension JSONLFoldState {
    mutating func finishBatch() {}
}

nonisolated final class IncrementalJSONLCache<State: JSONLFoldState>: @unchecked Sendable {
    private struct FileIdentity: Equatable {
        let device: Int32
        let inode: UInt64
        let birthSeconds: Int
        let birthNanoseconds: Int
    }

    private struct FileStamp: Equatable {
        let identity: FileIdentity
        let size: Int64
        let mtimeSeconds: Int
        let mtimeNanoseconds: Int
    }

    /// One per file. Its own lock serialises readers of the same file
    /// without blocking readers of other files.
    private final class Entry: @unchecked Sendable {
        let lock = NSLock()
        var identity: FileIdentity?
        var stamp: FileStamp?
        var offset: UInt64 = 0
        var state = State()
        /// Recency tick, guarded by the cache-wide `lock` (not this entry's).
        var lastUsed: UInt64 = 0
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    private let capacity: Int

    init(capacity: Int = 32) {
        self.capacity = capacity
    }

    /// Brings the state for `url` up to date and hands it to `body`.
    /// Returns `nil` if the file can't be stat-ed or read.
    func withState<Result>(for url: URL, _ body: (State) -> Result) -> Result? {
        let path = url.standardizedFileURL.path
        guard let stamp = Self.stamp(of: path) else {
            drop(path)
            return nil
        }
        let entry = entry(for: path)
        entry.lock.lock()
        defer { entry.lock.unlock() }

        if entry.stamp != stamp {
            if entry.identity != stamp.identity || UInt64(max(stamp.size, 0)) < entry.offset {
                entry.offset = 0
                entry.state = State()
            }
            var state = entry.state
            guard let newOffset = JSONLReader.forEachJSONObject(
                in: url,
                fromOffset: entry.offset,
                handler: { state.consume($0) }
            ) else { return nil }
            state.finishBatch()
            entry.state = state
            entry.offset = newOffset
            entry.identity = stamp.identity
            // Only remember the stamp once every byte is consumed; a
            // half-written trailing line must be re-read next time even if
            // nothing else changes.
            entry.stamp = newOffset >= UInt64(max(stamp.size, 0)) ? stamp : nil
        }
        return body(entry.state)
    }

    /// Forgets every file. For tests.
    func removeAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    // MARK: - Private

    private func entry(for path: String) -> Entry {
        lock.lock()
        defer { lock.unlock() }
        clock &+= 1
        if let existing = entries[path] {
            existing.lastUsed = clock
            return existing
        }
        // Evict the least recently used file: the active tabs' sessions are
        // read every few seconds and must never be the ones pushed out (a
        // re-fold of a 100 MB session is the cost this cache exists to avoid).
        if entries.count >= capacity,
           let victim = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            entries.removeValue(forKey: victim)
        }
        let created = Entry()
        created.lastUsed = clock
        entries[path] = created
        return created
    }

    private func drop(_ path: String) {
        lock.lock()
        entries.removeValue(forKey: path)
        lock.unlock()
    }

    private static func stamp(of path: String) -> FileStamp? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileStamp(
            identity: FileIdentity(
                device: info.st_dev,
                inode: info.st_ino,
                birthSeconds: info.st_birthtimespec.tv_sec,
                birthNanoseconds: info.st_birthtimespec.tv_nsec
            ),
            size: info.st_size,
            mtimeSeconds: info.st_mtimespec.tv_sec,
            mtimeNanoseconds: info.st_mtimespec.tv_nsec
        )
    }
}
