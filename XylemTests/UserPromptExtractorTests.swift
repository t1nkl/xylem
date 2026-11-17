//
//  UserPromptExtractorTests.swift
//  XylemTests
//
//  Shapes taken from real Claude Code session files: only what the human
//  typed may become a session title or a tab preview.
//

import Testing
import Foundation

struct UserPromptExtractorTests {

    private func record(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @Test func plainStringAndTextPartsAreUserPrompts() throws {
        #expect(UserPromptExtractor.prompt(from: try record(
            #"{"type":"user","message":{"content":"  fix the build  "}}"#
        )) == "fix the build")
        #expect(UserPromptExtractor.prompt(from: try record(
            #"{"type":"user","message":{"content":[{"type":"image"},{"type":"text","text":"what is this?"}]}}"#
        )) == "what is this?")
    }

    @Test func machineWrittenRecordsAreIgnored() throws {
        let machine = [
            // Hook output injected by `/goal`, marked isMeta.
            #"{"type":"user","isMeta":true,"message":{"content":"A session-scoped Stop hook is now active"}}"#,
            #"{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"user","message":{"content":"<local-command-stdout>done</local-command-stdout>"}}"#,
            #"{"type":"user","message":{"content":"<task-notification>\n<task-id>1</task-id>"}}"#,
            #"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"},{"type":"text","text":"note"}]}}"#,
            #"{"type":"assistant","message":{"content":"hello"}}"#,
            // Compaction summary: not isMeta, but Claude Code wrote it.
            #"{"type":"user","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"message":{"content":"This session is being continued from a previous conversation that ran out of context."}}"#
        ]
        for json in machine {
            #expect(UserPromptExtractor.prompt(from: try record(json)) == nil, "\(json)")
        }
    }

    @Test func pastedBlockIsShownWithoutItsWrapper() throws {
        #expect(UserPromptExtractor.prompt(from: try record(
            #"{"type":"user","message":{"content":"<pasted_content id=\"a1\">\nlog line\n</pasted_content>"}}"#
        )) == "log line")
    }

    @Test func lastPromptSurvivesLaterCommandEchoes() throws {
        let lines = [
            #"{"type":"user","message":{"content":"<tag> inside a real prompt is fine"}}"#,
            #"{"type":"user","message":{"content":"refactor the reader"}}"#,
            #"{"type":"user","message":{"content":"<command-name>/mcp</command-name>"}}"#,
            #"{"type":"user","message":{"content":"<local-command-stdout>ok</local-command-stdout>"}}"#,
            #"{"type":"user","isMeta":true,"message":{"content":"Caveat: injected"}}"#
        ]
        let url = FileManager.default.temporaryDirectory
            .appending(path: "xylem-lastprompt-\(UUID().uuidString).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(LastPromptReader.read(from: url) == "refactor the reader")
    }

    @Test func slashCommandWithArgumentsIsThePrompt() throws {
        let goal = try record(#"{"type":"user","message":{"content":"<command-name>/goal</command-name>\n            <command-message>goal</command-message>\n            <command-args>fix the build</command-args>"}}"#)
        #expect(UserPromptExtractor.prompt(from: goal) == "/goal fix the build")
        let bare = try record(#"{"type":"user","message":{"content":"<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>"}}"#)
        #expect(UserPromptExtractor.prompt(from: bare) == nil)
    }

    @Test func tabPreviewKeepsTheRealPromptOverLaterSlashCommands() throws {
        let lines = [
            #"{"type":"user","message":{"content":"<command-name>/goal</command-name><command-args>ship it</command-args>"}}"#,
            #"{"type":"user","message":{"content":"why does the build fail?"}}"#,
            #"{"type":"user","message":{"content":"<command-name>/model</command-name><command-args>opus</command-args>"}}"#
        ]
        let url = FileManager.default.temporaryDirectory.appending(path: "xylem-preview-\(UUID().uuidString).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(LastPromptReader.read(from: url) == "why does the build fail?")
    }

    @Test func goalAfterAPlainPromptBecomesThePreview() throws {
        let lines = [
            #"{"type":"user","message":{"content":"fix the login form"}}"#,
            #"{"type":"user","message":{"content":"<command-name>/goal</command-name><command-args>ship the release</command-args>"}}"#,
            #"{"type":"user","message":{"content":"<command-name>/resume</command-name><command-args>1234-abcd</command-args>"}}"#
        ]
        let url = FileManager.default.temporaryDirectory.appending(path: "xylem-goal-\(UUID().uuidString).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(LastPromptReader.read(from: url) == "/goal ship the release")
    }
}

