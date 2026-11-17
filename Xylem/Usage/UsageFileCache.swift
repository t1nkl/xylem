//
//  UsageFileCache.swift
//  Xylem
//
//  Per-file aggregate cache that lets UsageAggregator skip jsonl files that
//  haven't changed since the last scan, and read only the appended part of
//  those that grew. Keyed by absolute path so projects that are renamed or
//  disappear simply fall out of the cache naturally.
//
//  Freshness is decided by a `FileStamp` (size + mtime seconds + mtime
//  nanoseconds + inode straight from `stat`), stored as plain integers.
//  The first version stored `mtime: Date` through `.iso8601`, which keeps
//  whole seconds only, and compared it with `==` against APFS nanosecond
//  mtimes - so no entry ever matched and every refresh re-parsed every
//  jsonl (~3 GB on a heavy machine). Integers round-trip through JSON
//  exactly, so equality is meaningful again.
//
//  Subagent transcripts (`<session>/subagents/agent-*.jsonl`) are cached
//  the same way, one entry per file; their `sessionID` is the parent
//  session's id, so the dashboard folds them into that session.
//
//  The file on disk is an envelope `{ "version": N, "entries": [...] }`.
//  Any older or differently-shaped file fails to decode and loads as empty,
//  which costs exactly one full re-parse.
//

import Foundation

/// Identity of a file's contents as cheaply as the filesystem can give it.
/// Equal stamps mean "same bytes" for append-only jsonl: an append bumps
/// size and mtime, an atomic rewrite usually changes the inode as well.
nonisolated struct FileStamp: Codable, Hashable {
    let size: UInt64
    let mtimeSeconds: Int64
    let mtimeNanoseconds: Int64
    let inode: UInt64

    /// `stat`s `url`; nil when the file is gone or unreadable.
    init?(url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        self.size = UInt64(info.st_size)
        self.mtimeSeconds = Int64(info.st_mtimespec.tv_sec)
        self.mtimeNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        self.inode = UInt64(info.st_ino)
    }

    init(size: UInt64, mtimeSeconds: Int64, mtimeNanoseconds: Int64, inode: UInt64) {
        self.size = size
        self.mtimeSeconds = mtimeSeconds
        self.mtimeNanoseconds = mtimeNanoseconds
        self.inode = inode
    }
}

/// Summed token counts of one file's messages that share a day and a
/// pricing class. Tokens, not money: the cost is computed when the
/// dashboard is built, so a tariff change never forces a re-parse.
nonisolated struct UsageBucket: Codable, Hashable {
    /// Local start of the message's day; nil when it had no timestamp.
    let day: Date?
    let model: String
    let isFast: Bool
    let isLongPrompt: Bool
    var input = 0
    var output = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var cacheRead = 0

    nonisolated struct Key: Hashable {
        let day: Date?
        let model: String
        let isFast: Bool
        let isLongPrompt: Bool
    }

    var key: Key { Key(day: day, model: model, isFast: isFast, isLongPrompt: isLongPrompt) }

    init(key: Key) {
        day = key.day
        model = key.model
        isFast = key.isFast
        isLongPrompt = key.isLongPrompt
    }

    mutating func add(_ usage: MessageTokenUsage) {
        input += usage.input
        output += usage.output
        cacheWrite5m += usage.cacheWrite5m
        cacheWrite1h += usage.cacheWrite1h
        cacheRead += usage.cacheRead
    }

    mutating func addTokens(of other: UsageBucket) {
        input += other.input
        output += other.output
        cacheWrite5m += other.cacheWrite5m
        cacheWrite1h += other.cacheWrite1h
        cacheRead += other.cacheRead
    }

    var tokens: MessageTokenUsage {
        MessageTokenUsage(input: input, output: output, cacheWrite5m: cacheWrite5m,
                          cacheWrite1h: cacheWrite1h, cacheRead: cacheRead, isFast: isFast)
    }

    var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
    var totalTokens: Int { input + output + cacheWrite + cacheRead }
    var cost: Double { ModelPricingCatalog.cost(tokens, model: model, longPrompt: isLongPrompt) }
}

