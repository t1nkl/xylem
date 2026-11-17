//
//  SessionStatsReaderTests.swift
//  XylemTests
//
//  Claude Code writes one jsonl line per content block, and every line of a
//  message repeats that message's usage. The reader must count each message
//  id once, or tokens and cost come out roughly doubled.
//

import Testing
import Foundation

struct SessionStatsReaderTests {

    private func writeSession(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "xylem-stats-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func assistantLine(id: String, input: Int, output: Int) -> String {
        #"{"type":"assistant","timestamp":"2026-11-13T10:00:00.000Z","message":{"id":"\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}}"#
    }

    @Test func repeatedLinesOfOneMessageAreCountedOnce() throws {
        let url = try writeSession([
            assistantLine(id: "msg_a", input: 1_000_000, output: 0),
            assistantLine(id: "msg_a", input: 1_000_000, output: 0),
            assistantLine(id: "msg_b", input: 0, output: 1_000_000)
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let stats = try #require(SessionStatsReader().readStats(from: url))
        #expect(stats.tokens == 2_000_000)
        #expect(abs(stats.costUSD - 24) < 1e-9)
        #expect(stats.model == "Opus 5.5")
        #expect(stats.contextLimit == 1_000_000)
    }
}
