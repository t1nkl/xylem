//
//  UsageAggregator.swift
//  Xylem
//
//  Scans all Claude Code session jsonl files and produces a UsageDataset
//  for every date range in one pass.
//
//  Subagent transcripts (`<session id>/subagents/agent-*.jsonl`) are read
//  too and folded into their parent session: they were ~40% of all
//  transcript bytes on a heavy machine, and leaving them out undercounted
//  spend accordingly. Forks start with a copy of their parent's messages,
//  which is skipped (SubagentTranscript.swift).
//
//  Incremental, backed by UsageFileCache:
//    · a file whose `FileStamp` (size + nanosecond mtime + inode) is
//      unchanged reuses its cached aggregate;
//    · a file that only grew (same inode, not shorter, same bytes just
//      before where reading stopped) is read from that offset on, and the
//      new messages are added to the cached counts;
//    · anything else (new, truncated, rewritten) is read from the start.
//  The cache holds token counts per day and pricing class, never money, so
//  costs come from the current tariff table every time and a tariff change
//  never forces a re-read.
//
//  Only lines containing the bytes `"usage"` are handed to
//  JSONSerialization: most of a transcript is prompts, tool results and
//  attachments that never carry usage.
//

import Foundation

nonisolated protocol UsageAggregating {
    /// One scan, every range.
    func aggregateAll() async -> [UsageDateRange: UsageDataset]
}

