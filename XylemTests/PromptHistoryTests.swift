//
//  PromptHistoryTests.swift
//  XylemTests
//
//  The ⌘K prompt index: only what the human typed gets in (the byte
//  pre-filter must not lose any prompt UserPromptExtractor accepts), files
//  that did not change are not read, files that grew are read from where
//  reading stopped, and search is case-, diacritic- and Cyrillic-aware,
//  newest first.
//

import Testing
import Foundation

struct PromptHistoryTests {

    // MARK: - Fixtures

    /// `<root>/projects/-srv-proj/` plus an index path, all in a fresh temp dir.
    private struct Fixture {
        let root: URL
        let projects: URL
        let folder: URL
        let indexURL: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "xylem-prompts-\(UUID().uuidString)", directoryHint: .isDirectory)
            projects = root.appending(path: "projects", directoryHint: .isDirectory)
            folder = projects.appending(path: "-srv-proj", directoryHint: .isDirectory)
            indexURL = root.appending(path: "prompt-index.json")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        var indexer: PromptHistoryIndexer {
            PromptHistoryIndexer(projectsDirectory: projects, store: PromptHistoryStore(url: indexURL))
        }

        func write(_ lines: [String], to name: String, in directory: URL? = nil) throws -> URL {
            let url = (directory ?? folder).appending(path: name)
            try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
            return url
        }

        func append(_ lines: [String], to url: URL) throws {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private static func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    /// A human prompt record, shaped like Claude Code writes it.
    private static func prompt(_ text: String, uuid: String = UUID().uuidString,
                               at time: String = "2026-11-10T10:00:00.000Z") -> String {
        json(["type": "user", "uuid": uuid, "timestamp": time, "cwd": "/srv/proj",
              "isSidechain": false, "message": ["role": "user", "content": text]])
    }

    private static let machineLines: [String] = [
        json(["type": "user", "isMeta": true, "cwd": "/srv/proj",
              "message": ["content": "A session-scoped Stop hook is now active"]]),
        json(["type": "user", "isCompactSummary": true, "cwd": "/srv/proj",
              "message": ["content": "This session is being continued from a previous conversation"]]),
        json(["type": "user", "cwd": "/srv/proj",
              "message": ["content": [["type": "tool_result", "tool_use_id": "t1", "content": "fix the build output"]]]]),
        json(["type": "user", "cwd": "/srv/proj",
              "message": ["content": "<command-name>/clear</command-name>\n<command-args></command-args>"]]),
        json(["type": "assistant", "cwd": "/srv/proj",
              "message": ["content": [["type": "text", "text": "I will fix the build"]]]]),
        json(["type": "summary", "summary": "fix the build"])
    ]

    private func setMtime(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func texts(_ records: [String: PromptHistoryFileRecord], _ url: URL) -> [String] {
        lookup(records, url)?.prompts.map(\.text) ?? []
    }

    /// The record of `url`, whichever spelling of the temp dir (`/var` or
    /// `/private/var`) the directory listing used.
    private func lookup(_ records: [String: PromptHistoryFileRecord], _ url: URL) -> PromptHistoryFileRecord? {
        let wanted = url.resolvingSymlinksInPath().path
        return records.first { URL(fileURLWithPath: $0.key).resolvingSymlinksInPath().path == wanted }?.value
    }

    // MARK: - Building

    @Test func indexHoldsOnlyHumanPromptsOfMainTranscripts() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let session = try fx.write(
            [Self.prompt("fix the build")] + Self.machineLines + [
                Self.json(["type": "user", "cwd": "/srv/proj", "uuid": "u-goal",
                           "message": ["content": "<command-name>/goal</command-name>\n<command-args>tests pass</command-args>"]]),
                Self.json(["type": "user", "cwd": "/srv/proj", "uuid": "u-parts",
                           "message": ["content": [["type": "image"], ["type": "text", "text": "what is\n  this?"]]]])
            ],
            to: "session-a.jsonl"
        )
        // Subagent transcripts live one level down and are not the human.
        let subagents = fx.folder.appending(path: "session-a/subagents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        _ = try fx.write([Self.prompt("subagent task")], to: "agent-1.jsonl", in: subagents)

        let result = fx.indexer.update([:])

        #expect(result.changed)
        #expect(result.records.count == 1)
        let record = try #require(lookup(result.records, session))
        #expect(record.prompts.map(\.text) == ["fix the build", "/goal tests pass", "what is this?"])
        #expect(record.sessionID == "session-a")
        #expect(record.projectPath == "/srv/proj")
        #expect(record.prompts.first?.time == TimestampParser.parse("2026-11-10T10:00:00.000Z")?.timeIntervalSince1970)
        let size = try FileManager.default.attributesOfItem(atPath: session.path)[.size] as? UInt64
        #expect(record.parsedBytes == size)
        // Saved, and loads back the same.
        #expect(fx.indexer.loadStored() == result.records)
    }

    @Test func prefilterKeepsPromptsThatMentionTheMarkers() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        // The markers inside a prompt are escaped JSON strings, so the
        // pre-filter must still let the line through.
        let text = #"why is "isMeta":true and "type":"tool_result" in the log?"#
        let session = try fx.write([Self.prompt(text)], to: "s.jsonl")
        #expect(texts(fx.indexer.update([:]).records, session) == [text])
    }

    @Test func longPromptsAreCappedAndCollapsed() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let long = "line one\n\n\tline two " + String(repeating: "x", count: 5000)
        let session = try fx.write([Self.prompt(long)], to: "s.jsonl")
        let text = try #require(texts(fx.indexer.update([:]).records, session).first)
        #expect(text.hasPrefix("line one line two x"))
        #expect(text.count == PromptHistoryIndexer.promptCharacterLimit)
    }

