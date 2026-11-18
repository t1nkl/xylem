//
//  PromptHistoryIndex.swift
//  Xylem
//
//  Every prompt the human typed in every main Claude Code session
//  (`~/.claude/projects/*/*.jsonl`, not `subagents/`), so the ⌘K palette
//  can answer "where did I ask to do X?" and resume that session.
//
//  The transcripts are ~3 GB on a heavy machine, single files up to 250 MB,
//  so the index is built the way UsageAggregator reads usage:
//    · per file a `FileStamp` (size + nanosecond mtime + inode) and the
//      offset just past the last line consumed;
//    · an unchanged file is skipped, a file that only grew (same inode, not
//      shorter, same bytes just before the stored offset) is read from that
//      offset, anything else is read from the start;
//    · a line is JSON-decoded only if its raw bytes contain `"type":"user"`
//      and none of the markers of records UserPromptExtractor rejects
//      anyway (tool results, `isMeta`). Most bytes are assistant output and
//      tool results, which are never decoded.
//  What counts as a human prompt is UserPromptExtractor's rule, not ours.
//
//  The result is persisted to `~/.xylem/prompt-index.json` so the palette
//  has results right after a relaunch; the folded search keys are rebuilt
//  in memory (PromptHistorySnapshot), not stored.
//

import Foundation

/// One human prompt as stored in the index.
nonisolated struct PromptHistoryPrompt: Codable, Hashable, Sendable {
    /// Record uuid: a forked or copied session repeats the prompt with the
    /// same uuid, and the snapshot shows it once.
    let uuid: String?
    /// Whitespace collapsed to single spaces, capped at
    /// `PromptHistoryIndexer.promptCharacterLimit`.
    let text: String
    /// Seconds since 1970; nil when the record had no timestamp.
    let time: Double?
}

/// What one transcript has contributed, plus where reading stopped.
nonisolated struct PromptHistoryFileRecord: Codable, Hashable, Sendable {
    let path: String
    /// `stat` of the file taken before it was last read.
    var stamp: FileStamp
    /// The file name, which is what tabs bind to (`claude --resume <id>`).
    let sessionID: String
    /// Directory Claude Code runs this session in - the project folder's
    /// cwd, not a line's `cwd` (that one follows `cd` into subfolders, and
    /// `--resume` from there would not find the transcript).
    let projectPath: String
    var parsedBytes: UInt64
    /// Up to 64 bytes just before `parsedBytes`; a file rewritten in place
    /// no longer matches them and is read again from the start.
    var tailBytes: Data
    var prompts: [PromptHistoryPrompt]

    static let tailByteCount: UInt64 = 64

    func canResume(from current: FileStamp) -> Bool {
        current.inode == stamp.inode && current.size >= parsedBytes
    }
}

nonisolated protocol PromptHistoryStoring: Sendable {
    func load() -> [String: PromptHistoryFileRecord]
    func save(_ records: [String: PromptHistoryFileRecord]) throws
}