/// What one session file has contributed so far, plus where reading
/// stopped, so the next scan continues from there instead of starting over.
nonisolated struct FileUsageAggregate: Codable, Hashable {
    let path: String
    /// `stat` of the file when it was last read.
    var stamp: FileStamp
    let sessionID: String
    let projectPath: String
    /// Last model seen; the dashboard attributes the session to it.
    var model: String
    var firstDate: Date?
    var buckets: [UsageBucket]
    /// Offset just past the last line consumed. A half-written last line
    /// is not consumed; it is read once it is complete.
    var parsedBytes: UInt64
    /// Ids of the last messages read. Claude Code writes one line per
    /// content block, all repeating the message's usage, and those lines are
    /// adjacent, so these are enough to skip the repeats across a resume.
    var tailMessageIDs: [String]
    /// Up to 64 bytes just before `parsedBytes`: a file rewritten in place
    /// (same inode, not shorter) no longer matches and is read again.
    var tailBytes: Data
    var classificationVersion: Int
    /// Subagent file whose inherited prefix could not be told apart: no
    /// `.meta.json` yet, or a fork transcript in which the spawning message
    /// was not found. Everything was counted, and the entry is never
    /// resumed, so the next change re-reads it from the start and tries
    /// again. Optional so entries written before subagents were scanned
    /// still decode (nil means resolved).
    var subagentPrefixUnresolved: Bool?

    static let tailMessageIDLimit = 8
    static let tailByteCount: UInt64 = 64

    /// The file has the stamp it had when read, and messages were
    /// classified the current way.
    func isFresh(for current: FileStamp) -> Bool {
        stamp == current && classificationVersion == ModelPricingCatalog.classificationVersion
    }

    /// The file only grew since it was read: same inode, at least as long
    /// as what was consumed. (The tail bytes are checked by the reader.)
    func canResume(from current: FileStamp) -> Bool {
        subagentPrefixUnresolved != true
            && classificationVersion == ModelPricingCatalog.classificationVersion
            && current.inode == stamp.inode
            && current.size >= parsedBytes
    }

    var hasUsage: Bool { !buckets.isEmpty }

    /// A subagent transcript (`.../<session>/subagents/agent-*.jsonl`), not
    /// a session's own. Derived from the path, so the cached shape is the
    /// same for both kinds.
    var isSubagent: Bool {
        (path as NSString).deletingLastPathComponent.hasSuffix("/" + UsageAggregator.subagentsDirectoryName)
    }
}

nonisolated protocol UsageFileCaching {
    func load() -> [String: FileUsageAggregate]
    func save(_ entries: [String: FileUsageAggregate]) throws
}

nonisolated struct UsageFileCache: UsageFileCaching {
    /// Bump whenever the on-disk shape changes. 1 was the bare array with
    /// ISO8601 `mtime`; 2 the envelope with `FileStamp`; 3 stores tokens per
    /// pricing class and the resume position instead of money. Subagent
    /// files did not need a 4: they only add an optional field, so the
    /// main-transcript entries of a v3 file stay valid and only the
    /// subagent files are read cold once.
    static let formatVersion = 3

    let cacheURL: URL

    init(cacheURL: URL? = nil) {
        self.cacheURL = cacheURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".xylem/usage-files-cache.json")
    }

    private struct Envelope: Codable {
        let version: Int
        let entries: [FileUsageAggregate]
    }

    func load() -> [String: FileUsageAggregate] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [:] }
        let decoder = JSONDecoder()
        // Seconds since 1970 as a Double round-trips exactly, unlike
        // `.iso8601`, which silently truncated `firstDate` to whole seconds.
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let envelope = try? decoder.decode(Envelope.self, from: data),
              envelope.version == Self.formatVersion
        else { return [:] }
        var map: [String: FileUsageAggregate] = [:]
        for entry in envelope.entries { map[entry.path] = entry }
        return map
    }

    func save(_ entries: [String: FileUsageAggregate]) throws {
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let list = Array(entries.values).sorted { $0.path < $1.path }
        let data = try encoder.encode(Envelope(version: Self.formatVersion, entries: list))
        try data.write(to: cacheURL, options: .atomic)
    }
}
