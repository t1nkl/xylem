//
//  EffortChoiceTests.swift
//  XylemTests
//
//  The toolbar's effort menu: the level comes from the transcript (every
//  assistant line carries `effort`), a pick shows until a reply to a later
//  prompt confirms it.
//

import Testing
import Foundation

struct EffortChoiceTests {

    private func writeSession(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "xylem-effort-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func user(_ time: String, _ text: String = "hi") -> String {
        #"{"type":"user","timestamp":"2026-11-19T\#(time).000Z","message":{"role":"user","content":"\#(text)"}}"#
    }

    private func assistant(_ id: String, _ time: String, effort: String?) -> String {
        let field = effort.map { #","effort":"\#($0)","perTurnEffort":"\#($0)""# } ?? ""
        return #"{"type":"assistant","timestamp":"2026-11-19T\#(time).000Z"\#(field),"message":{"id":"\#(id)","model":"claude-sonnet-5-5","usage":{"input_tokens":10,"output_tokens":5}}}"#
    }

    @Test func transcriptGivesTheNewestReplysEffort() throws {
        let url = try writeSession([
            user("10:00:00"), assistant("a", "10:00:01", effort: "low"),
            user("10:01:00"), assistant("b", "10:01:01", effort: "high")
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let stats = try #require(SessionStatsReader().readStats(from: url))
        #expect(stats.effort == "high")
        #expect(ModelSwitchController.displayedEffort(pick: nil, stats: stats)?.title == "High")
    }

    @Test func olderTranscriptsWithoutEffortShowNothing() throws {
        let url = try writeSession([user("10:00:00"), assistant("a", "10:00:01", effort: nil)])
        defer { try? FileManager.default.removeItem(at: url) }
        let stats = try #require(SessionStatsReader().readStats(from: url))
        #expect(stats.effort == nil)
        #expect(ModelSwitchController.displayedEffort(pick: nil, stats: stats) == nil)
    }

    @Test func pickShowsUntilAReplyToALaterPrompt() throws {
        let url = try writeSession([user("10:00:00"), assistant("a", "10:00:05", effort: "medium")])
        defer { try? FileManager.default.removeItem(at: url) }
        let high = try #require(ClaudeEffortChoice.matching(level: "high"))
        let pick = ModelSwitchController.EffortPick(choice: high, at: try #require(TimestampParser.parse("2026-11-19T10:00:10.000Z")))

        // Typed mid-turn: replies still streaming carry the old level.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + assistant("b", "10:00:20", effort: "medium")).utf8))
        let midTurn = try #require(SessionStatsReader().readStats(from: url))
        #expect(ModelSwitchController.displayedEffort(pick: pick, stats: midTurn) == high)

        // The next prompt's reply confirms it; from then on the transcript
        // decides (Claude Code capped it at medium here).
        try handle.write(contentsOf: Data(("\n" + user("10:01:00") + "\n" + assistant("c", "10:01:05", effort: "medium")).utf8))
        try handle.close()
        let answered = try #require(SessionStatsReader().readStats(from: url))
        #expect(ModelSwitchController.displayedEffort(pick: pick, stats: answered)?.level == "medium")
    }

    @Test func levelsAreTheSlidersStops() {
        #expect(ClaudeEffortChoice.levels.map(\.level) == ["low", "medium", "high", "xhigh", "max"])
        #expect(ClaudeEffortChoice.matching(level: "XHIGH")?.title == "Extra High")
        #expect(ClaudeEffortChoice.matching(level: "auto") == nil)
        #expect(ClaudeEffortChoice.matching(level: nil) == nil)
    }

    /// Screen text as SwiftTerm's rows give it (Claude Code 2.1.328).
    @Test func pickerIsRecognisedOnScreen() {
        let open = """
         Effort                                   Faster          Smarter
         ──────────▲───────────────────────────────
           low     medium    high    xhigh    max
         The default effort for this model
         ←/→ to adjust · s to use this session only · Enter to save · Esc to
         cancel
        """
        #expect(EffortPicker.isOpen(onScreen: open))
        #expect(!EffortPicker.isOpen(onScreen: "❯ /effort\n  ⎿  Set effort level to low (this session only): Quick"))
    }

    @Test func slidersStopsComeFromItsLabelRow() {
        #expect(EffortPicker.stops(onScreen: "Effort\n   low     medium    high    xhigh    max\n") == ["low", "medium", "high", "xhigh", "max"])
        #expect(EffortPicker.stops(onScreen: "  low   medium   high\n") == ["low", "medium", "high"])
        #expect(EffortPicker.stops(onScreen: "lowmediumhighxhighmaxTabtoggle") == ["low", "medium", "high", "xhigh", "max"])
        #expect(EffortPicker.stops(onScreen: "Set effort level to low (this session only)") == nil)
    }

    @Test func confirmationsAreListedInScreenOrder() {
        let screen = """
        ❯ /effort
          ⎿  Set effort level to low (this session only): Quick, straightforward
        ❯ /effort
          ⎿  Set effort level to max (this session
             only): Maximum capability with deepest reasoning.
        ❯ /effort high
          ⎿  Set effort level to high (saved as your default for new sessions)
        """
        #expect(EffortPicker.confirmations(onScreen: screen) == ["low", "max"])
        #expect(EffortPicker.confirmations(onScreen: "nothing here").isEmpty)
    }

    @Test func stashedDraftIsSeenOnScreen() {
        #expect(ClaudePromptDraft.isStashed(onScreen: "  ◐ medium · /effort · draft stashed\n"))
        #expect(ClaudePromptDraft.isStashed(onScreen: "· draft\nstashed"))
        #expect(!ClaudePromptDraft.isStashed(onScreen: "❯ my draft\n  draft restored"))
    }
}
