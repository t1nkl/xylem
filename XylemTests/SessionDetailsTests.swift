//
//  SessionDetailsTests.swift
//  XylemTests
//
//  What a tab shows of its claude beyond the state: the session's name from
//  the transcript, the prompt cache from the status line input, the
//  permission mode and background tasks from hook events, the questions
//  before closing or quitting, the "open elsewhere" rule with Claude Code's
//  own session list, and the fixes for an API error's `<synthetic>` model
//  and the path cache. Payload shapes are Claude Code 2.1.332's, with
//  made-up values.
//

import Testing
import Foundation

struct PromptCacheParsingTests {
    private func parse(_ json: String) -> ClaudeLiveStatus? {
        ClaudeLiveStatus.parse(Data(json.utf8), at: Date(timeIntervalSince1970: 100))
    }

    @Test func readsExpiryTtlAndRecacheTokens() throws {
        let status = try #require(parse(#"""
            {"version":"2.1.332","session_id":"s","prompt_cache":{"warm":true,"caching_observed":true,"ttl":"1h",
             "expires_at":1795772065,"requests":212,"misses":7,"recache_tokens_if_cold":183377,
             "last_miss_cause":{"causes":["ttl_expired_1h"]}}}
            """#))
        let cache = try #require(status.promptCache)
        #expect(cache.expiresAt == Date(timeIntervalSince1970: 1_795_772_065))
        #expect(cache.ttl == "1h")
        #expect(cache.recacheTokens == 183_377)
        #expect(cache.isWarm(at: Date(timeIntervalSince1970: 1_795_772_064)))
        #expect(!cache.isWarm(at: Date(timeIntervalSince1970: 1_795_772_065)))
    }

    /// Older Claude Code, a cache without an expiry, junk values.
    @Test func missingOrUnusableCacheIsNil() throws {
        #expect(try #require(parse(#"{"version":"2.1.329"}"#)).promptCache == nil)
        #expect(try #require(parse(#"{"version":"2.1.332","prompt_cache":{"warm":false}}"#)).promptCache == nil)
        #expect(try #require(parse(#"{"version":"2.1.332","prompt_cache":{"expires_at":true}}"#)).promptCache == nil)
        let zero = try #require(parse(#"{"version":"2.1.332","prompt_cache":{"expires_at":5,"recache_tokens_if_cold":0}}"#))
        #expect(zero.promptCache?.recacheTokens == nil)
    }
}

struct HookEventDetailsTests {
    private func event(_ json: String) -> ClaudeTabEvent? {
        ClaudeTabEvent.parse(Data(json.utf8), at: Date(timeIntervalSince1970: 100))
    }

    @Test func stopCountsRunningAndPendingTasks() throws {
        let stop = try #require(event(#"""
            {"hook_event_name":"Stop","session_id":"A","permission_mode":"auto","background_tasks":[
             {"id":"1","type":"local_bash","status":"running","command":"npm run dev"},
             {"id":"2","type":"local_agent","status":"pending"},
             {"id":"3","type":"local_bash","status":"completed"},
             {"id":"4","type":"monitor_mcp","status":"failed"},
             {"id":"5","status":"killed"},{"id":"6"},"junk"],"session_crons":[]}
            """#))
        #expect(stop.runningBackgroundTasks == 2)
        #expect(stop.permissionMode == "auto")
        #expect(stop.kind == .stop)
    }

    /// Only Stop carries the list: an event without it says nothing about tasks.
    @Test func eventsWithoutTheFieldsLeaveThemUnknown() throws {
        let prompt = try #require(event(#"{"hook_event_name":"UserPromptSubmit","session_id":"A","permission_mode":"plan"}"#))
        #expect(prompt.runningBackgroundTasks == nil)
        #expect(prompt.permissionMode == "plan")
        let start = try #require(event(#"{"hook_event_name":"SessionStart","session_id":"A","permission_mode":""}"#))
        #expect(start.permissionMode == nil)
        let empty = try #require(event(#"{"hook_event_name":"Stop","session_id":"A","background_tasks":[]}"#))
        #expect(empty.runningBackgroundTasks == 0)
    }
}

struct SessionTitleTests {
    private func preview(_ lines: [String]) throws -> LastPromptReader.Preview? {
        let url = FileManager.default.temporaryDirectory.appending(path: "xylem-title-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return LastPromptReader.preview(from: url)
    }

    private let prompt = #"{"type":"user","message":{"role":"user","content":"fix the build"}}"#

    @Test func newestAiTitleWins() throws {
        let read = try #require(try preview([
            #"{"type":"ai-title","aiTitle":"Build setup","sessionId":"s"}"#,
            prompt,
            #"{"type":"ai-title","aiTitle":"Огляд документації","sessionId":"s"}"#
        ]))
        #expect(read.title == "Огляд документації")
        #expect(read.prompt == "fix the build")
    }

    /// `/rename` (custom-title) beats every name Claude Code makes up, also later ones.
    @Test func customTitleWinsOverAiTitle() throws {
        let read = try #require(try preview([
            #"{"type":"custom-title","customTitle":"  release prep\nsecond line","sessionId":"s"}"#,
            #"{"type":"ai-title","aiTitle":"Something else","sessionId":"s"}"#
        ]))
        #expect(read.title == "release prep")
    }

    @Test func noTitleUntilNamed() throws {
        let read = try #require(try preview([prompt, #"{"type":"ai-title","aiTitle":"   ","sessionId":"s"}"#]))
        #expect(read.title == nil)
        #expect(read.prompt == "fix the build")
    }
}

@MainActor
struct TabSessionTitlePollTests {
    /// The name comes from the tab's own session, also after its claude has
    /// exited (the poll then follows the folder's newest transcript for the
    /// prompt, which may be another tab's).
    @Test func nameStaysAfterClaudeExits() async throws {
        let transcript = FileManager.default.temporaryDirectory.appending(path: "xylem-own-\(UUID().uuidString).jsonl")
        try ([#"{"type":"user","message":{"content":"fix the build"}}"#,
              #"{"type":"ai-title","aiTitle":"Fix the build","sessionId":"s"}"#].joined(separator: "\n") + "\n")
            .write(to: transcript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: transcript) }
        let tabID = UUID()
        let directory = FileManager.default.temporaryDirectory.appending(path: "xylem-nowhere-\(UUID().uuidString)").path
        let session = TerminalSessionFactory(autoStartClaude: { false }).makeSession(tabID: tabID, title: "t", directory: directory)
        defer { session.close() }
        let tab = TerminalTab(id: tabID, title: "t", state: .session(session))
        tab.claudeSessionID = "s"
        tab.transcriptPath = transcript.path
        let activity = TabActivityViewModel()

        tab.claudeState = .idle
        await activity.refresh(for: [tab])
        #expect(tab.sessionTitle == "Fix the build")
        #expect(tab.displayTitle == "Fix the build")

        tab.claudeState = .notRunning
        try #"{"type":"user","message":{"content":"one more"}}"#.appendLine(to: transcript)
        await activity.refresh(for: [tab])
        #expect(tab.sessionTitle == "Fix the build")
        #expect(tab.lastPrompt == "one more")
    }
}

private extension String {
    func appendLine(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((self + "\n").utf8))
    }
}

@MainActor
struct TabTitleTests {
    @Test func customThenSessionThenFolder() {
        let tab = TerminalTab(title: "New Tab")
        #expect(tab.displayTitle == "New Tab")
        tab.sessionTitle = "Огляд документації"
        #expect(tab.displayTitle == "Огляд документації")
        #expect(tab.folderTitle == "New Tab")
        tab.title = "mine"
        tab.hasCustomTitle = true
        #expect(tab.displayTitle == "mine")
        #expect(tab.folderTitle == "mine")
    }
}

struct TabDetailTextTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func badgesOnlyForPlanAndBypass() {
        #expect(TabDetailText.badge(for: "plan") == .plan)
        #expect(TabDetailText.badge(for: "bypassPermissions") == .bypass)
        for mode in ["default", "auto", "acceptEdits", "dontAsk", nil] as [String?] {
            #expect(TabDetailText.badge(for: mode) == nil)
        }
    }

    @Test func cacheWarmColdAndSoon() {
        let warm = ClaudeLiveStatus.PromptCache(expiresAt: now.addingTimeInterval(1_500), ttl: "1h", recacheTokens: 136_000)
        #expect(TabDetailText.promptCache(warm, now: now).hasPrefix("Prompt cache warm until "))
        #expect(TabDetailText.minutesLeft(warm, now: now) == nil)
        #expect(TabDetailText.minutesLeft(warm, now: now.addingTimeInterval(1_000)) == 9)
        #expect(TabDetailText.minutesLeft(warm, now: now.addingTimeInterval(1_499)) == 1)
        let cold = TabDetailText.promptCache(warm, now: now.addingTimeInterval(1_500))
        #expect(cold.hasPrefix("Prompt cache expired at "))
        #expect(cold.hasSuffix(": the next message writes 136K tokens again"))
        #expect(TabDetailText.minutesLeft(warm, now: now.addingTimeInterval(1_500)) == nil)
        let unknown = ClaudeLiveStatus.PromptCache(expiresAt: now, ttl: nil, recacheTokens: nil)
        #expect(!TabDetailText.promptCache(unknown, now: now).contains("tokens"))
    }

    @Test func linesSkipDefaultModeAndNoTasks() {
        #expect(TabDetailText.lines(permissionMode: "default", taskCount: 0, cache: nil, now: now).isEmpty)
        #expect(TabDetailText.lines(permissionMode: nil, taskCount: 0, cache: nil, now: now).isEmpty)
        #expect(TabDetailText.lines(permissionMode: "auto", taskCount: 1, cache: nil, now: now)
                == ["Auto mode", "1 background task running"])
        #expect(TabDetailText.backgroundTasks(3) == "3 background tasks running")
    }
}

@MainActor
struct BackgroundTaskConfirmationTests {
    private func tab(_ title: String, tasks: Int = 0, state: ClaudeTabState? = .idle) -> TerminalTab {
        let tab = TerminalTab(title: title)
        tab.title = title
        tab.hasCustomTitle = true
        tab.claudeState = state
        tab.runningBackgroundTasks = tasks
        return tab
    }

    @Test func quitNamesTabsWithTasks() throws {
        let quiet = try #require(QuitConfirmation(tabs: [tab("api", tasks: 2), tab("web")]))
        #expect(quiet.background == ["api"])
        #expect(quiet.title == "Background tasks are running in 1 tab")
        #expect(quiet.message.contains("Background tasks: api"))
        #expect(quiet.message.hasSuffix("Quitting ends those tasks now. The sessions resume on the next launch."))
        // A working tab is named once, as working.
        let busy = try #require(QuitConfirmation(tabs: [tab("api", tasks: 1, state: .working), tab("web", tasks: 1)]))
        #expect(busy.working == ["api"])
        #expect(busy.background == ["web"])
        #expect(busy.title == "Claude is busy in 2 tabs")
        #expect(QuitConfirmation(tabs: [tab("web")]) == nil)
    }

    @Test func closeAsksOnlyForTabsWithTasks() throws {
        #expect(CloseTabConfirmation(closing: [tab("web")]) == nil)
        let one = try #require(CloseTabConfirmation(closing: [tab("api", tasks: 1), tab("web")]))
        #expect(one.title == "api has 1 background task running")
        #expect(one.message == "Counted when Claude last replied. Closing ends them now; the session itself can be resumed later.")
        let two = try #require(CloseTabConfirmation(closing: [tab("api", tasks: 2), tab("db", tasks: 1)]))
        #expect(two.title == "2 tabs have 3 background tasks running")
        #expect(two.message.hasPrefix("api: 2\ndb: 1\n"))
    }
}

@MainActor
struct PermissionAndTasksTrackerTests {
    @Test func ownSessionEventsSetModeAndTasksUntilClaudeExits() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "xylem-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tabID = UUID()
        let session = TerminalSessionFactory(autoStartClaude: { false }).makeSession(tabID: tabID, title: "t", directory: "/tmp")
        defer { session.close() }
        let tab = TerminalTab(id: tabID, title: "t", state: .session(session))
        tab.claudeSessionID = "A"
        let tracker = ClaudeTabStateTracker(eventsDirectory: dir, notifier: FakeNotifier(), hooksInstalled: true,
                                            rememberVersion: { _ in }, accountConfigFile: { nil })
        let start = Date().addingTimeInterval(1)
        let events = ClaudeHookBridge.eventFile(forTab: tabID, in: dir)
        func write(_ json: String, at offset: TimeInterval) async throws {
            try Data(json.utf8).write(to: events)
            try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(offset)], ofItemAtPath: events.path)
            await tracker.refresh(tabs: [tab], activeTabID: nil, appIsActive: false, now: start.addingTimeInterval(offset + 0.5))
        }

        try await write(#"{"hook_event_name":"Stop","session_id":"A","permission_mode":"bypassPermissions","background_tasks":[{"status":"running"}]}"#, at: 1)
        #expect(tab.permissionMode == "bypassPermissions")
        #expect(tab.runningBackgroundTasks == 1)
        // A teammate's event (same tab id, its own session) changes nothing.
        try await write(#"{"hook_event_name":"Stop","session_id":"B","permission_mode":"plan","background_tasks":[]}"#, at: 2)
        #expect(tab.permissionMode == "bypassPermissions")
        #expect(tab.runningBackgroundTasks == 1)
        // A prompt has no task list: the count from the last Stop stays.
        try await write(#"{"hook_event_name":"UserPromptSubmit","session_id":"A","permission_mode":"plan"}"#, at: 3)
        #expect(tab.permissionMode == "plan")
        #expect(tab.runningBackgroundTasks == 1)
        // Claude exits: its tasks end with it, the mode is unknown again.
        try await write(#"{"hook_event_name":"SessionEnd","session_id":"A","reason":"prompt_input_exit"}"#, at: 4)
        #expect(tab.claudeState == .notRunning)
        #expect(tab.permissionMode == nil)
        #expect(tab.runningBackgroundTasks == 0)
    }
}

struct AgentsListingTests {
    @Test func parsesPidsAndSessionIDs() throws {
        let json = #"""
            [{"pid":88843,"cwd":"/x","kind":"interactive","startedAt":1795598276568,"sessionId":"4844c92c","name":"x-f8","status":"idle"},
             {"pid":0,"sessionId":"zero"},{"pid":12,"sessionId":""},{"sessionId":"nopid"},"junk"]
            """#
        #expect(ClaudeAgentsListing.parse(Data(json.utf8)) == [.init(pid: 88843, sessionID: "4844c92c")])
        #expect(ClaudeAgentsListing.parse(Data("error: unknown command".utf8)) == nil)
    }

    @Test func runsWithTheTabsConfigFolderAndNoParentMarkers() {
        let claude = ClaudeExecutable.Location(path: "/x/claude", searchPath: ["/opt/node/bin"])
        let custom = ClaudeAgentsListing.environmentArguments(claude: claude, configDirectory: "/Users/me/.claude-work")
        #expect(custom.contains("CLAUDE_CONFIG_DIR=/Users/me/.claude-work"))
        #expect(custom.last == "PATH=/opt/node/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(custom.contains("CLAUDECODE"))
        let unset = ClaudeAgentsListing.environmentArguments(claude: claude, configDirectory: nil)
        #expect(Array(unset.suffix(3)) == ["-u", "CLAUDE_CONFIG_DIR", "PATH=/opt/node/bin:/usr/bin:/bin:/usr/sbin:/sbin"])
    }

    private let ours = "/.xylem/hooks/settings"

    @Test func aSessionOpenedFromTheResumePickerCounts() {
        let ps = """
              501 /Applications/Other.app/Contents/MacOS/Other
              777 claude
              888 claude --settings /Users/me/.xylem/hooks/settings.json --session-id x
            """
        // Only Claude Code's list knows pid 777 now runs session S.
        #expect(OpenSessionDetector.decide(sessionID: "S", processes: ps, agents: [.init(pid: 777, sessionID: "S")],
                                           ignoringLinesContaining: ours))
        // Our own previous claude (hook settings on its line) doesn't count.
        #expect(!OpenSessionDetector.decide(sessionID: "S", processes: ps, agents: [.init(pid: 888, sessionID: "S")],
                                            ignoringLinesContaining: ours))
        // A pid that is gone, another session, no list at all.
        #expect(!OpenSessionDetector.decide(sessionID: "S", processes: ps, agents: [.init(pid: 999, sessionID: "S")],
                                            ignoringLinesContaining: ours))
        #expect(!OpenSessionDetector.decide(sessionID: "S", processes: ps, agents: [.init(pid: 777, sessionID: "T")],
                                            ignoringLinesContaining: ours))
        #expect(!OpenSessionDetector.decide(sessionID: "S", processes: ps, agents: nil, ignoringLinesContaining: ours))
        // Without a ps listing an entry can't be checked against our marker:
        // not open, as a failing ps always meant.
        #expect(!OpenSessionDetector.decide(sessionID: "S", processes: nil, agents: [.init(pid: 777, sessionID: "S")],
                                            ignoringLinesContaining: ours))
    }

    @Test func aCommandLineStillCountsWithoutTheList() {
        let ps = "  42 claude --resume S\n"
        #expect(OpenSessionDetector.decide(sessionID: "S", processes: ps, agents: nil, ignoringLinesContaining: ours))
        #expect(!OpenSessionDetector.decide(sessionID: "", processes: ps, agents: [.init(pid: 42, sessionID: "")],
                                            ignoringLinesContaining: ours))
    }
}

struct SyntheticModelTests {
    /// After an API error Claude Code writes a 0-token `<synthetic>` message:
    /// the session's model and context stay those of the last real reply.
    @Test func errorMessageDoesNotReplaceTheModel() throws {
        var state = SessionStatsAccumulator()
        state.consume(["type": "assistant", "timestamp": "2026-11-27T10:00:00.000Z",
                       "message": ["id": "m1", "model": "claude-opus-5-5",
                                   "usage": ["input_tokens": 10, "cache_read_input_tokens": 90_000, "output_tokens": 5]]])
        state.consume(["type": "assistant", "timestamp": "2026-11-27T10:01:00.000Z", "isApiErrorMessage": true,
                       "message": ["id": "e1", "model": "<synthetic>",
                                   "usage": ["input_tokens": 0, "output_tokens": 0]]])
        state.finishBatch()
        let snapshot = try #require(state.snapshot())
        #expect(snapshot.modelID == "claude-opus-5-5")
        #expect(snapshot.contextUsed == 90_015)
        #expect(snapshot.lastAssistantAt == TimestampParser.parse("2026-11-27T10:00:00.000Z"))
    }
}

struct PathCacheRefreshTests {
    /// A folder resolved from a transcript is read again only once a
    /// transcript is added (its mtime moves), not on every refresh.
    @Test func transcriptAnswerFollowsTheFolderMtime() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "xylem-projects-\(UUID().uuidString)/-real-gamma", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 120).rounded(.down))
        let first = folder.appending(path: "a.jsonl")
        try #"{"cwd":"/real/gamma"}"#.write(to: first, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: first.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: folder.path)
        #expect(ClaudeProjectPathResolver.resolve(folder: folder) == "/real/gamma")

        // Unchanged folder: a refresh keeps the answer (the transcript is
        // rewritten in place, which a re-read would notice).
        try #"{"cwd":"/rewritten"}"#.write(to: first, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: first.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: folder.path)
        ClaudeProjectPathResolver.forgetChangedFolders()
        #expect(ClaudeProjectPathResolver.resolve(folder: folder) == "/real/gamma")

        // A new, newer transcript: the folder's mtime moves and it is read again.
        try #"{"cwd":"/real/gamma-moved"}"#.write(to: folder.appending(path: "b.jsonl"), atomically: true, encoding: .utf8)
        ClaudeProjectPathResolver.forgetChangedFolders()
        #expect(ClaudeProjectPathResolver.resolve(folder: folder) == "/real/gamma-moved")
    }

    /// A manual refresh re-reads a folder that got a transcript since, and
    /// keeps the answers of folders that didn't change.
    @Test func onlyChangedFoldersAreResolvedAgain() throws {
        let projects = FileManager.default.temporaryDirectory.appending(path: "xylem-projects-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: projects) }
        let changing = projects.appending(path: "-nowhere-alpha", directoryHint: .isDirectory)
        let steady = projects.appending(path: "-nowhere-beta", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: changing, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: steady, withIntermediateDirectories: true)
        try #"{"cwd":"/real/beta"}"#.write(to: steady.appending(path: "b.jsonl"), atomically: true, encoding: .utf8)
        let old = Date(timeIntervalSinceNow: -60)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: changing.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: steady.path)

        #expect(ClaudeProjectPathResolver.resolve(folder: changing) == "/nowhere/alpha")   // the dash guess
        #expect(ClaudeProjectPathResolver.resolve(folder: steady) == "/real/beta")

        // The transcript that names the real path arrives (the folder's mtime moves).
        try #"{"cwd":"/real/alpha"}"#.write(to: changing.appending(path: "a.jsonl"), atomically: true, encoding: .utf8)
        // The steady folder's transcript is rewritten in place (its folder's mtime stays).
        try #"{"cwd":"/elsewhere"}"#.write(to: steady.appending(path: "b.jsonl"), atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: steady.path)

        #expect(ClaudeProjectPathResolver.resolve(folder: changing) == "/nowhere/alpha")   // cached until a refresh
        ClaudeProjectPathResolver.forgetChangedFolders()
        #expect(ClaudeProjectPathResolver.resolve(folder: changing) == "/real/alpha")
        #expect(ClaudeProjectPathResolver.resolve(folder: steady) == "/real/beta")
    }
}
