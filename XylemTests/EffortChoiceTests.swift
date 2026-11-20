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
        let live = try #require(ClaudeLiveStatus.parse(Data(json.utf8), at: Date(timeIntervalSince1970: 100)))
        #expect(live.level == "high" && live.sessionID == "s1")
        // Claude Code before effort was passed: no level.
        #expect(ClaudeLiveStatus.parse(Data(#"{"session_id":"s1"}"#.utf8), at: Date()) == nil)
        let full = try #require(ClaudeLiveStatus.parse(Data(#"{"session_id":"s1","version":"2.1.250","model":{"id":"claude-sonnet-5-5"}}"#.utf8), at: Date()))
        #expect(full.level == nil && full.modelID == "claude-sonnet-5-5" && full.version == "2.1.250")

        // Before any reply the live level shows; a pick shows until a newer input.
        let stats = StatsSnapshot()
        #expect(ModelSwitchController.displayedEffort(pick: nil, live: live, stats: stats)?.level == "high")
        let low = try #require(ClaudeEffortChoice.matching(level: "low"))
        let pick = ModelSwitchController.EffortPick(choice: low, at: Date(timeIntervalSince1970: 150))
        #expect(ModelSwitchController.displayedEffort(pick: pick, live: live, stats: stats) == low)
        // A reply still streaming reports the old level: the pick holds.
        let streaming = ClaudeLiveStatus(level: "high", sessionID: "s1", at: Date(timeIntervalSince1970: 151))
        #expect(ModelSwitchController.displayedEffort(pick: pick, live: streaming, stats: stats) == low)
        // The input names the pick: from now on the input decides.
        let confirmed = ClaudeLiveStatus(level: "low", sessionID: "s1", at: Date(timeIntervalSince1970: 152))
        #expect(ModelSwitchController.displayedEffort(pick: pick, live: confirmed, stats: stats)?.level == "low")
        // Never confirmed (a cap, a change in the terminal): the input after 10 s.
        let later = ClaudeLiveStatus(level: "medium", sessionID: "s1", at: Date(timeIntervalSince1970: 161))
        #expect(ModelSwitchController.displayedEffort(pick: pick, live: later, stats: stats)?.level == "medium")
    }

    @Test func statusLineScriptKeepsTheInputAndRunsTheUsersCommand() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "xylem-sl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsPath = try #require(ClaudeHookBridge.install(root: root, userSettings: NoClaudeSettings()))
        let settings = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: settingsPath))) as? [String: Any])
        let statusLine = try #require(settings["statusLine"] as? [String: Any])
        #expect(statusLine["type"] as? String == "command")

        // Run it the way Claude Code does: JSON on stdin, the tab's env.
        let tab = UUID()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", try #require(statusLine["command"] as? String)]
        let events = root.appending(path: "tab-events")
        ClaudeHookBridge.setUserStatusLine("cat >/dev/null; printf 'users line'", forTab: tab, in: events)
        let commandMode = try FileManager.default.attributesOfItem(atPath: ClaudeHookBridge.userStatusLineFile(forTab: tab, in: events).path)[.posixPermissions] as? Int
        #expect(commandMode == 0o600)
        process.environment = [ClaudeHookBridge.environmentKey: tab.uuidString]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"session_id":"s1","effort":{"level":"xhigh"}}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(printed == "users line")
        #expect(ClaudeHookBridge.latestStatus(forTab: tab, in: events)?.level == "xhigh")
        let mode = try FileManager.default.attributesOfItem(atPath: ClaudeHookBridge.statusFile(forTab: tab, in: events).path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func usersStatusLineFollowsClaudeCodesPrecedence() throws {
        struct Settings: ClaudeSettingsReading {
            let global: String?, shared: String?, local: String?
            func decode(_ command: String?) -> ClaudeSettings? {
                command.flatMap { try? JSONDecoder().decode(ClaudeSettings.self, from: Data(#"{"statusLine":{"type":"command","command":"\#($0)"}}"#.utf8)) }
            }
            func readGlobalSettings() -> ClaudeSettings? { decode(global) }
            func readProjectSettings(at projectDirectory: String) -> (shared: ClaudeSettings?, local: ClaudeSettings?) { (decode(shared), decode(local)) }
        }
        let all = Settings(global: "g", shared: "p", local: "l")
        #expect(TerminalSessionFactory.userStatusLine(directory: "/x", settings: all)?.command == "l")
        #expect(TerminalSessionFactory.userStatusLine(directory: "/x", settings: Settings(global: "g", shared: "p", local: nil))?.command == "p")
        #expect(TerminalSessionFactory.userStatusLine(directory: nil, settings: all)?.command == "g")
        #expect(TerminalSessionFactory.userStatusLine(directory: "/x", settings: Settings(global: nil, shared: nil, local: nil)) == nil)
        // Kept beside the hook settings in use; nothing without that folder.
        let root = FileManager.default.temporaryDirectory.appending(path: "xylem-slenv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let hooks = try #require(ClaudeHookBridge.install(root: root, userSettings: NoClaudeSettings()))
        let events = root.appending(path: "tab-events")
        let tab = UUID()
        TerminalSessionFactory.keepUserStatusLine(tabID: tab, directory: "/x", hookSettingsPath: hooks, settings: all)
        #expect((try? String(contentsOf: ClaudeHookBridge.userStatusLineFile(forTab: tab, in: events), encoding: .utf8)) == "l")
        TerminalSessionFactory.keepUserStatusLine(tabID: tab, directory: nil, hookSettingsPath: hooks,
                                                  settings: Settings(global: nil, shared: nil, local: nil))
        TerminalSessionFactory.keepUserStatusLine(tabID: tab, directory: "/x", hookSettingsPath: "/nonexistent/hooks/settings.json", settings: all)
        #expect(!FileManager.default.fileExists(atPath: ClaudeHookBridge.userStatusLineFile(forTab: tab, in: events).path))
    }

    /// Claude Code drops leading spaces from a status line's output, so the
    /// user's padding goes into Xylem's own status line setting.
    @Test func usersGlobalPaddingGoesIntoXylemsStatusLine() throws {
        struct Settings: ClaudeSettingsReading {
            let padding: Int?
            func readGlobalSettings() -> ClaudeSettings? {
                let json = padding.map { #"{"statusLine":{"type":"command","command":"x","padding":\#($0)}}"# } ?? "{}"
                return try? JSONDecoder().decode(ClaudeSettings.self, from: Data(json.utf8))
            }
            func readProjectSettings(at projectDirectory: String) -> (shared: ClaudeSettings?, local: ClaudeSettings?) { (nil, nil) }
        }
        for padding in [6, nil] {
            let root = FileManager.default.temporaryDirectory.appending(path: "xylem-pad-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let path = try #require(ClaudeHookBridge.install(root: root, userSettings: Settings(padding: padding)))
            let settings = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
            let statusLine = try #require(settings["statusLine"] as? [String: Any])
            #expect(statusLine["padding"] as? Int == padding)
        }
    }

    @Test func olderClaudeCodeIsToldApart() {
        #expect(EffortPicker.unsupportedMarks(onScreen: "❯ /effort\n  ⎿  Unknown skill: effort") == 1)
        #expect(EffortPicker.unsupportedMarks(onScreen: "Unknown slash command: effort") == 1)
        #expect(EffortPicker.unsupportedMarks(onScreen: "⎿  Effort level: auto (currently high)") == 1)
        #expect(EffortPicker.unsupportedMarks(onScreen: "⎿  Set effort level to max (this session only)") == 0)
        // 2.1.200-2.1.252: a picker without "s" for this session only.
        let old = "  low  medium  high  xhigh  max\n  ←/→ to adjust · Enter to confirm · Esc to cancel"
        #expect(EffortPicker.isOpen(onScreen: old) && !EffortPicker.offersSessionKey(onScreen: old))

        let low = ClaudeEffortChoice.levels[0], max = ClaudeEffortChoice.levels[4]
        #expect(EffortSupport.explanation(for: low, version: "2.1.250").message.contains("Claude Code 2.1.250 can't"))
        #expect(EffortSupport.explanation(for: low, version: nil).message.contains("2.1.257 or later"))
        #expect(EffortSupport.explanation(for: max, version: "2.1.70").message.contains("Max needs Claude Code 2.1.76"))
    }

    @Test func menuOffersOnlyWhatTheRunningClaudeCodeCanDo() {
        let low = ClaudeEffortChoice.levels[0], max = ClaudeEffortChoice.levels[4]
        #expect(EffortSupport.isVersion("2.1.257", atLeast: "2.1.257"))
        #expect(EffortSupport.isVersion("2.1.300", atLeast: "2.1.257"))
        #expect(!EffortSupport.isVersion("2.1.76", atLeast: "2.1.257"))
        #expect(EffortSupport.isVersion("3.0.0", atLeast: "2.1.257"))
        #expect(EffortSupport.isAvailable(low, version: "2.1.329") && EffortSupport.isAvailable(max, version: "2.1.329"))
        #expect(!EffortSupport.isAvailable(low, version: "2.1.250") && EffortSupport.isAvailable(max, version: "2.1.250"))
        #expect(!EffortSupport.isAvailable(max, version: "2.1.75"))
        #expect(EffortSupport.isAvailable(low, version: nil))
        #expect(EffortSupport.canSetAnything(version: nil) && EffortSupport.canSetAnything(version: "2.1.76"))
        #expect(!EffortSupport.canSetAnything(version: "2.1.70"))
        #expect(EffortSupport.cantSetHelp(version: "2.1.70").contains("claude update"))
    }

    @Test func modelComesFromTheStatusLineAtOnce() throws {
        let opus = try #require(ClaudeModelChoice.all.first { $0.alias == "opus" })
        let haiku = try #require(ClaudeModelChoice.all.first { $0.alias == "haiku" })
        var stats = StatsSnapshot()
        stats.modelID = "<synthetic>"; stats.model = "<synthetic>"
        let live = ClaudeLiveStatus(modelID: "claude-opus-5-5", at: Date(timeIntervalSince1970: 100))
        #expect(ModelSwitchController.displayedModel(pick: nil, live: live, stats: stats).title == "Opus")
        // A /model pick waits for the turn; it shows until the input names it.
        let pick = ModelSwitchController.Pick(choice: haiku, at: Date(timeIntervalSince1970: 150))
        #expect(ModelSwitchController.displayedModel(pick: pick, live: live, stats: stats).choice == haiku)
        let switched = ClaudeLiveStatus(modelID: "claude-haiku-5-5", at: Date(timeIntervalSince1970: 200))
        #expect(ModelSwitchController.displayedModel(pick: pick, live: switched, stats: stats).choice == haiku)
        #expect(ModelSwitchController.displayedModel(pick: nil, live: nil, stats: stats).title == "<synthetic>")
        _ = opus
    }
}

/// No user settings: tests never read the real ~/.claude.
nonisolated struct NoClaudeSettings: ClaudeSettingsReading {
    func readGlobalSettings() -> ClaudeSettings? { nil }
    func readProjectSettings(at projectDirectory: String) -> (shared: ClaudeSettings?, local: ClaudeSettings?) { (nil, nil) }
}