//
//  UsageFileCacheTests.swift
//  XylemTests
//
//  The per-file usage cache must actually hit. The first version stored
//  `mtime` as an ISO8601 Date (whole seconds) and compared it with `==`
//  against APFS nanosecond mtimes, so every entry missed and every refresh
//  re-parsed every jsonl. These tests use real temp files whose mtime has
//  a fractional part - a whole-second mtime would hide the bug.
//
//  Also covers the `"usage"` byte pre-filter in UsageAggregator's line scan.
//

import Testing
import Foundation

struct UsageFileCacheTests {

    private static let fractionalMtime = Date(timeIntervalSince1970: 1_700_000_000.123456)

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "xylem-usage-\(UUID().uuidString)-\(name)")
    }

    private func setFractionalMtime(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Self.fractionalMtime],
            ofItemAtPath: url.path
        )
    }

    private func assistantLine(id: String, input: Int, output: Int) -> String {
        #"{"type":"assistant","cwd":"/tmp/proj","timestamp":"2026-11-13T10:00:00.000Z","message":{"id":"\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}}"#
    }

    /// A cached entry whose single bucket holds `input` input tokens.
    private func aggregate(stamp: FileStamp, path: String, input: Int = 1) -> FileUsageAggregate {
        var bucket = UsageBucket(key: .init(
            day: Date(timeIntervalSince1970: 1_762_992_000),
            model: "claude-opus-5-5", isFast: false, isLongPrompt: false
        ))
        bucket.add(MessageTokenUsage(input: input, output: 1))
        return FileUsageAggregate(
            path: path,
            stamp: stamp,
            sessionID: "s",
            projectPath: "/tmp/proj",
            model: "claude-opus-5-5",
            firstDate: Date(timeIntervalSince1970: 1_763_028_000.5),
            buckets: [bucket],
            parsedBytes: stamp.size,
            tailMessageIDs: ["m"],
            tailBytes: Data(),
            classificationVersion: ModelPricingCatalog.classificationVersion
        )
    }

    // MARK: - Stamp round-trip

    @Test func entryForFractionalMtimeFileIsFreshAfterSaveAndReload() throws {
        let file = tempURL("session.jsonl")
        let cacheURL = tempURL("cache.json")
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: cacheURL)
        }
        try Data((assistantLine(id: "m", input: 1, output: 1) + "\n").utf8).write(to: file)
        try setFractionalMtime(file)

        let stamp = try #require(FileStamp(url: file))
        // Guard against a vacuous pass: the fraction really is on disk.
        #expect(stamp.mtimeSeconds == 1_700_000_000)
        #expect(stamp.mtimeNanoseconds != 0)

        let cache = UsageFileCache(cacheURL: cacheURL)
        try cache.save([file.path: aggregate(stamp: stamp, path: file.path)])

        let reloaded = UsageFileCache(cacheURL: cacheURL).load()
        let entry = try #require(reloaded[file.path])
        let current = try #require(FileStamp(url: file))
        #expect(entry.isFresh(for: current))
        #expect(entry.firstDate == Date(timeIntervalSince1970: 1_763_028_000.5))
    }

    @Test func appendingToFileMakesEntryStale() throws {
        let file = tempURL("session.jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("{}\n".utf8).write(to: file)
        try setFractionalMtime(file)
        let entry = aggregate(stamp: try #require(FileStamp(url: file)), path: file.path)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{}\n".utf8))
        try handle.close()
        // Same mtime as before: the size change alone must invalidate.
        try setFractionalMtime(file)

        #expect(!entry.isFresh(for: try #require(FileStamp(url: file))))
    }

    @Test func legacyArrayFormatLoadsEmpty() throws {
        let cacheURL = tempURL("cache.json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let legacy = #"[{"path":"/x.jsonl","mtime":"2026-11-13T10:00:00Z","sessionID":"x","projectPath":"/","model":"m","input":1,"output":1,"cacheWrite":0,"cacheRead":0,"cost":1,"dayBuckets":[],"pricingVersion":4}]"#
        try Data(legacy.utf8).write(to: cacheURL)

        #expect(UsageFileCache(cacheURL: cacheURL).load().isEmpty)
    }

    // MARK: - End to end through UsageAggregator

    /// Scan once, replace the cached entry with sentinel totals under the
    /// same stamp, scan again: a cache hit returns the sentinel, a miss
    /// re-parses and returns the real numbers.
    @Test func secondScanReusesCachedEntry() async throws {
        let projects = tempURL("projects")
        let cacheURL = tempURL("cache.json")
        defer {
            try? FileManager.default.removeItem(at: projects)
            try? FileManager.default.removeItem(at: cacheURL)
        }
        let folder = projects.appending(path: "-tmp-proj", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "s.jsonl")
        try Data((assistantLine(id: "m", input: 1_000, output: 10) + "\n").utf8).write(to: file)
        try setFractionalMtime(file)

        let cache = UsageFileCache(cacheURL: cacheURL)
        let aggregator = UsageAggregator(projectsDirectory: projects, fileCache: cache)

        let first = await aggregator.aggregate(in: .allTime)
        #expect(first.totals.totalTokens == 1_010)

        // Keyed by the path `contentsOfDirectory` reports, which resolves
        // `/var` to `/private/var`, so don't look it up via `file.path`.
        var entries = cache.load()
        #expect(entries.count == 1)
        let (key, original) = try #require(entries.first)
        #expect(key.hasSuffix("/-tmp-proj/s.jsonl"))
        entries[key] = aggregate(stamp: original.stamp, path: key, input: 999_999)
        try cache.save(entries)

        let second = await aggregator.aggregate(in: .allTime)
        #expect(second.totals.totalTokens == 1_000_000)
    }

    // MARK: - Resume

    private func projectFolder() throws -> (projects: URL, file: URL, cache: URL) {
        let projects = tempURL("projects")
        let folder = projects.appending(path: "-tmp-proj", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (projects, folder.appending(path: "s.jsonl"), tempURL("cache.json"))
    }

    private func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func fullParse(_ projects: URL) async -> UsageDataset {
        let fresh = tempURL("fresh-cache.json")
        defer { try? FileManager.default.removeItem(at: fresh) }
        return await UsageAggregator(projectsDirectory: projects, fileCache: UsageFileCache(cacheURL: fresh))
            .aggregate(in: .allTime)
    }

    /// Appended lines are read from where the last scan stopped: the cached
    /// offset moves forward and the totals match a from-scratch parse -
    /// including a message whose repeated content-block lines straddle the
    /// two scans, and a half-written last line.
    @Test func appendedLinesAreReadFromTheLastOffset() async throws {
        let (projects, file, cacheURL) = try projectFolder()
        defer {
            try? FileManager.default.removeItem(at: projects)
            try? FileManager.default.removeItem(at: cacheURL)
        }
        let a = assistantLine(id: "a", input: 100, output: 1)
        let b = assistantLine(id: "b", input: 200, output: 2)
        let c = assistantLine(id: "c", input: 300, output: 3)
        // "b" is written twice (two content blocks); the scan sees the first
        // copy and half of the next line.
        try Data((a + "\n" + b + "\n" + String(b.prefix(40))).utf8).write(to: file)

        let cache = UsageFileCache(cacheURL: cacheURL)
        let aggregator = UsageAggregator(projectsDirectory: projects, fileCache: cache)
        let first = await aggregator.aggregate(in: .allTime)
        #expect(first.totals.totalTokens == 303)
        let offset = try #require(cache.load().values.first?.parsedBytes)
        #expect(offset == UInt64((a + "\n" + b + "\n").utf8.count))

        try append(String(b.dropFirst(40)) + "\n" + c + "\n", to: file)
        let second = await aggregator.aggregate(in: .allTime)
        #expect(second.totals.totalTokens == 606)
        #expect(second == (await fullParse(projects)))
        #expect(try #require(cache.load().values.first?.parsedBytes) > offset)
    }

    /// A file that got shorter, or whose bytes before the stop point
    /// changed, is read from the start instead of continued.
    @Test func truncatedOrRewrittenFileIsReadAgain() async throws {
        let (projects, file, cacheURL) = try projectFolder()
        defer {
            try? FileManager.default.removeItem(at: projects)
            try? FileManager.default.removeItem(at: cacheURL)
        }
        let aggregator = UsageAggregator(projectsDirectory: projects, fileCache: UsageFileCache(cacheURL: cacheURL))
        let a = assistantLine(id: "a", input: 100, output: 1)
        let b = assistantLine(id: "b", input: 200, output: 2)
        try Data((a + "\n" + b + "\n").utf8).write(to: file)
        _ = await aggregator.aggregate(in: .allTime)

        // Shorter: only "a" is left.
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64((a + "\n").utf8.count))
        try handle.close()
        #expect((await aggregator.aggregate(in: .allTime)).totals.totalTokens == 101)

        // Same inode, longer, but the old bytes were rewritten ("a" became
        // "x" with other numbers): continuing would keep a's stale tokens.
        let x = assistantLine(id: "x", input: 900, output: 9)
        let rewrite = try FileHandle(forWritingTo: file)
        try rewrite.seek(toOffset: 0)
        try rewrite.write(contentsOf: Data((x + "\n" + b + "\n").utf8))
        try rewrite.close()
        let result = await aggregator.aggregate(in: .allTime)
        #expect(result.totals.totalTokens == 1_111)
        #expect(result == (await fullParse(projects)))
    }

    /// Cost comes from tokens at display time: the cached entry carries no
    /// money, and its cost matches pricing the same message directly.
    @Test func costIsComputedFromCachedTokens() async throws {
        let (projects, file, cacheURL) = try projectFolder()
        defer {
            try? FileManager.default.removeItem(at: projects)
            try? FileManager.default.removeItem(at: cacheURL)
        }
        try Data((assistantLine(id: "a", input: 1_000_000, output: 100_000) + "\n").utf8).write(to: file)
        let result = await UsageAggregator(projectsDirectory: projects, fileCache: UsageFileCache(cacheURL: cacheURL))
            .aggregate(in: .allTime)
        let expected = ModelPricingCatalog.cost(MessageTokenUsage(input: 1_000_000, output: 100_000), model: "claude-opus-5-5")
        #expect(abs(result.totals.totalCostUSD - expected) < 1e-9)
    }

    // MARK: - "usage" pre-filter

    @Test func preFilterSkipsNonUsageLinesAndKeepsTrailingLine() throws {
        let file = tempURL("session.jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"no usage here"}}"#,
            #"{"type":"user","message":{"content":"tool said \"usage\": 5"}}"#,
            assistantLine(id: "a", input: 100, output: 1),
            assistantLine(id: "b", input: 200, output: 2)
        ]
        // Last line deliberately has no trailing newline.
        try Data(lines.joined(separator: "\n").utf8).write(to: file)

        var seen: [String] = []
        UsageAggregator.forEachUsageObject(in: file) { object in
            if let message = object["message"] as? [String: Any], let id = message["id"] as? String {
                seen.append(id)
            } else {
                seen.append("other")
            }
        }
        #expect(seen == ["a", "b"])
    }

    @Test func containsUsageKeyWorksOnSlicesWithNonZeroStart() {
        let data = Data(#"xxxx{"message":{"usage":{}}}"#.utf8)
        #expect(UsageAggregator.containsUsageKey(data[4...]))
        #expect(!UsageAggregator.containsUsageKey(Data(#"{"type":"user"}"#.utf8)))
        #expect(!UsageAggregator.containsUsageKey(Data(#"\"usage\""#.utf8)))
    }
}
