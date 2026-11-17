//
//  UsageSubagentTests.swift
//  XylemTests
//
//  Subagent transcripts (`<session>/subagents/agent-*.jsonl`) count toward
//  Usage, folded into their parent session: same session count, the
//  parent's project, the subagent's own model, incremental like any other
//  file. A fork starts with a copy of messages the parent already paid
//  for; that copy (up to and including the message with the spawning
//  `tool_use`) is not counted again.
//
//  Real temp directories, a temp cache file - nothing touches ~/.claude or
//  ~/.xylem.
//

import Testing
import Foundation

struct UsageSubagentTests {

    // MARK: - Fixtures

    private struct Tree {
        let projects: URL
        let folder: URL
        let cache: URL

        func session(_ id: String) -> URL { folder.appending(path: "\(id).jsonl") }

        func subagent(_ agent: String, of session: String) throws -> URL {
            let dir = folder.appending(path: "\(session)/subagents", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appending(path: "agent-\(agent).jsonl")
        }

        func aggregator() -> UsageAggregator {
            UsageAggregator(projectsDirectory: projects, fileCache: UsageFileCache(cacheURL: cache))
        }

        func remove() {
            // The folder holding both (else an empty one is left per test).
            try? FileManager.default.removeItem(at: projects.deletingLastPathComponent())
        }
    }

