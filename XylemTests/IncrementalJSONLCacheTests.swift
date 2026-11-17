//
//  IncrementalJSONLCacheTests.swift
//  XylemTests
//
//  Session readers fold only the bytes appended since their previous read.
//  These tests grow, cut and replace a file between reads and check the
//  result matches what a reader would produce from scratch.
//

import Testing
import Foundation

struct IncrementalJSONLCacheTests {

    private func makeFile(_ text: String = "") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "xylem-incremental-\(UUID().uuidString).jsonl")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func assistantLine(id: String, input: Int, output: Int, at time: String = "10:00:00") -> String {
        #"{"type":"assistant","timestamp":"2026-11-13T\#(time).000Z","message":{"id":"\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}}"#
    }

    private func userLine(_ text: String) -> String {
        #"{"type":"user","message":{"role":"user","content":"\#(text)"}}"#
    }

    @Test func appendedLinesAreAddedAndRepeatedMessageIDsStillCountOnce() throws {
        let url = try makeFile(assistantLine(id: "msg_a", input: 1_000_000, output: 0) + "\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try #require(SessionStatsReader().readStats(from: url))
        #expect(first.tokens == 1_000_000)

        // Second content block of msg_a (must not be counted again) plus a
        // new message, appended after the first read.
        try append(
            assistantLine(id: "msg_a", input: 1_000_000, output: 0, at: "10:00:30") + "\n"
                + assistantLine(id: "msg_b", input: 0, output: 1_000_000, at: "10:01:00") + "\n",
            to: url
        )
        let second = try #require(SessionStatsReader().readStats(from: url))
        #expect(second.tokens == 2_000_000)
        #expect(abs(second.costUSD - 24) < 1e-9)
        #expect(second.duration == 60)
    }

    @Test func halfWrittenLineIsPickedUpOnceComplete() throws {
        let url = try makeFile(userLine("first") + "\n" + #"{"type":"user","message":{"content":"sec"#)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(LastPromptReader.read(from: url) == "first")
        try append(#"ond"}}"# + "\n", to: url)
        #expect(LastPromptReader.read(from: url) == "second")
    }

    @Test func truncatedFileIsReadFromScratch() throws {
        let url = try makeFile(userLine("one") + "\n" + userLine("two") + "\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(LastPromptReader.read(from: url) == "two")

        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.close()
        try append(userLine("three") + "\n", to: url)
        #expect(LastPromptReader.read(from: url) == "three")
    }

    @Test func replacedFileIsReadFromScratch() throws {
        let url = try makeFile(assistantLine(id: "msg_a", input: 10, output: 0) + "\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(SessionStatsReader().readStats(from: url)?.tokens == 10)

        // Atomic replace: same path, new inode, longer than the old file.
        let replacement = assistantLine(id: "msg_x", input: 7, output: 0) + "\n"
            + assistantLine(id: "msg_y", input: 5, output: 0) + "\n"
        try Data(replacement.utf8).write(to: url, options: .atomic)
        #expect(SessionStatsReader().readStats(from: url)?.tokens == 12)
    }

    @Test func evictsTheLeastRecentlyUsedFile() throws {
        let cache = IncrementalJSONLCache<IdentityState>(capacity: 2)
        let a = try makeFile(userLine("a") + "\n")
        let b = try makeFile(userLine("b") + "\n")
        let c = try makeFile(userLine("c") + "\n")
        defer { for url in [a, b, c] { try? FileManager.default.removeItem(at: url) } }

        let aID = try #require(cache.withState(for: a) { $0.id })
        let bID = try #require(cache.withState(for: b) { $0.id })
        _ = cache.withState(for: a) { $0.id }      // a is now the most recent
        _ = cache.withState(for: c) { $0.id }      // full: must push out b, not a

        #expect(cache.withState(for: a) { $0.id } == aID)
        #expect(cache.withState(for: b) { $0.id } != bID)
    }
}

/// Fold state whose identity shows whether the cache kept or rebuilt it.
nonisolated private struct IdentityState: JSONLFoldState {
    let id = UUID()
    init() {}
    mutating func consume(_ object: [String: Any]) {}
}
