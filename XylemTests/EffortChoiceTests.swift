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
        #expect(EffortPicker.offersSessionKey(onScreen: open))
        // Claude Code 2.1.325's wording.
        let older = "  low     medium     high     xhigh      max\n  ←/→ to adjust · Enter to confirm · s for this session only · Esc to cancel"
        #expect(EffortPicker.isOpen(onScreen: older) && EffortPicker.offersSessionKey(onScreen: older))
        // On the max stop Enter is "this session only": still the picker.
        let atMax = "  low  medium  high  xhigh  max\n  ←/→ to adjust · Enter to use this session only · Esc to cancel"
        #expect(EffortPicker.isOpen(onScreen: atMax) && !EffortPicker.offersSessionKey(onScreen: atMax))
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

    @Test func statusLineInputGivesTheLevelAtOnce() throws {
        let json = #"{"session_id":"s1","model":{"id":"claude-opus-5-5"},"effort":{"level":"high"}}"#
        let live = try #require(LiveEffort.parse(Data(json.utf8), at: Date(timeIntervalSince1970: 100)))
        #expect(live.level == "high" && live.sessionID == "s1")
        // Claude Code before effort was passed: no level.
        #expect(LiveEffort.parse(Data(#"{"session_id":"s1"}"#.utf8), at: Date()) == nil)

        // Before any reply the live level shows; a pick shows until a newer input.
        let stats = StatsSnapshot()
        #expect(ModelSwitchController.displayedEffort(pick: nil, live: live, stats: stats)?.level == "high")
        let low = try #require(ClaudeEffortChoice.matching(level: "low"))
        let pick = ModelSwitchController.EffortPick(choice: low, at: Date(timeIntervalSince1970: 150))
        #expect(ModelSwitchController.displayedEffort(pick: pick, live: live, stats: stats) == low)
        let newer = LiveEffort(level: "medium", sessionID: "s1", at: Date(timeIntervalSince1970: 151))
        #expect(ModelSwitchController.displayedEffort(pick: pick, live: newer, stats: stats)?.level == "medium")
    }

    @Test func statusLineScriptKeepsTheInputAndRunsTheUsersCommand() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "xylem-sl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsPath = try #require(ClaudeHookBridge.install(root: root))
        let settings = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: settingsPath))) as? [String: Any])
        let statusLine = try #require(settings["statusLine"] as? [String: String])
        #expect(statusLine["type"] == "command")

        // Run it the way Claude Code does: JSON on stdin, the tab's env.
        let tab = UUID()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", statusLine["command"]!]
        process.environment = [ClaudeHookBridge.environmentKey: tab.uuidString,
                               ClaudeHookBridge.userStatusLineKey: "cat >/dev/null; printf 'users line'"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"session_id":"s1","effort":{"level":"xhigh"}}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(printed == "users line")
        let events = root.appending(path: "tab-events")
        #expect(ClaudeHookBridge.latestStatusEffort(forTab: tab, in: events)?.level == "xhigh")
        let mode = try FileManager.default.attributesOfItem(atPath: ClaudeHookBridge.statusFile(forTab: tab, in: events).path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func usersStatusLineFollowsClaudeCodesPrecedence() {
        struct Settings: ClaudeSettingsReading {
            let global: String?, shared: String?, local: String?
            func decode(_ command: String?) -> ClaudeSettings? {
                command.flatMap { try? JSONDecoder().decode(ClaudeSettings.self, from: Data(#"{"statusLine":{"type":"command","command":"\#($0)"}}"#.utf8)) }
            }
            func readGlobalSettings() -> ClaudeSettings? { decode(global) }
            func readProjectSettings(at projectDirectory: String) -> (shared: ClaudeSettings?, local: ClaudeSettings?) { (decode(shared), decode(local)) }
        }
        let all = Settings(global: "g", shared: "p", local: "l")
        #expect(TerminalSessionFactory.userStatusLineCommand(directory: "/x", settings: all) == "l")
        #expect(TerminalSessionFactory.userStatusLineCommand(directory: "/x", settings: Settings(global: "g", shared: "p", local: nil)) == "p")
        #expect(TerminalSessionFactory.userStatusLineCommand(directory: nil, settings: all) == "g")
        #expect(TerminalSessionFactory.userStatusLineCommand(directory: "/x", settings: Settings(global: nil, shared: nil, local: nil)) == nil)
        let env = TerminalSessionFactory.tabEnvironment(tabID: UUID(), directory: nil, settings: Settings(global: nil, shared: nil, local: nil))
        #expect(env[ClaudeHookBridge.userStatusLineKey] == nil && env[ClaudeHookBridge.environmentKey] != nil)
    }
}