    // MARK: - Incremental

    @Test func unchangedFileIsNotReadAgain() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let mtime = Date(timeIntervalSince1970: 1_700_000_000.123456)
        let session = try fx.write([Self.prompt("first prompt")], to: "s.jsonl")
        try setMtime(session, mtime)
        let first = fx.indexer.update([:])

        // Same size, same inode, mtime put back: the stamp says "unchanged",
        // so the new bytes must not be seen.
        let handle = try FileHandle(forWritingTo: session)
        try handle.write(contentsOf: Data(Self.prompt("other prompt").utf8))
        try handle.close()
        try setMtime(session, mtime)

        let second = fx.indexer.update(first.records)
        #expect(!second.changed)
        #expect(texts(second.records, session) == ["first prompt"])
    }

    @Test func appendedFileIsReadFromWhereReadingStopped() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let early = Self.prompt("early prompt", uuid: "u-early")
        let session = try fx.write([early, Self.prompt("second prompt", uuid: "u-second")], to: "s.jsonl")
        let first = fx.indexer.update([:])

        // Rewrite the first record in place (same length, same inode, far
        // from the tail bytes) and append: only the appended part is read,
        // so the early prompt keeps its indexed text.
        let handle = try FileHandle(forWritingTo: session)
        try handle.write(contentsOf: Data(early.replacingOccurrences(of: "early", with: "EARLY").utf8))
        try handle.close()
        try fx.append([Self.prompt("third prompt")], to: session)

        let second = fx.indexer.update(first.records)
        #expect(second.changed)
        #expect(texts(second.records, session) == ["early prompt", "second prompt", "third prompt"])
    }

    @Test func rewrittenFileIsReadFromTheStart() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let session = try fx.write([Self.prompt("old one"), Self.prompt("old two")], to: "s.jsonl")
        let first = fx.indexer.update([:])

        // Rewritten with other content: the bytes before the stored offset differ.
        _ = try fx.write([Self.prompt("new one"), Self.prompt("new two"), Self.prompt("new three")], to: "s.jsonl")
        #expect(texts(fx.indexer.update(first.records).records, session) == ["new one", "new two", "new three"])

        // Shorter than what was read: from the start too.
        let second = fx.indexer.update(first.records)
        let handle = try FileHandle(forWritingTo: session)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((Self.prompt("tiny") + "\n").utf8))
        try handle.close()
        #expect(texts(fx.indexer.update(second.records).records, session) == ["tiny"])
    }

    @Test func halfWrittenLastLineWaitsUntilComplete() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let line = Self.prompt("being written")
        let session = try fx.write([Self.prompt("done")], to: "s.jsonl")
        let handle = try FileHandle(forWritingTo: session)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.prefix(line.count / 2).utf8))
        let first = fx.indexer.update([:])
        #expect(texts(first.records, session) == ["done"])

        try handle.write(contentsOf: Data((line.dropFirst(line.count / 2) + "\n").utf8))
        try handle.close()
        #expect(texts(fx.indexer.update(first.records).records, session) == ["done", "being written"])
    }

    @Test func replyWithoutPromptIsSavedButKeepsTheSnapshot() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let session = try fx.write([Self.prompt("question")], to: "s.jsonl")
        let first = fx.indexer.update([:])
        #expect(first.promptsChanged)

        try fx.append(Self.machineLines, to: session)
        let reply = fx.indexer.update(first.records)
        #expect(reply.changed)  // new offset to save
        #expect(!reply.promptsChanged)  // nothing new to search

        try fx.append([Self.prompt("follow-up")], to: session)
        #expect(fx.indexer.update(reply.records).promptsChanged)
    }

    @Test func deletedTranscriptLeavesTheIndex() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let session = try fx.write([Self.prompt("gone soon")], to: "s.jsonl")
        let first = fx.indexer.update([:])
        try FileManager.default.removeItem(at: session)
        let second = fx.indexer.update(first.records)
        #expect(second.changed)
        #expect(second.records.isEmpty)
    }

    @Test func staleOrMissingIndexLoadsEmpty() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        #expect(fx.indexer.loadStored().isEmpty)
        try Data(#"{"version":1,"rules":0,"files":[]}"#.utf8).write(to: fx.indexURL)
        #expect(fx.indexer.loadStored().isEmpty)
    }

    // MARK: - Search

    private func record(_ path: String, mtime: Int64, project: String = "/Users/me/Projects/xylem",
                        _ prompts: [(String, Double?, String?)]) -> PromptHistoryFileRecord {
        PromptHistoryFileRecord(
            path: path,
            stamp: FileStamp(size: 1, mtimeSeconds: mtime, mtimeNanoseconds: 0, inode: 1),
            sessionID: (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: ""),
            projectPath: project,
            parsedBytes: 1,
            tailBytes: Data(),
            prompts: prompts.map { PromptHistoryPrompt(uuid: $0.2, text: $0.0, time: $0.1) }
        )
    }

    /// Prompts of throwaway temp-folder runs don't show in Cmd-K.
    @Test func temporaryFolderPromptsAreNotSearched() {
        let snapshot = PromptHistorySnapshot(records: [
            record("/p/a.jsonl", mtime: 1, [("summarize the release", 10, nil)]),
            record("/p/b.jsonl", mtime: 2, project: "/private/var/folders/0l/x/T/summarizer/cwd/ab12cd34",
                   [("summarize this diff", 20, nil)]),
            record("/p/c.jsonl", mtime: 3, project: "/tmp/scratch", [("summarize tmp", 30, nil)])
        ])
        #expect(snapshot.search("summarize").map(\.text) == ["summarize the release"])
        #expect(snapshot.count == 1)
    }

    @Test func searchIgnoresCaseAndDiacriticsIncludingCyrillic() {
        let snapshot = PromptHistorySnapshot(records: [record("/p/a.jsonl", mtime: 1, [
            ("Fix the Café menu", 10, nil),
            ("Привіт, зроби ЇЖАКА", 20, nil),
            ("додай пошук по промптах", 30, nil)
        ])])
        #expect(snapshot.search("cafe").map(\.text) == ["Fix the Café menu"])
        #expect(snapshot.search("FIX THE").map(\.text) == ["Fix the Café menu"])
        #expect(snapshot.search("ПРИВІТ").map(\.text) == ["Привіт, зроби ЇЖАКА"])
        #expect(snapshot.search("їжака").map(\.text) == ["Привіт, зроби ЇЖАКА"])
        #expect(snapshot.search("Пошук По").map(\.text) == ["додай пошук по промптах"])
        // Query whitespace is collapsed like the prompts'.
        #expect(snapshot.search("  пошук \n по ").map(\.text) == ["додай пошук по промптах"])
        #expect(snapshot.search("x").isEmpty)
        #expect(snapshot.search("nothing like it").isEmpty)
    }

    @Test func resultsAreNewestFirstAndLimited() {
        let prompts: [(String, Double?, String?)] = (0..<30).map { ("deploy step \($0)", Double($0), nil) }
        let snapshot = PromptHistorySnapshot(records: [
            record("/p/a.jsonl", mtime: 1, Array(prompts[0..<15])),
            record("/p/b.jsonl", mtime: 2, Array(prompts[15...]) + [("deploy undated", nil, nil)])
        ])
        let hits = snapshot.search("deploy", limit: 20)
        #expect(hits.count == 20)
        #expect(hits.first?.text == "deploy step 29")
        #expect(hits.map(\.date) == hits.map(\.date).sorted { ($0 ?? .distantPast) > ($1 ?? .distantPast) })
        // Prompts without a timestamp come last.
        #expect(snapshot.search("deploy", limit: 100).last?.text == "deploy undated")
    }

    @Test func forkedPromptShowsOnceInTheNewestSession() {
        let snapshot = PromptHistorySnapshot(records: [
            record("/p/old.jsonl", mtime: 1, [("shared question", 5, "u1"), ("only old", 6, "u2")]),
            record("/p/new.jsonl", mtime: 9, [("shared question", 5, "u1"), ("only new", 7, "u3")])
        ])
        let hits = snapshot.search("shared")
        #expect(hits.count == 1)
        #expect(hits.first?.sessionID == "new")
        #expect(hits.first?.sessionTitle == "shared question")
        #expect(hits.first?.projectName == "xylem")
        #expect(snapshot.count == 3)
    }

    @Test func snippetMarksTheMatchAndCutsLongLeads() {
        let short = PromptHistorySnippet(text: "please fix the Café menu", query: "cafe")
        #expect(short.before == "please fix the ")
        #expect(short.match == "Café")
        #expect(short.after == " menu")

        let lead = String(repeating: "a", count: 100)
        let long = PromptHistorySnippet(text: lead + " needle end", query: "NEEDLE")
        #expect(long.before.hasPrefix("…"))
        #expect(long.before.count == PromptHistorySnippet.leadingContext + 1)
        #expect(long.match == "needle")

        let missing = PromptHistorySnippet(text: "no match", query: "zz")
        #expect(missing.before == "no match" && missing.match.isEmpty)
    }

    // MARK: - View model

    @MainActor
    @Test func viewModelPublishesTheSavedIndexThenUpdates() async throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let session = try fx.write([Self.prompt("saved before relaunch", at: "2026-11-01T10:00:00.000Z")], to: "s.jsonl")
        _ = fx.indexer.update([:])  // the index a previous run saved
        try fx.append([Self.prompt("typed while Xylem was closed", at: "2026-11-02T10:00:00.000Z")], to: session)

        let model = PromptHistoryViewModel(indexer: fx.indexer)
        #expect(model.snapshot == nil)
        model.refresh()
        for _ in 0..<200 where model.snapshot?.count != 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.snapshot?.search("while xylem").map(\.text) == ["typed while Xylem was closed"])
        #expect(model.snapshot?.entries.map(\.text) == ["typed while Xylem was closed", "saved before relaunch"])
    }
}
