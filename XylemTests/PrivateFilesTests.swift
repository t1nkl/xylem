//
//  PrivateFilesTests.swift
//  XylemTests
//
//  Files that hold the user's prompts stay owner-only, like Claude Code's
//  own transcripts: the prompt index and the tab-event files the hook
//  script writes.
//

import Testing
import Foundation

struct PrivateFilesTests {
    private func permissions(_ path: String) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
    }

    @Test func promptIndexIsOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "xylem-perm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "prompt-index.json")
        let store = PromptHistoryStore(url: url)
        try store.save([:])
        #expect(try permissions(url.path) == 0o600)
        try store.save([:])                       // replacing keeps it private
        #expect(try permissions(url.path) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["prompt-index.json"])
    }

    @Test func hookEventFilesAreOwnerOnly() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "xylem-hook-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try #require(ClaudeHookBridge.install(root: root))
        let events = root.appending(path: "tab-events")
        #expect(try permissions(events.path) == 0o700)

        let tab = UUID()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [root.appending(path: "hooks/tab-event.sh").path]
        process.environment = [ClaudeHookBridge.environmentKey: tab.uuidString, "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"hook_event_name":"UserPromptSubmit","prompt":"secret"}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let file = ClaudeHookBridge.eventFile(forTab: tab, in: events)
        #expect(try permissions(file.path) == 0o600)
    }
}