nonisolated struct PromptHistoryStore: PromptHistoryStoring {
    /// Bump when the on-disk shape changes.
    static let formatVersion = 1
    /// Bump when the rule for "human prompt" changes (UserPromptExtractor,
    /// the byte pre-filter, the text cap): every file is read again once.
    /// 1 already excluded compaction summaries; 2 raised the text cap;
    /// 3 dropped agent-team messages (`<teammate-message>`).
    static let rulesVersion = 3

    let url: URL

    init(url: URL? = nil) {
        self.url = url
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".xylem/prompt-index.json")
    }

    private struct Envelope: Codable {
        let version: Int
        let rules: Int
        let files: [PromptHistoryFileRecord]
    }

    func load() -> [String: PromptHistoryFileRecord] {
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == Self.formatVersion,
              envelope.rules == Self.rulesVersion
        else { return [:] }
        var map: [String: PromptHistoryFileRecord] = [:]
        for file in envelope.files { map[file.path] = file }
        return map
    }

    /// Owner-only (0600), like Claude Code's own transcripts: the index is a
    /// copy of everything the user typed, pasted secrets included, and the
    /// default umask would leave it readable by every local account. Written
    /// to a 0600 temp file and renamed over the old one, so it is never
    /// readable by others, not even for a moment, and never half-written.
    func save(_ records: [String: PromptHistoryFileRecord]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = records.values.sorted { $0.path < $1.path }
        let envelope = Envelope(version: Self.formatVersion, rules: Self.rulesVersion, files: files)
        let data = try JSONEncoder().encode(envelope)
        let temp = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: data,
                                             attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        guard rename(temp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

nonisolated struct PromptHistoryIndexer: Sendable {
    /// Long pasted prompts are cut: the palette shows one or two lines, and
    /// a 100 KB log pasted into a prompt would bloat the index and match
    /// almost any query. Matches past this point are not found. Measured on
    /// 4333 real prompts: 4000 cuts 6% of them (1000 cut 11%), index 2.8 MB
    /// instead of 1.8 MB, worst-case search still ~3 ms.
    static let promptCharacterLimit = 4000

    /// Injected in tests; otherwise the Claude config folder's, read per
    /// use so a changed CLAUDE_CONFIG_DIR applies without a relaunch.
    private let projectsOverride: URL?
    var projectsDirectory: URL { projectsOverride ?? SessionFileLocator.defaultProjectsDirectory }
    let store: any PromptHistoryStoring

    init(projectsDirectory: URL? = nil, store: any PromptHistoryStoring = PromptHistoryStore()) {
        self.projectsOverride = projectsDirectory
        self.store = store
    }

    /// The index as last saved; empty when there is none (or it is stale).
    func loadStored() -> [String: PromptHistoryFileRecord] {
        store.load()
    }

    /// Result of `update`. `changed`: something must be saved (a stamp or
    /// offset moved). `promptsChanged`: what search sees differs - a live
    /// session moves its stamp on every reply, but only a new prompt (or a
    /// transcript added / removed) needs a new snapshot.
    struct Update {
        let records: [String: PromptHistoryFileRecord]
        let changed: Bool
        let promptsChanged: Bool
    }

    /// Brings `records` up to date with the transcripts on disk and saves
    /// the result when anything changed. Synchronous and blocking: callers
    /// run it off the main actor.
    func update(_ records: [String: PromptHistoryFileRecord]) -> Update {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return Update(records: records, changed: false, promptsChanged: false) }

        var records = records
        var seen = Set<String>()
        var changed = false
        var promptsChanged = false

        for folder in folders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            else { continue }
            // Resolved lazily: a folder whose files are all fresh costs no read.
            var projectPath: String?

            for file in files where file.pathExtension == "jsonl" {
                let path = file.path
                seen.insert(path)
                // Stamp taken *before* reading: a write that lands meanwhile
                // changes the stamp, and the next update continues from
                // `parsedBytes`.
                guard let stamp = FileStamp(url: file) else { continue }
                let existing = records[path]
                if existing?.stamp == stamp { continue }

                let resumable = existing.flatMap { record in
                    record.canResume(from: stamp)
                        && Self.tailBytes(of: file, endingAt: record.parsedBytes) == record.tailBytes
                        ? record : nil
                }
                if projectPath == nil { projectPath = ClaudeProjectPathResolver.resolve(folder: folder) }
                guard let record = Self.read(file, projectPath: projectPath ?? "", stamp: stamp, resuming: resumable)
                else { continue }  // unreadable right now: keep what was indexed
                if record != existing {
                    if existing == nil || record.prompts != existing?.prompts { promptsChanged = true }
                    records[path] = record
                    changed = true
                }
            }
        }

        for path in records.keys where !seen.contains(path) {
            records.removeValue(forKey: path)
            changed = true
            promptsChanged = true
        }
        if changed { try? store.save(records) }
        return Update(records: records, changed: changed, promptsChanged: promptsChanged)
    }

    // MARK: - Reading one transcript

    private static func read(
        _ file: URL,
        projectPath: String,
        stamp: FileStamp,
        resuming: PromptHistoryFileRecord?
    ) -> PromptHistoryFileRecord? {
        var prompts = resuming?.prompts ?? []
        guard let end = scanCandidateLines(in: file, from: resuming?.parsedBytes ?? 0, handler: { root in
            guard let text = UserPromptExtractor.prompt(from: root) else { return }
            let time = (root["timestamp"] as? String).flatMap(TimestampParser.parse)?.timeIntervalSince1970
            prompts.append(PromptHistoryPrompt(
                uuid: root["uuid"] as? String,
                text: normalized(text),
                time: time
            ))
        }) else { return nil }

        return PromptHistoryFileRecord(
            path: file.path,
            stamp: stamp,
            sessionID: file.deletingPathExtension().lastPathComponent,
            projectPath: resuming?.projectPath ?? projectPath,
            parsedBytes: end,
            tailBytes: tailBytes(of: file, endingAt: end) ?? Data(),
            prompts: prompts
        )
    }

    /// One line, whitespace runs collapsed (so "fix\nthe build" is found by
    /// "fix the build"), capped.
    static func normalized(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard collapsed.count > promptCharacterLimit else { return collapsed }
        return String(collapsed.prefix(promptCharacterLimit))
    }

    private static func tailBytes(of file: URL, endingAt end: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let start = end >= PromptHistoryFileRecord.tailByteCount ? end - PromptHistoryFileRecord.tailByteCount : 0
        guard (try? handle.seek(toOffset: start)) != nil else { return nil }
        return (try? handle.read(upToCount: Int(end - start))) ?? Data()
    }

    // MARK: - Pre-filtered line scan

    private static let userNeedle = Array(#""type":"user""#.utf8)
    /// Records UserPromptExtractor rejects whatever else they contain. The
    /// quotes make these structural: inside a JSON string a quote is
    /// escaped (`\"`), so a prompt that merely mentions `"isMeta":true`
    /// still reaches the extractor.
    private static let rejectNeedles = [
        Array(#""type":"tool_result""#.utf8),
        Array(#""isMeta":true"#.utf8)
    ]

    /// Whether a raw line may hold a human prompt.
    static func isCandidate(_ line: UnsafeRawBufferPointer) -> Bool {
        contains(line, userNeedle) && !rejectNeedles.contains(where: { contains(line, $0) })
    }

    private static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard haystack.count >= needle.count, let base = haystack.baseAddress else { return false }
        return needle.withUnsafeBytes { memmem(base, haystack.count, $0.baseAddress, $0.count) != nil }
    }

    /// Reads `url` from `offset` in 1 MB chunks, splits lines with `memchr`
    /// and JSON-decodes only candidate lines. Returns the offset just past
    /// the last line consumed, or nil if the file can't be read.
    ///
    /// A last line without `\n` is consumed only when it is a candidate
    /// and complete JSON; otherwise it is left for the next update (Claude
    /// Code terminates every record with `\n`, so it is a line being
    /// written).
    @discardableResult
    static func scanCandidateLines(
        in url: URL,
        from offset: UInt64 = 0,
        handler: ([String: Any]) -> Void
    ) -> UInt64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }

        let chunkSize = 1024 * 1024
        var buffer = Data()
        /// Absolute file offset of `buffer[0]`.
        var bufferStart = offset
        /// Bytes at the start of `buffer` already searched for `\n`.
        var searched = 0
        var candidates: [Data] = []

        while let chunk = (try? handle.read(upToCount: chunkSize)) ?? nil, !chunk.isEmpty {
            buffer.append(chunk)
            var lineStart = 0
            buffer.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var position = searched
                while position < raw.count,
                      let hit = memchr(base + position, Int32(UInt8(ascii: "\n")), raw.count - position) {
                    let newline = base.distance(to: UnsafeRawPointer(hit))
                    let line = UnsafeRawBufferPointer(rebasing: raw[lineStart..<newline])
                    if isCandidate(line) { candidates.append(Data(line)) }
                    lineStart = newline + 1
                    position = lineStart
                }
            }
            for line in candidates { decode(line).map(handler) }
            candidates.removeAll(keepingCapacity: true)
            if lineStart > 0 {
                bufferStart += UInt64(lineStart)
                buffer = lineStart < buffer.count ? Data(buffer[lineStart...]) : Data()
            }
            searched = buffer.count
        }

        guard !buffer.isEmpty else { return bufferStart }
        let isCompleteCandidate = buffer.withUnsafeBytes { isCandidate($0) }
        guard isCompleteCandidate, let object = decode(buffer) else { return bufferStart }
        handler(object)
        return bufferStart + UInt64(buffer.count)
    }

    private static func decode(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }
}