    private func makeTree() throws -> Tree {
        let base = FileManager.default.temporaryDirectory.appending(path: "xylem-usage-sub-\(UUID().uuidString)")
        let folder = base.appending(path: "projects/-tmp-proj", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return Tree(
            projects: base.appending(path: "projects", directoryHint: .isDirectory),
            folder: folder,
            cache: base.appending(path: "cache.json")
        )
    }

    /// One content-block line of an assistant message. `toolUse` puts a
    /// `tool_use` block with that id in the content.
    private func line(
        id: String,
        input: Int,
        output: Int,
        model: String = "claude-opus-5-5",
        daysAgo: Int = 0,
        toolUse: String? = nil
    ) -> String {
        let date = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
        let content = toolUse.map { #"[{"type":"tool_use","id":"\#($0)","name":"Agent","input":{}}]"# }
            ?? #"[{"type":"text","text":"hi"}]"#
        return #"{"type":"assistant","isSidechain":true,"timestamp":"\#(ISO8601DateFormatter().string(from: date))","message":{"id":"\#(id)","model":"\#(model)","content":\#(content),"usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}}"#
    }

    private func write(_ lines: [String], to url: URL, trailingNewline: Bool = true) throws {
        let text = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        try Data(text.utf8).write(to: url)
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func writeMeta(_ json: String, for transcript: URL) throws {
        let meta = transcript.deletingPathExtension().appendingPathExtension("meta.json")
        try Data(json.utf8).write(to: meta)
    }

    private func fullParse(_ tree: Tree) async -> [UsageDateRange: UsageDataset] {
        let fresh = FileManager.default.temporaryDirectory.appending(path: "xylem-usage-sub-fresh-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fresh) }
        return await UsageAggregator(projectsDirectory: tree.projects, fileCache: UsageFileCache(cacheURL: fresh))
            .aggregateAll()
    }

    // MARK: - Discovery and attribution

    @Test func subagentSpendIsFoldedIntoItsParentSession() async throws {
        let tree = try makeTree()
        defer { tree.remove() }
        try write([line(id: "m1", input: 1_000, output: 10)], to: tree.session("s1"))
        try write([line(id: "m2", input: 2_000, output: 20)], to: tree.session("s2"))
        let agent = try tree.subagent("a1", of: "s1")
        try write([
            line(id: "x1", input: 300, output: 3, model: "claude-haiku-4-5"),
            line(id: "x2", input: 200, output: 2, model: "claude-haiku-4-5")
        ], to: agent)
        try writeMeta(#"{"agentType":"Explore","toolUseId":"toolu_A"}"#, for: agent)
        // Other session subfolders are not transcripts of anything.
        let toolResults = tree.folder.appending(path: "s1/tool-results", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: toolResults, withIntermediateDirectories: true)
        try write([line(id: "junk", input: 9_999, output: 9)], to: toolResults.appending(path: "agent-x.jsonl"))
        let memory = tree.folder.appending(path: "memory", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)

        let result = try #require((await tree.aggregator().aggregateAll())[.allTime])

        #expect(result.totals.sessionCount == 2)
        #expect(result.totals.totalTokens == 1_010 + 2_020 + 505)
        let subagentCost = ModelPricingCatalog.cost(MessageTokenUsage(input: 500, output: 5), model: "claude-haiku-4-5")
        #expect(abs(result.totals.subagentCostUSD - subagentCost) < 1e-12)

        #expect(result.bySession.count == 2)
        let s1 = try #require(result.bySession.first { $0.id == "s1" })
        #expect(s1.totalTokens == 1_010 + 505)
        #expect(s1.model == "claude-opus-5-5")
        #expect(s1.projectPath == result.bySession.first { $0.id == "s2" }?.projectPath)
        #expect(abs((s1.subagentCostUSD ?? 0) - subagentCost) < 1e-12)
        #expect(result.bySession.first { $0.id == "s2" }?.subagentCostUSD == nil)

        #expect(result.byProject.count == 1)
        #expect(result.byProject.first?.sessionCount == 2)
        #expect(result.byProject.first?.totalTokens == 1_010 + 2_020 + 505)

        // The agent's tokens go to its own model; the session counts once
        // per model row it used.
        let haiku = try #require(result.byModel.first { $0.model == "claude-haiku-4-5" })
        #expect(haiku.inputTokens == 500 && haiku.outputTokens == 5)
        #expect(haiku.sessionCount == 1)
        let opus = try #require(result.byModel.first { $0.model == "claude-opus-5-5" })
        #expect(opus.inputTokens == 3_000)
        #expect(opus.sessionCount == 2)

        #expect(result.timeline.map(\.tokens).reduce(0, +) == result.totals.totalTokens)
        #expect(tree.aggregator().fileCache.load().values.filter(\.isSubagent).count == 1)
    }

    /// A session whose own transcript is out of range but whose subagent is
    /// in it counts once, in that range only.
    @Test func sessionWithOnlySubagentUsageInRangeCountsOnce() async throws {
        let tree = try makeTree()
        defer { tree.remove() }
        try write([line(id: "m1", input: 1_000, output: 10, daysAgo: 60)], to: tree.session("s1"))
        let agent = try tree.subagent("a1", of: "s1")
        try write([line(id: "x1", input: 300, output: 3, daysAgo: 1)], to: agent)
        try writeMeta(#"{"agentType":"general-purpose"}"#, for: agent)

        let all = await tree.aggregator().aggregateAll()
        let week = try #require(all[.last7])
        #expect(week.totals.sessionCount == 1)
        #expect(week.totals.totalTokens == 303)
        #expect(week.bySession.map(\.id) == ["s1"])
        #expect(all[.allTime]?.totals.sessionCount == 1)
        #expect(all[.allTime]?.totals.totalTokens == 1_313)
    }

    // MARK: - Incremental

    /// An appended subagent transcript is resumed from where the last scan
    /// stopped, like a session's own, and ends equal to a fresh parse.
    @Test func appendedSubagentFileIsResumed() async throws {
        let tree = try makeTree()
        defer { tree.remove() }
        try write([line(id: "m1", input: 1_000, output: 10)], to: tree.session("s1"))
        let agent = try tree.subagent("a1", of: "s1")
        try writeMeta(#"{"agentType":"general-purpose","toolUseId":"toolu_A"}"#, for: agent)
        let a = line(id: "a", input: 100, output: 1)
        let b = line(id: "b", input: 200, output: 2)
        // "b" has two content-block lines; the second is half-written.
        try Data((a + "\n" + b + "\n" + String(b.prefix(40))).utf8).write(to: agent)

        let aggregator = tree.aggregator()
        let first = try #require((await aggregator.aggregateAll())[.allTime])
        #expect(first.totals.totalTokens == 1_010 + 303)
        let entry = try #require(aggregator.fileCache.load().values.first { $0.isSubagent })
        #expect(entry.parsedBytes == UInt64((a + "\n" + b + "\n").utf8.count))
        #expect(entry.sessionID == "s1")
        #expect(entry.subagentPrefixUnresolved == nil)

        try append(String(b.dropFirst(40)) + "\n" + line(id: "c", input: 300, output: 3) + "\n", to: agent)
        let second = await aggregator.aggregateAll()
        #expect(second[.allTime]?.totals.totalTokens == 1_010 + 606)
        #expect(second[.allTime]?.totals.sessionCount == 1)
        #expect(second == (await fullParse(tree)))
        let resumed = try #require(aggregator.fileCache.load().values.first { $0.isSubagent })
        #expect(resumed.parsedBytes > entry.parsedBytes)
    }

    // MARK: - Forks

    /// A fork's leading copy (here: a parent agent's message, then the
    /// spawning message with the `tool_use` in its second content block)
    /// is skipped; the fork's own messages count. The first scan lands
    /// mid-copy, before the spawning message is written: everything seen is
    /// counted for now, and the next change re-reads the file from the
    /// start, which drops the copy.
    @Test func forkCopyOfParentMessagesIsNotCountedTwice() async throws {
        let tree = try makeTree()
        defer { tree.remove() }
        let p1 = line(id: "p1", input: 1_000, output: 10)
        let spawnText = line(id: "p2", input: 2_000, output: 20)
        let spawnToolUse = line(id: "p2", input: 2_000, output: 20, toolUse: "toolu_F")
        try write([p1, spawnText, spawnToolUse], to: tree.session("s1"))

        let fork = try tree.subagent("f1", of: "s1")
        try writeMeta(#"{"agentType":"fork","isFork":true,"toolUseId":"toolu_F"}"#, for: fork)
        let contextRef = #"{"type":"fork-context-ref","agentId":"f1","parentSessionId":"s1"}"#
        try write([contextRef, p1, spawnText], to: fork)

        let aggregator = tree.aggregator()
        let early = try #require((await aggregator.aggregateAll())[.allTime])
        #expect(early.totals.totalTokens == 3_030 + 3_030)
        #expect(aggregator.fileCache.load().values.first { $0.isSubagent }?.subagentPrefixUnresolved == true)

        let own1 = line(id: "f-own1", input: 400, output: 4)
        let own2 = line(id: "f-own2", input: 500, output: 5)
        try append([spawnToolUse, own1, own2].joined(separator: "\n") + "\n", to: fork)
        let settled = await aggregator.aggregateAll()
        let all = try #require(settled[.allTime])
        #expect(all.totals.totalTokens == 3_030 + 909)
        #expect(all.totals.sessionCount == 1)
        #expect(settled == (await fullParse(tree)))
        let entry = try #require(aggregator.fileCache.load().values.first { $0.isSubagent })
        #expect(entry.subagentPrefixUnresolved == nil)

        // Resolved: later appends resume, still without the copy.
        try append(line(id: "f-own3", input: 600, output: 6) + "\n", to: fork)
        let later = await aggregator.aggregateAll()
        #expect(later[.allTime]?.totals.totalTokens == 3_030 + 909 + 606)
        #expect(later == (await fullParse(tree)))
    }

    /// No meta file (yet): count everything, mark unresolved, and settle
    /// once the meta is there and the transcript changes.
    @Test func subagentWithoutMetaIsCountedAndRecheckedLater() async throws {
        let tree = try makeTree()
        defer { tree.remove() }
        let spawn = line(id: "p1", input: 1_000, output: 10, toolUse: "toolu_F")
        try write([spawn], to: tree.session("s1"))
        let fork = try tree.subagent("f1", of: "s1")
        try write([spawn, line(id: "own", input: 100, output: 1)], to: fork)

        let aggregator = tree.aggregator()
        #expect((await aggregator.aggregateAll())[.allTime]?.totals.totalTokens == 1_010 + 1_111)
        #expect(aggregator.fileCache.load().values.first { $0.isSubagent }?.subagentPrefixUnresolved == true)

        try writeMeta(#"{"agentType":"fork","isFork":true,"toolUseId":"toolu_F"}"#, for: fork)
        try append(line(id: "own2", input: 200, output: 2) + "\n", to: fork)
        #expect((await aggregator.aggregateAll())[.allTime]?.totals.totalTokens == 1_010 + 101 + 202)
    }

    // MARK: - All Sessions overview

    /// The overview's per-session reader sums the session's subagents with
    /// the same fork rule, and picks up appends.
    @Test func overviewReaderSumsOneSessionsSubagents() async throws {
        let tree = try makeTree()
        defer { tree.remove() }
        let spawn = line(id: "p1", input: 1_000, output: 10, toolUse: "toolu_F")
        try write([spawn], to: tree.session("s1"))
        let fork = try tree.subagent("f1", of: "s1")
        try writeMeta(#"{"agentType":"fork","isFork":true,"toolUseId":"toolu_F"}"#, for: fork)
        try write([spawn, line(id: "own", input: 100, output: 1)], to: fork)
        let plain = try tree.subagent("a2", of: "s1")
        try writeMeta(#"{"agentType":"Explore"}"#, for: plain)
        try write([line(id: "e1", input: 200, output: 2, model: "claude-haiku-4-5")], to: plain)
        // Another session's agent is not this session's.
        let other = try tree.subagent("a3", of: "s2")
        try write([line(id: "z", input: 9_000, output: 9)], to: other)

        let reader = SessionSubagentStatsReader()
        let first = reader.spend(forTranscript: tree.session("s1"))
        #expect(first.tokens == 101 + 202)
        let expectedCost = ModelPricingCatalog.cost(MessageTokenUsage(input: 100, output: 1), model: "claude-opus-5-5")
            + ModelPricingCatalog.cost(MessageTokenUsage(input: 200, output: 2), model: "claude-haiku-4-5")
        #expect(abs(first.costUSD - expectedCost) < 1e-12)
        #expect(first.newestModification != nil)
        #expect(reader.newestModification(forTranscript: tree.session("s1")) == first.newestModification)

        try append(line(id: "own2", input: 300, output: 3) + "\n", to: fork)
        #expect(reader.spend(forTranscript: tree.session("s1")).tokens == 101 + 202 + 303)

        #expect(reader.spend(forTranscript: tree.session("s3")) == SubagentSpend())
    }

    @Test func prefixRuleReadsTheMeta() {
        #expect(SubagentPrefix(meta: ["agentType": "Explore", "toolUseId": "t"]) == .none)
        #expect(SubagentPrefix(meta: ["isFork": true, "toolUseId": "t"]) == .inheritedUntilToolUse("t"))
        #expect(SubagentPrefix(meta: ["isFork": true]) == .unknown)
        let missing = FileManager.default.temporaryDirectory.appending(path: "nope-\(UUID().uuidString)/agent-x.jsonl")
        #expect(SubagentPrefix(transcript: missing) == .unknown)
    }
}