nonisolated struct UsageAggregator: UsageAggregating {
    /// Injected in tests; otherwise the Claude config folder's, read per
    /// use so a changed CLAUDE_CONFIG_DIR applies without a relaunch.
    private let projectsOverride: URL?
    var projectsDirectory: URL { projectsOverride ?? SessionFileLocator.defaultProjectsDirectory }
    let fileCache: UsageFileCaching

    init(
        projectsDirectory: URL? = nil,
        fileCache: UsageFileCaching = UsageFileCache()
    ) {
        self.projectsOverride = projectsDirectory
        self.fileCache = fileCache
    }

    func aggregateAll() async -> [UsageDateRange: UsageDataset] {
        await Self.scan(root: projectsDirectory, cache: UncheckedSendable(fileCache))
    }

    func aggregate(in range: UsageDateRange) async -> UsageDataset {
        await aggregateAll()[range] ?? UsageDataset()
    }

    /// Whole-tree scan; `@concurrent` so it never runs on the main actor.
    @concurrent
    private static func scan(
        root: URL,
        cache: UncheckedSendable<UsageFileCaching>
    ) async -> [UsageDateRange: UsageDataset] {
        let files = parseAll(in: root, cache: cache.value)
        var result: [UsageDateRange: UsageDataset] = [:]
        for range in UsageDateRange.allCases {
            result[range] = combine(files: files, cutoff: range.cutoff)
        }
        return result
    }

    // MARK: - Per-file parsing

    /// `<project>/<session id>/subagents/` holds the session's subagent
    /// transcripts.
    static let subagentsDirectoryName = "subagents"

    private static func parseAll(in projectsDirectory: URL, cache: UsageFileCaching) -> [FileUsageAggregate] {
        let fm = FileManager.default
        guard let projectFolders = try? fm.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var cached = cache.load()
        var seen = Set<String>()
        var output: [FileUsageAggregate] = []
        var changed = false

        func visit(_ file: URL, sessionID: String, projectPath: String, isSubagent: Bool) {
            let path = file.path
            seen.insert(path)
            switch refresh(file, existing: cached[path], sessionID: sessionID,
                           projectPath: projectPath, isSubagent: isSubagent) {
            case .missing:
                return
            case let .current(entry):
                if entry.hasUsage { output.append(entry) }
            case let .read(entry):
                // Files without usage are cached too, so they are not read
                // again until they change.
                cached[path] = entry
                changed = true
                if entry.hasUsage { output.append(entry) }
            }
        }

        for projectFolder in projectFolders {
            guard
                let values = try? projectFolder.resourceValues(forKeys: [.isDirectoryKey]),
                values.isDirectory == true
            else { continue }

            let projectPath = ClaudeProjectPathResolver.resolve(folder: projectFolder)

            guard let entries = try? fm.contentsOfDirectory(
                at: projectFolder,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }

            for entry in entries {
                if entry.pathExtension == "jsonl" {
                    visit(entry, sessionID: entry.deletingPathExtension().lastPathComponent,
                          projectPath: projectPath, isSubagent: false)
                    continue
                }
                // Only `<session id>/subagents/` is listed: one failed
                // `opendir` for directories without it (`memory`, sessions
                // that never spawned an agent), no recursive walk through
                // `tool-results` and the like.
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                      let transcripts = try? fm.contentsOfDirectory(
                        at: entry.appending(path: subagentsDirectoryName, directoryHint: .isDirectory),
                        includingPropertiesForKeys: nil
                      )
                else { continue }
                for transcript in transcripts
                where transcript.pathExtension == "jsonl" && transcript.lastPathComponent.hasPrefix("agent-") {
                    visit(transcript, sessionID: entry.lastPathComponent,
                          projectPath: projectPath, isSubagent: true)
                }
            }
        }

        // Drop entries whose files no longer exist so the cache doesn't grow
        // forever.
        for path in cached.keys where !seen.contains(path) {
            cached.removeValue(forKey: path)
            changed = true
        }

        if changed { try? cache.save(cached) }
        return output
    }

    /// Result of bringing one file's aggregate up to date.
    enum FileRefresh {
        /// The file is gone or can't be `stat`-ed.
        case missing
        /// `existing` still holds: unchanged file, or unreadable right now
        /// (keep showing what was counted).
        case current(FileUsageAggregate)
        /// Read now (fully or the appended part); replaces `existing`.
        case read(FileUsageAggregate)
    }

    /// One file's step of the incremental scan, also used for a single
    /// session's subagents (SessionStatsSubagents.swift): skip the file
    /// when its stamp matches `existing`, continue from `parsedBytes` when
    /// it only grew, read it from the start otherwise.
    static func refresh(
        _ file: URL,
        existing: FileUsageAggregate?,
        sessionID: String,
        projectPath: String,
        isSubagent: Bool
    ) -> FileRefresh {
        // Stamp taken *before* reading: if the file grows meanwhile, the
        // stored stamp no longer matches and the next scan continues from
        // `parsedBytes`.
        guard let stamp = FileStamp(url: file) else { return .missing }
        if let existing, existing.isFresh(for: stamp) { return .current(existing) }

        let resumable = existing.flatMap { entry in
            entry.canResume(from: stamp) && tailMatches(entry, file: file) ? entry : nil
        }
        // The meta is read only when the transcript is (re)read, never on a
        // cache hit. Resuming means the prefix is already behind.
        let prefix: SubagentPrefix = isSubagent && resumable == nil
            ? SubagentPrefix(transcript: file)
            : .none
        guard let entry = read(
            file,
            sessionID: sessionID,
            projectPath: projectPath,
            stamp: stamp,
            resuming: resumable,
            prefix: prefix
        ) else {
            return existing.map(FileRefresh.current) ?? .missing
        }
        return .read(entry)
    }

    /// The bytes just before where the cached entry stopped are still
    /// there - the file was appended to, not rewritten.
    private static func tailMatches(_ entry: FileUsageAggregate, file: URL) -> Bool {
        tailBytes(of: file, endingAt: entry.parsedBytes) == entry.tailBytes
    }

    private static func tailBytes(of file: URL, endingAt end: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let start = end >= FileUsageAggregate.tailByteCount ? end - FileUsageAggregate.tailByteCount : 0
        guard (try? handle.seek(toOffset: start)) != nil else { return nil }
        return (try? handle.read(upToCount: Int(end - start))) ?? Data()
    }

    /// Reads `file` from the start, or - when `resuming` - only what was
    /// appended after `resuming.parsedBytes`, adding to its counts.
    ///
    /// `prefix` (subagent transcripts read from the start) says which
    /// leading messages are copies of the parent's (see
    /// SubagentTranscript.swift). They are collected aside and dropped once
    /// the spawning message shows up; if it never does, they are counted
    /// after all and the entry is marked unresolved.
    private static func read(
        _ file: URL,
        sessionID: String,
        projectPath: String,
        stamp: FileStamp,
        resuming: FileUsageAggregate?,
        prefix: SubagentPrefix = .none
    ) -> FileUsageAggregate? {
        let calendar = Calendar.current
        var model = resuming?.model ?? ""
        var firstDate = resuming?.firstDate
        var buckets: [UsageBucket.Key: UsageBucket] = [:]
        for bucket in resuming?.buckets ?? [] { buckets[bucket.key] = bucket }
        var recentIDs = resuming?.tailMessageIDs ?? []
        var countedIDs = Set(recentIDs)

        var awaitedToolUse: String?
        if case let .inheritedUntilToolUse(id) = prefix { awaitedToolUse = id }
        var inherited: [UsageBucket.Key: UsageBucket] = [:]
        var inheritedFirstDate: Date?

        func remember(_ id: String) {
            recentIDs.append(id)
            if recentIDs.count > FileUsageAggregate.tailMessageIDLimit {
                recentIDs.removeFirst(recentIDs.count - FileUsageAggregate.tailMessageIDLimit)
            }
        }

        let start = resuming?.parsedBytes ?? 0
        guard let end = scanUsageLines(in: file, from: start, handler: { root in
            guard (root["type"] as? String) == "assistant",
                  let message = root["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { return }

            let id = message["id"] as? String
            // Checked before the repeat guard: the spawning `tool_use` may
            // sit in a later content-block line of a message whose first
            // line was already seen. Its remaining lines are repeats.
            if let toolUseID = awaitedToolUse,
               SubagentPrefix.message(message, hasToolUse: toolUseID) {
                awaitedToolUse = nil
                inherited.removeAll()
                inheritedFirstDate = nil
                if let id, countedIDs.insert(id).inserted { remember(id) }
                return
            }

            // One line per content block, each repeating the message usage.
            if let id {
                guard countedIDs.insert(id).inserted else { return }
                remember(id)
            }

            let tokens = MessageTokenUsage(usage: usage)
            let messageModel = (message["model"] as? String) ?? model
            model = messageModel

            var day: Date?
            var date: Date?
            if let timestamp = root["timestamp"] as? String, let parsed = TimestampParser.parse(timestamp) {
                date = parsed
                day = calendar.startOfDay(for: parsed)
            }
            let key = UsageBucket.Key(
                day: day,
                model: messageModel,
                isFast: tokens.isFast,
                isLongPrompt: ModelPricingCatalog.isLongPrompt(tokens, model: messageModel)
            )
            if awaitedToolUse != nil {
                if inheritedFirstDate == nil { inheritedFirstDate = date }
                inherited[key, default: UsageBucket(key: key)].add(tokens)
            } else {
                if firstDate == nil { firstDate = date }
                buckets[key, default: UsageBucket(key: key)].add(tokens)
            }
        }) else { return nil }

        // The spawning message never showed up: count the would-be copy
        // rather than drop the fork's own work, and re-check on the next
        // change (from the start, since the entry won't resume).
        var unresolved = prefix == .unknown
        if awaitedToolUse != nil {
            unresolved = true
            for (key, bucket) in inherited {
                buckets[key, default: UsageBucket(key: key)].addTokens(of: bucket)
            }
            if let inheritedFirstDate, inheritedFirstDate < (firstDate ?? .distantFuture) {
                firstDate = inheritedFirstDate
            }
        }

        return FileUsageAggregate(
            path: file.path,
            stamp: stamp,
            sessionID: sessionID,
            projectPath: projectPath,
            model: model,
            firstDate: firstDate,
            buckets: buckets.values.sorted { lhs, rhs in
                (lhs.day ?? .distantPast, lhs.model, lhs.isFast ? 1 : 0, lhs.isLongPrompt ? 1 : 0)
                    < (rhs.day ?? .distantPast, rhs.model, rhs.isFast ? 1 : 0, rhs.isLongPrompt ? 1 : 0)
            },
            parsedBytes: end,
            tailMessageIDs: recentIDs,
            tailBytes: tailBytes(of: file, endingAt: end) ?? Data(),
            classificationVersion: ModelPricingCatalog.classificationVersion,
            subagentPrefixUnresolved: unresolved ? true : nil
        )
    }

    // MARK: - Pre-filtered line scan

    private static let usageNeedle = Array(#""usage""#.utf8)

    /// Line-by-line scan from byte `offset` that decodes only lines
    /// containing the bytes `"usage"`. Returns the offset just past the
    /// last line consumed, or nil if the file can't be read.
    ///
    /// 256 KB chunks, `\n`-separated, each newline search covering only
    /// newly appended bytes. A last line without `\n` is consumed only if
    /// it is complete JSON: a line still being written is left for the next
    /// scan. An escaped `\"usage\"` inside a tool result does not match
    /// (its closing quote is preceded by a backslash), and any false
    /// positive is rejected by the JSON guards in the handler.
    @discardableResult
    static func scanUsageLines(
        in url: URL,
        from offset: UInt64 = 0,
        handler: ([String: Any]) -> Void
    ) -> UInt64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }

        let chunkSize = 256 * 1024
        let newline = UInt8(ascii: "\n")
        var buffer = Data()
        /// Absolute file offset of `buffer[0]`.
        var bufferStart = offset

        func consume(_ line: Data) {
            guard containsUsageKey(line),
                  let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            else { return }
            handler(object)
        }

        while let chunk = (try? handle.read(upToCount: chunkSize)) ?? nil, !chunk.isEmpty {
            // `buffer` is always rebuilt zero-based, so offsets are indices.
            var searchFrom = buffer.count
            buffer.append(chunk)
            var lineStart = 0
            while let newlineIndex = buffer[searchFrom...].firstIndex(of: newline) {
                consume(buffer[lineStart..<newlineIndex])
                lineStart = newlineIndex + 1
                searchFrom = lineStart
            }
            if lineStart > 0 {
                bufferStart += UInt64(lineStart)
                buffer = lineStart < buffer.count ? Data(buffer[lineStart...]) : Data()
            }
        }

        guard !buffer.isEmpty else { return bufferStart }
        guard (try? JSONSerialization.jsonObject(with: buffer)) != nil else { return bufferStart }
        consume(buffer)
        return bufferStart + UInt64(buffer.count)
    }

    /// Every usage-bearing JSON object in the file, from the start.
    static func forEachUsageObject(in url: URL, handler: ([String: Any]) -> Void) {
        scanUsageLines(in: url, handler: handler)
    }

    /// `memmem` over the raw bytes; works on slices with non-zero start
    /// indices because `withUnsafeBytes` hands over just the slice.
    static func containsUsageKey(_ line: Data) -> Bool {
        guard line.count >= usageNeedle.count else { return false }
        return line.withUnsafeBytes { haystack in
            usageNeedle.withUnsafeBytes { needle in
                memmem(haystack.baseAddress, haystack.count, needle.baseAddress, needle.count) != nil
            }
        }
    }

    // MARK: - Combine into dataset

    /// A session's own transcript and its subagents' transcripts share the
    /// session id (the subagents' folder name); the project is part of the
    /// key so two projects can never merge.
    private struct SessionKey: Hashable {
        let projectPath: String
        let sessionID: String
    }

    /// One session in range, summed over its transcript and its subagents.
    private struct SessionTotals {
        var tokens = 0
        var cost = 0.0
        var subagentCost = 0.0
        /// The session's own transcript was in range; its model and start
        /// win over any subagent's.
        var hasMain = false
        var model = ""
        var startedAt = Date.distantFuture
    }

    /// Sessions are counted once however many files they span: a subagent
    /// transcript adds tokens and cost to its parent session, its project,
    /// its model and its days, never a session of its own. A session whose
    /// only in-range usage is a subagent's still counts once.
    ///
    /// By Model: each file's tokens go to the last model *that file* used
    /// (a session's own transcript keeps the old rule), so a Haiku `Explore`
    /// agent under an Opus session shows up under Haiku. A session counts
    /// once in every model row it contributed to, so the rows' session
    /// counts can add up to more than the total.
    static func combine(files: [FileUsageAggregate], cutoff: Date?) -> UsageDataset {
        var totals = UsageTotals()
        var modelBuckets: [String: (sessions: Set<SessionKey>, input: Int, output: Int, cw: Int, cr: Int, cost: Double, estimated: Bool)] = [:]
        // Few distinct models across thousands of buckets: ask once per id.
        var listedPrice: [String: Bool] = [:]
        var projectBuckets: [String: (sessions: Set<SessionKey>, tokens: Int, cost: Double)] = [:]
        var sessions: [SessionKey: SessionTotals] = [:]
        var dayBuckets: [Date: (cost: Double, tokens: Int)] = [:]

        for file in files {
            // Day granularity: a multi-day session counts only its days in
            // range. Undated messages count toward "all time" only.
            let inRange: [UsageBucket]
            if let cutoff {
                inRange = file.buckets.filter { ($0.day ?? .distantPast) >= cutoff }
            } else {
                inRange = file.buckets
            }
            guard !inRange.isEmpty else { continue }

            var sumInput = 0, sumOutput = 0, sumCW = 0, sumCR = 0
            var sumCost = 0.0
            var estimatedCost = 0.0
            for bucket in inRange {
                let cost = bucket.cost
                if cost > 0 {
                    let listed = listedPrice[bucket.model] ?? ModelPricingCatalog.hasListedPrice(bucket.model)
                    listedPrice[bucket.model] = listed
                    if !listed { estimatedCost += cost }
                }
                sumInput += bucket.input
                sumOutput += bucket.output
                sumCW += bucket.cacheWrite
                sumCR += bucket.cacheRead
                sumCost += cost
                if let day = bucket.day {
                    var d = dayBuckets[day] ?? (0, 0)
                    d.cost += cost
                    d.tokens += bucket.totalTokens
                    dayBuckets[day] = d
                }
            }
            let tokens = sumInput + sumOutput + sumCW + sumCR

            let sessionKey = SessionKey(projectPath: file.projectPath, sessionID: file.sessionID)

            totals.totalCostUSD += sumCost
            totals.totalTokens += tokens
            if file.isSubagent { totals.subagentCostUSD += sumCost }
            totals.estimatedCostUSD += estimatedCost

            // The file's tokens go to the last model it used.
            let modelKey = file.model.isEmpty ? "unknown" : file.model
            var m = modelBuckets[modelKey] ?? ([], 0, 0, 0, 0, 0, false)
            m.sessions.insert(sessionKey)
            m.input += sumInput
            m.output += sumOutput
            m.cw += sumCW
            m.cr += sumCR
            m.cost += sumCost
            if estimatedCost > 0 { m.estimated = true }
            modelBuckets[modelKey] = m

            var p = projectBuckets[file.projectPath] ?? ([], 0, 0)
            p.sessions.insert(sessionKey)
            p.tokens += tokens
            p.cost += sumCost
            projectBuckets[file.projectPath] = p

            var session = sessions[sessionKey] ?? SessionTotals()
            session.tokens += tokens
            session.cost += sumCost
            let startedAt = file.firstDate ?? inRange.compactMap(\.day).min() ?? .distantPast
            if file.isSubagent {
                session.subagentCost += sumCost
                if !session.hasMain {
                    if session.model.isEmpty { session.model = file.model }
                    session.startedAt = min(session.startedAt, startedAt)
                }
            } else {
                session.hasMain = true
                session.model = file.model
                session.startedAt = startedAt
            }
            sessions[sessionKey] = session
        }

        totals.sessionCount = sessions.count

        let byModel = modelBuckets.map { key, value in
            ModelUsage(
                model: key,
                sessionCount: value.sessions.count,
                inputTokens: value.input,
                outputTokens: value.output,
                cacheWriteTokens: value.cw,
                cacheReadTokens: value.cr,
                totalCostUSD: value.cost,
                hasEstimatedCost: value.estimated ? true : nil
            )
        }.sorted { $0.totalCostUSD > $1.totalCostUSD }

        let byProject = projectBuckets.map { key, value in
            ProjectUsage(
                projectPath: key,
                sessionCount: value.sessions.count,
                totalTokens: value.tokens,
                totalCostUSD: value.cost
            )
        }.sorted { $0.totalCostUSD > $1.totalCostUSD }

        let bySession = sessions.map { key, value in
            SessionUsage(
                id: key.sessionID,
                projectPath: key.projectPath,
                model: value.model,
                totalTokens: value.tokens,
                totalCostUSD: value.cost,
                startedAt: value.startedAt,
                subagentCostUSD: value.subagentCost > 0 ? value.subagentCost : nil
            )
        }
        // Id breaks ties: dictionary order differs run to run, and an equal
        // dataset must compare equal so the view model doesn't re-render.
        .sorted { ($0.startedAt, $0.id) > ($1.startedAt, $1.id) }

        let timeline = dayBuckets.map { DailyUsage(day: $0.key, costUSD: $0.value.cost, tokens: $0.value.tokens) }
            .sorted { $0.day < $1.day }

        return UsageDataset(
            totals: totals,
            byModel: byModel,
            byProject: byProject,
            bySession: bySession,
            timeline: timeline
        )
    }
}
