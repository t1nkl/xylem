//
//  ClaudeTabStateTests.swift
//  XylemTests
//
//  Hook events + pty output -> what the tab shows. Event payloads are the
//  shapes captured from Claude Code 2.1.323 (pty driver).
//

import Testing
import Foundation

struct ClaudeTabEventParsingTests {
    private func parse(_ json: String) -> ClaudeTabEvent? {
        ClaudeTabEvent.parse(Data(json.utf8), at: Date(timeIntervalSince1970: 100))
    }

    @Test func readsKindSessionAndTranscript() {
        let e = parse(#"{"session_id":"s1","transcript_path":"/t/s1.jsonl","cwd":"/p","hook_event_name":"SessionStart","source":"clear"}"#)
        #expect(e?.kind == .sessionStart(source: "clear"))
        #expect(e?.switchesSession == true)
        #expect(e?.sessionID == "s1")
        #expect(e?.transcriptPath == "/t/s1.jsonl")
        #expect(e?.time == Date(timeIntervalSince1970: 100))
    }

    @Test func mapsEveryEvent() {
        #expect(parse(#"{"hook_event_name":"UserPromptSubmit","prompt":"hi"}"#)?.kind == .promptSubmitted)
        #expect(parse(#"{"hook_event_name":"SessionStart","source":"startup"}"#)?.switchesSession == false)
        #expect(parse(#"{"hook_event_name":"SessionStart","source":"resume"}"#)?.switchesSession == true)
        #expect(parse(#"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#)?.kind == .toolActivity)
        #expect(parse(#"{"hook_event_name":"PostToolUse","tool_name":"Bash"}"#)?.kind == .toolActivity)
        #expect(parse(#"{"hook_event_name":"Stop","stop_hook_active":false}"#)?.kind == .stop)
        #expect(parse(#"{"hook_event_name":"SessionEnd","reason":"clear"}"#)?.kind == .sessionEnd(reason: "clear"))
        #expect(parse(#"{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission"}"#)?.kind
                == .needsInput(message: "Claude needs your permission"))
        #expect(parse(#"{"hook_event_name":"Notification","notification_type":"idle_prompt"}"#)?.kind == .idlePrompt)
        #expect(parse(#"{"hook_event_name":"Notification","notification_type":"auth_success"}"#)?.kind == .other)
    }

    @Test func rejectsGarbage() {
        #expect(parse("not json") == nil)
        #expect(parse(#"{"session_id":"s1"}"#) == nil)
    }
}

struct ClaudeTabStateResolveTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func event(_ kind: ClaudeTabEvent.Kind, at offset: TimeInterval = 0) -> ClaudeTabEvent {
        ClaudeTabEvent(kind: kind, sessionID: "s", transcriptPath: nil, time: t0.addingTimeInterval(offset))
    }

    /// Spinner-like output: a batch every 0.1 s over [from, to].
    private func spinner(_ from: TimeInterval, _ to: TimeInterval, input: TimeInterval? = nil) -> TerminalActivitySnapshot {
        let times = stride(from: from, through: to, by: 0.1).map { t0.addingTimeInterval($0) }
        return TerminalActivitySnapshot(lastInput: input.map { t0.addingTimeInterval($0) }, outputTimes: Array(times.suffix(32)))
    }

    private let silent = TerminalActivitySnapshot()

    private func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

    @Test func promptIsWorkingAtOnceThenFollowsTheSpinner() {
        #expect(ClaudeTabState.resolve(event: event(.promptSubmitted), activity: silent, now: at(1)) == .working)
        #expect(ClaudeTabState.resolve(event: event(.promptSubmitted), activity: spinner(5, 20), now: at(20)) == .working)
        // Esc: no hook, the spinner stops -> idle (not "finished": nothing to look at).
        #expect(ClaudeTabState.resolve(event: event(.toolActivity), activity: spinner(5, 10), now: at(15)) == .idle)
        // ...and stays idle for that turn even if output comes back.
        #expect(ClaudeTabState.resolve(event: event(.toolActivity), activity: spinner(25, 30), now: at(30), interrupted: true) == .idle)
    }

    @Test func typingDuringATurnKeepsItWorking() {
        // Keystrokes every 0.5 s: their echo windows swallow the spinner.
        let typing = TerminalActivitySnapshot(lastInput: at(29.8), outputTimes: [])
        #expect(ClaudeTabState.resolve(event: event(.toolActivity), activity: typing, now: at(30)) == .working)
        // Stopped typing, spinner back: working; spinner gone: Esc.
        #expect(ClaudeTabState.resolve(event: event(.toolActivity), activity: spinner(28, 34, input: 27), now: at(34)) == .working)
        #expect(ClaudeTabState.resolve(event: event(.toolActivity), activity: TerminalActivitySnapshot(lastInput: at(27)), now: at(34)) == .idle)
    }

    @Test func escThenSwitchingAwayIsIdle() {
        // Checked live: Esc, then another tab within 0.5 s. The background
        // tab is silent, so the turn reads as interrupted, focus or not.
        let background = TerminalActivitySnapshot(lastInput: at(10), isFocused: false, focusChangedAt: at(10.5))
        #expect(ClaudeTabState.resolve(event: event(.toolActivity), activity: background, now: at(14)) == .idle)
        // A background tab whose turn runs keeps its spinner (~15 per 1.5 s).
        var running = spinner(20, 30)
        running.isFocused = false
        #expect(ClaudeTabState.resolve(event: event(.toolActivity), activity: running, now: at(30)) == .working)
    }

    @Test func focusReportsAreNotInput() {
        let monitor = TerminalActivityMonitor()
        monitor.noteSent([0x1B, 0x5B, 0x4F][...], at: at(1))
        var snap = monitor.snapshot()
        #expect(!snap.isFocused && snap.lastInput == nil && snap.focusChangedAt == at(1))
        monitor.noteSent([0x1B, 0x5B, 0x49][...], at: at(2))
        monitor.noteSent(Array("y".utf8)[...], at: at(3))
        snap = monitor.snapshot()
        #expect(snap.isFocused && snap.lastInput == at(3))
    }

    /// The terminal's replies to Claude Code's startup queries (bytes from a
    /// live log) are not the user typing; keys still are.
    @Test func terminalRepliesAreNotInput() {
        let monitor = TerminalActivityMonitor()
        let replies: [String] = [
            "\u{1B}P>|SwiftTerm 1.99.3\u{1B}\\",       // XTVERSION
            "\u{1B}[?0u",                                 // kitty flags
            "\u{1B}]7501;?\u{07}",                       // OSC
            "\u{1B}[?65;4;1;2;6;21;22;17;28c",            // DA1
            "\u{1B}[?2026;2$y",                           // DECRPM
            "\u{1B}_Gi=31;OK\u{1B}\\",                  // kitty graphics
            "\u{1B}[6;34;14t"                             // window size
        ]
        for reply in replies { monitor.noteSent(Array(reply.utf8)[...], at: at(1)) }
        #expect(monitor.snapshot().lastInput == nil)
        for key in ["\u{1B}[99;5u", "\u{1B}[A", "\u{1B}[3~", "x"] {
            monitor.noteSent(Array(key.utf8)[...], at: at(2))
            #expect(monitor.snapshot().lastInput == at(2), "\(key.debugDescription)")
            monitor.noteInput(at: at(0))
        }
    }

    /// Claude Code tracks every pointer motion; hovering is not an answer.
    @Test func pointerMotionAndWheelAreNotInputButClicksAre() {
        let monitor = TerminalActivityMonitor()
        let sgr = { (s: String) in Array(("\u{1B}[<" + s).utf8)[...] }
        monitor.noteSent(sgr("35;10;5M"), at: at(1))          // motion, no button
        monitor.noteSent(sgr("32;10;5M"), at: at(1))          // drag with left button
        monitor.noteSent(sgr("64;10;5M"), at: at(1))          // wheel up
        monitor.noteSent([0x1B, 0x5B, 0x4D, 32 + 35, 40, 40][...], at: at(1))   // legacy motion
        #expect(monitor.snapshot().lastInput == nil)
        monitor.noteSent(sgr("0;10;5M"), at: at(2))           // left press
        #expect(monitor.snapshot().lastInput == at(2))
        monitor.noteSent(sgr("0;10;5m"), at: at(3))           // release
        #expect(monitor.snapshot().lastInput == at(3))
        // Text that happens to start like a report still counts.
        monitor.noteSent(Array("\u{1B}[<x".utf8)[...], at: at(4))
        #expect(monitor.snapshot().lastInput == at(4))
    }

    @Test func stopIsTheUsersMoveUnlessTheTurnGoesOn() {
        // The final redraw right after Stop doesn't count.
        #expect(ClaudeTabState.resolve(event: event(.stop), activity: spinner(-3, 0.5), now: at(2)) == .finished)
        #expect(ClaudeTabState.resolve(event: event(.stop), activity: silent, now: at(60)) == .finished)
        // /goal keeps going after Stop: the spinner is back.
        #expect(ClaudeTabState.resolve(event: event(.stop), activity: spinner(2, 6), now: at(6)) == .working)
        // idle_prompt is never stored; alone it is idle, not finished.
        #expect(ClaudeTabState.resolve(event: event(.idlePrompt), activity: silent, now: at(1)) == .idle)
    }

    @Test func permissionWaitsForTheUsersAnswerNotForSilence() {
        let ask = event(.needsInput(message: "Claude needs your permission"))
        // The permission prompt itself keeps redrawing: still waiting.
        #expect(ClaudeTabState.resolve(event: ask, activity: spinner(1, 8), now: at(8))
                == .needsInput(message: "Claude needs your permission"))
        // Answered in the tab, tool running: working.
        #expect(ClaudeTabState.resolve(event: ask, activity: spinner(9, 12, input: 8.5), now: at(12)) == .working)
        // Answered (denied) and quiet: idle.
        #expect(ClaudeTabState.resolve(event: ask, activity: TerminalActivitySnapshot(lastInput: at(8.5)), now: at(12)) == .idle)
    }

    @Test func sessionLifecycle() {
        #expect(ClaudeTabState.resolve(event: event(.sessionStart(source: "startup")), activity: silent, now: at(1)) == .idle)
        #expect(ClaudeTabState.resolve(event: event(.sessionEnd(reason: "clear")), activity: silent, now: at(1)) == .idle)
        #expect(ClaudeTabState.resolve(event: event(.sessionEnd(reason: "resume")), activity: silent, now: at(1)) == .idle)
        #expect(ClaudeTabState.resolve(event: event(.sessionEnd(reason: "prompt_input_exit")), activity: silent, now: at(1)) == .notRunning)
    }

    @Test func attentionOnlyWhenEnteredUnseenAndUntilSeen() {
        // Entered while looking elsewhere.
        #expect(ClaudeTabState.attention(previous: false, from: .working, to: .finished, isSeen: false))
        // Entered while looking at it: never marked, even after looking away.
        #expect(!ClaudeTabState.attention(previous: false, from: .working, to: .finished, isSeen: true))
        #expect(!ClaudeTabState.attention(previous: false, from: .finished, to: .finished, isSeen: false))
        // Kept until seen; dropped when seen or when Claude works again.
        #expect(ClaudeTabState.attention(previous: true, from: .finished, to: .finished, isSeen: false))
        #expect(!ClaudeTabState.attention(previous: true, from: .finished, to: .finished, isSeen: true))
        #expect(!ClaudeTabState.attention(previous: true, from: .finished, to: .working, isSeen: false))
        // Finished -> asks permission: a new reason to look.
        #expect(ClaudeTabState.attention(previous: false, from: .finished, to: .needsInput(message: nil), isSeen: false))
    }

    @Test func echoOfTypingIsNotOutput() {
        let monitor = TerminalActivityMonitor()
        monitor.noteInput(at: at(0))
        monitor.noteOutput(at: at(0.1))     // echo
        monitor.noteOutput(at: at(1.5))     // Claude
        #expect(monitor.snapshot().outputTimes == [at(1.5)])
        for i in 0..<40 { monitor.noteOutput(at: at(2 + Double(i) * 0.1)) }
        #expect(monitor.snapshot().outputTimes.count == 32)
    }

    /// A resize SIGWINCHes the program; its redraw is not Claude working.
    @Test func redrawAfterAResizeIsNotOutput() {
        let monitor = TerminalActivityMonitor()
        monitor.noteResize(at: at(10))
        for i in 0..<9 { monitor.noteOutput(at: at(10 + Double(i) * 0.1)) }
        #expect(monitor.snapshot().outputTimes.isEmpty)
        // A Stop at 7: the redraw never turns "finished" back into working.
        #expect(ClaudeTabState.resolve(event: event(.stop, at: 7), activity: monitor.snapshot(), now: at(10.9)) == .finished)
        monitor.noteOutput(at: at(11.2))
        #expect(monitor.snapshot().outputTimes == [at(11.2)])
    }

    @Test func idlePromptNeverMakesATabFinished() {
        #expect(!event(.idlePrompt).carriesState)
        #expect(!event(.other).carriesState)
        #expect(event(.stop).carriesState)
        #expect(event(.needsInput(message: nil)).carriesState)
        #expect(ClaudeTabState.resolve(event: event(.idlePrompt), activity: silent, now: at(70)) == .idle)
    }

    /// A resize mid-turn drops the spinner's redraw for a moment; that
    /// silence must not read as Esc (the tab would go idle for the turn).
    @Test func aResizeMidTurnKeepsTheTabWorking() {
        let monitor = TerminalActivityMonitor()
        for i in 0..<20 { monitor.noteOutput(at: at(20 + Double(i) * 0.1)) }
        monitor.noteResize(at: at(22))
        for i in 0..<15 { monitor.noteOutput(at: at(22 + Double(i) * 0.1)) }
        let turn = event(.toolActivity, at: 10)
        #expect(ClaudeTabState.resolve(event: turn, activity: monitor.snapshot(), now: at(23.4)) == .working)
        // Real silence long after the resize is still an interrupt.
        #expect(ClaudeTabState.resolve(event: turn, activity: monitor.snapshot(), now: at(30)) == .idle)
    }

    @Test func aBannerOncePerHookEvent() {
        let stop = event(.stop, at: 10)
        var memory = AttentionAnnouncements()
        #expect(memory.allows(.finished, event: stop, lastPromptAt: at(1)))
        memory.record(stop)
        #expect(memory.announced(stop))
        // Same Stop again (mark seen, state flipped on output): silent.
        #expect(!memory.allows(.finished, event: stop, lastPromptAt: at(1)))
        // A permission question: once per Notification event.
        let ask = event(.needsInput(message: "m"), at: 20)
        #expect(memory.allows(.needsInput(message: "m"), event: ask, lastPromptAt: at(1)))
        memory.record(ask)
        #expect(!memory.allows(.needsInput(message: "m"), event: ask, lastPromptAt: at(1)))
        #expect(memory.allows(.needsInput(message: "m"), event: event(.needsInput(message: "m"), at: 25), lastPromptAt: at(1)))
        // Only a Stop announces "finished"; an idle prompt or other kinds never.
        #expect(!memory.allows(.finished, event: event(.idlePrompt, at: 70), lastPromptAt: at(60)))
        #expect(!memory.allows(.working, event: event(.toolActivity, at: 30), lastPromptAt: at(1)))
    }

    /// Design choice: a turn Claude starts on its own finishes silently once
    /// the user knows about the previous Stop (a banner, or watched it land);
    /// `/goal`'s in-between Stops nobody saw settle don't count, so its end
    /// still announces.
    @Test func finishedNeedsAHumanPromptSinceTheLastKnownStop() {
        var memory = AttentionAnnouncements()
        // The first Stop of a tab announces, prompt or not.
        #expect(memory.allows(.finished, event: event(.stop, at: 10), lastPromptAt: at(1)))
        // /goal: Stops at 10 and 20 went by unseen; its end at 40 announces.
        #expect(memory.allows(.finished, event: event(.stop, at: 40), lastPromptAt: at(1)))
        memory.record(event(.stop, at: 40))
        // A background task's turn after that banner: silent.
        #expect(!memory.allows(.finished, event: event(.stop, at: 60), lastPromptAt: at(1)))
        // Watched landing counts as known too.
        memory.watched(event(.stop, at: 60))
        #expect(!memory.allows(.finished, event: event(.stop, at: 80), lastPromptAt: at(50)))
        // The human typed after it: announced.
        #expect(memory.allows(.finished, event: event(.stop, at: 80), lastPromptAt: at(70)))
        // Prompts unknowable (a claude with older hook settings): every Stop
        // announces once rather than a real turn going silent.
        #expect(memory.allows(.finished, event: event(.stop, at: 80), lastPromptAt: nil))
    }
}

@MainActor
struct ClaudeHookBridgeTests {
    @Test func installWritesARunnableHookThatKeepsTheLatestEvent() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "xylem-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsPath = try #require(ClaudeHookBridge.install(root: root, userSettings: NoClaudeSettings()))

        // settings.json routes every event to the script.
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: settingsPath))) as? [String: Any]
        let hooks = try #require(settings?["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(ClaudeHookBridge.events))
        func command(_ event: String) -> String? {
            ((hooks[event] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String
        }
        #expect(command("UserPromptSubmit")?.hasSuffix(" prompt") == true)
        #expect(command("Stop")?.hasSuffix("tab-event.sh'") == true)

        let script = root.appending(path: "hooks/tab-event.sh").path
        let events = root.appending(path: "tab-events")
        let tab = UUID()
        func run(_ json: String, tabID: String?, arguments: [String] = []) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script] + arguments
            var env = ["PATH": "/usr/bin:/bin"]
            if let tabID { env[ClaudeHookBridge.environmentKey] = tabID }
            process.environment = env
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            input.fileHandleForWriting.write(Data(json.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            // Silent: hook stdout could reach Claude.
            #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
        }

        try run(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1"}"#, tabID: tab.uuidString, arguments: ["prompt"])
        try run(#"{"hook_event_name":"Stop","session_id":"s1"}"#, tabID: tab.uuidString)
        let event = ClaudeHookBridge.latestEvent(forTab: tab, in: events)
        #expect(event?.kind == .stop)
        #expect(event?.sessionID == "s1")
        // The prompt left its marker even though the Stop replaced its event.
        #expect(ClaudeHookBridge.lastPrompt(forTab: tab, in: events)?.sessionID == "s1")

        // No tab id, or a hostile one: nothing written, still exit 0.
        try run(#"{"hook_event_name":"Stop"}"#, tabID: nil)
        try run(#"{"hook_event_name":"Stop"}"#, tabID: "../x")
        let files = try FileManager.default.contentsOfDirectory(atPath: events.path)
        #expect(Set(files) == ["\(tab.uuidString).json", "\(tab.uuidString).prompt"])

        // A folder it can't write to (permissions, full disk): still exit 0,
        // or Claude would show the user a hook error on every prompt.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: events.path)
        try run(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1"}"#, tabID: UUID().uuidString, arguments: ["prompt"])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: events.path)

        // A closed tab's file (recreated by its dying claude) is pruned once
        // it has been quiet for a while; a live tab's file never is.
        let other = UUID()
        try run(#"{"hook_event_name":"SessionEnd","session_id":"s9"}"#, tabID: other.uuidString)
        ClaudeHookBridge.pruneEvents(keeping: [tab], in: events, now: Date())
        #expect(ClaudeHookBridge.latestEvent(forTab: other, in: events) != nil)   // too fresh
        ClaudeHookBridge.pruneEvents(keeping: [tab], in: events, now: Date().addingTimeInterval(60))
        #expect(ClaudeHookBridge.latestEvent(forTab: other, in: events) == nil)
        #expect(ClaudeHookBridge.latestEvent(forTab: tab, in: events) != nil)

        ClaudeHookBridge.removeEvents(forTab: tab, in: events)
        #expect(ClaudeHookBridge.latestEvent(forTab: tab, in: events) == nil)
        #expect(ClaudeHookBridge.lastPrompt(forTab: tab, in: events) == nil)
    }

    @Test func notificationTextAndRowLine() {
        #expect(AttentionNotifier.body(for: .finished, lastPrompt: "fix the build") == "Claude finished: fix the build")
        #expect(AttentionNotifier.body(for: .finished, lastPrompt: nil) == "Claude finished")
        #expect(AttentionNotifier.body(for: .needsInput(message: "Claude needs your permission"), lastPrompt: "x")
                == "Claude needs your permission")
        #expect(AttentionNotifier.body(for: .working, lastPrompt: "x") == nil)
        #expect(TabRowText.needsInputLine("Claude needs your permission") == "Needs your permission")
        #expect(TabRowText.needsInputLine(nil) == "Needs your input")
    }
}

@MainActor
struct SessionBindingTests {
    /// `/usr/bin/true` stands in for claude: the shell runs it and moves on,
    /// so the tabs get real bindings without launching Claude Code.
    private static func factory() -> TerminalSessionFactory {
        TerminalSessionFactory(
            autoStartClaude: { true },
            claudeBinaryPath: { "/usr/bin/true" },
            continueLastSession: { true },
            hookSettingsPath: { nil },
            sessionExists: { _, _ in true }
        )
    }

    @Test func restoredTabsResumeTheirSessionAndADuplicateStartsFresh() {
        let store = StubTabsStore()
        store.seed = PersistedTabsState(
            tabs: [
                PersistedTab(id: UUID(), title: "a", workingDirectory: "/tmp", claudeSessionID: "s-1"),
                PersistedTab(id: UUID(), title: "b", workingDirectory: "/tmp", claudeSessionID: "s-1")
            ],
            activeTabID: nil
        )
        let vm = TabsViewModel(store: store, sessionFactory: Self.factory())
        defer { vm.tabs.forEach { $0.session?.close() } }
        #expect(vm.tabs[0].claudeSessionID == "s-1")
        #expect(vm.tabs[0].session?.configuration.initialCommand == ["/usr/bin/true", "--resume", "s-1"])
        #expect(vm.tabs[1].claudeSessionID != "s-1")
        #expect(vm.tabs[1].session?.configuration.initialCommand?.contains("--session-id") == true)
        // The shell knows its tab, for the hook script.
        #expect(vm.tabs[0].session?.configuration.environment[ClaudeHookBridge.environmentKey] == vm.tabs[0].id.uuidString)
    }

    @Test func bindingIsPersisted() throws {
        let store = StubTabsStore()
        store.seed = PersistedTabsState(
            tabs: [PersistedTab(id: UUID(), title: "a", workingDirectory: "/tmp", claudeSessionID: "s-9")],
            activeTabID: nil
        )
        let vm = TabsViewModel(store: store, sessionFactory: Self.factory())
        defer { vm.tabs.forEach { $0.session?.close() } }
        vm.tabs[0].claudeSessionID = "s-10"     // e.g. /clear
        vm.sessionBindingChanged()
        vm.flushPersistence()
        #expect(store.saved.last?.tabs.first?.claudeSessionID == "s-10")
    }

    @Test func restoreWritesTheBindingsAtOnce() {
        let store = StubTabsStore()
        store.seed = PersistedTabsState(
            tabs: [PersistedTab(id: UUID(), title: "a", workingDirectory: "/tmp")],
            activeTabID: nil
        )
        var f = Self.factory()
        f.newestSessionID = { _, _ in "picked" }    // one-time migration
        let vm = TabsViewModel(store: store, sessionFactory: f)
        defer { vm.tabs.forEach { $0.session?.close() } }
        #expect(vm.tabs[0].claudeSessionID == "picked")
        #expect(store.saved.last?.tabs.first?.claudeSessionID == "picked")
    }

    @Test func olderStateFilesStillDecode() throws {
        let json = #"{"tabs":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"x","workingDirectory":"/tmp"}]}"#
        let state = try JSONDecoder().decode(PersistedTabsState.self, from: Data(json.utf8))
        #expect(state.tabs.first?.claudeSessionID == nil)
    }
}

final class StubTabsStore: TabsStateStoring {
    var seed: PersistedTabsState?
    var saved: [PersistedTabsState] = []
    func load() -> PersistedTabsState? { seed }
    func save(_ state: PersistedTabsState) { saved.append(state) }
}

@MainActor
final class FakeNotifier: AttentionNotifying {
    var badge = 0
    var announced: [(UUID, ClaudeTabState)] = []
    var withdrawn: [UUID] = []
    func setBadgeCount(_ count: Int) { badge = count }
    func announce(tabID: UUID, title: String, state: ClaudeTabState, lastPrompt: String?) { announced.append((tabID, state)) }
    func withdraw(tabID: UUID) { withdrawn.append(tabID) }
}

@MainActor
struct ClaudeTabStateTrackerTests {
    private func write(_ json: String, tab: UUID, in dir: URL, at time: Date) throws {
        let url = ClaudeHookBridge.eventFile(forTab: tab, in: dir)
        try Data(json.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: url.path)
    }

    @Test func bindingFollowsOwnSessionOnlyAndFinishedIsAnnouncedOnce() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "xylem-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tabID = UUID()
        let session = TerminalSessionFactory(autoStartClaude: { false }).makeSession(tabID: tabID, title: "t", directory: "/tmp")
        defer { session.close() }
        let tab = TerminalTab(id: tabID, title: "t", state: .session(session))
        tab.claudeSessionID = "A"
        let notifier = FakeNotifier()
        let tracker = ClaudeTabStateTracker(eventsDirectory: dir, notifier: notifier, hooksInstalled: true, rememberVersion: { _ in }, accountConfigFile: { nil })
        var bindingChanges = 0
        tracker.onBindingChange = { bindingChanges += 1 }
        let start = Date()

        // Another claude under this tab (e.g. a teammate): ignored.
        try write(#"{"hook_event_name":"UserPromptSubmit","session_id":"B"}"#, tab: tabID, in: dir, at: start.addingTimeInterval(1))
        await tracker.refresh(tabs: [tab], activeTabID: nil, appIsActive: false, now: start.addingTimeInterval(2))
        #expect(tab.claudeSessionID == "A")
        #expect(tab.claudeState == nil)

        // /clear: the tab moves to the new session.
        try write(#"{"hook_event_name":"SessionStart","source":"clear","session_id":"C","transcript_path":"/t/C.jsonl"}"#,
                  tab: tabID, in: dir, at: start.addingTimeInterval(3))
        await tracker.refresh(tabs: [tab], activeTabID: nil, appIsActive: false, now: start.addingTimeInterval(4))
        #expect(tab.claudeSessionID == "C")
        #expect(tab.transcriptPath == "/t/C.jsonl")
        #expect(tab.claudeState == .idle)
        #expect(bindingChanges == 1)

        // Finished while the tab is not on screen: marked, badged, announced once.
        try write(#"{"hook_event_name":"Stop","session_id":"C"}"#, tab: tabID, in: dir, at: start.addingTimeInterval(5))
        await tracker.refresh(tabs: [tab], activeTabID: nil, appIsActive: false, now: start.addingTimeInterval(20))
        #expect(tab.claudeState == .finished)
        #expect(tab.needsAttention)
        #expect(notifier.badge == 1)
        #expect(notifier.announced.isEmpty)   // not held long enough yet
        await tracker.refresh(tabs: [tab], activeTabID: nil, appIsActive: false, now: start.addingTimeInterval(23))
        await tracker.refresh(tabs: [tab], activeTabID: nil, appIsActive: false, now: start.addingTimeInterval(24))
        #expect(notifier.announced.count == 1)

        // Looked at: mark, badge and banner go.
        await tracker.refresh(tabs: [tab], activeTabID: tabID, appIsActive: true, now: start.addingTimeInterval(25))
        #expect(!tab.needsAttention)
        #expect(notifier.badge == 0)
        #expect(notifier.withdrawn == [tabID])
    }

    /// No double banners: one Stop must never announce twice - not
    /// after the mark was seen and the tab left, not after a redraw flipped
    /// it to working and back; `idle_prompt` never re-announces; a Stop with
    /// no human prompt since the last banner is silent; a new prompt (its
    /// marker) and a permission question announce once each.
    @Test func oneBannerPerHookEvent() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "xylem-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tabID = UUID()
        let session = TerminalSessionFactory(autoStartClaude: { false }).makeSession(tabID: tabID, title: "t", directory: "/tmp")
        defer { session.close() }
        let tab = TerminalTab(id: tabID, title: "t", state: .session(session))
        tab.claudeSessionID = "A"
        let notifier = FakeNotifier()
        let tracker = ClaudeTabStateTracker(eventsDirectory: dir, notifier: notifier, hooksInstalled: true, rememberVersion: { _ in }, accountConfigFile: { nil })
        let start = Date().addingTimeInterval(1)
        func at(_ offset: TimeInterval) -> Date { start.addingTimeInterval(offset) }
        func tick(_ offset: TimeInterval, seen: Bool = false) async {
            await tracker.refresh(tabs: [tab], activeTabID: seen ? tabID : nil, appIsActive: true, now: at(offset))
        }

        // This claude's hooks leave prompt markers (current settings).
        let marker = ClaudeHookBridge.promptMarker(forTab: tabID, in: dir)
        func prompt(at offset: TimeInterval) throws {
            try Data().write(to: marker)
            try FileManager.default.setAttributes([.modificationDate: at(offset)], ofItemAtPath: marker.path)
        }
        try prompt(at: 1)
        try write(#"{"hook_event_name":"Stop","session_id":"A"}"#, tab: tabID, in: dir, at: at(5))
        await tick(10)
        await tick(13)
        #expect(notifier.announced.count == 1)

        // Seen, then left: same Stop, no banner.
        tracker.markSeen(tab)
        await tick(14, seen: true)
        await tick(15)
        await tick(20)
        #expect(notifier.announced.count == 1)

        // A redraw (no resize filter in this path) flips it to working and
        // back to finished: the mark returns, the banner doesn't.
        for i in 0..<10 { session.activity.noteOutput(at: at(21 + Double(i) * 0.1)) }
        await tick(22)
        #expect(tab.claudeState == .working)
        await tick(30)
        await tick(33)
        #expect(tab.claudeState == .finished)
        #expect(tab.needsAttention)
        #expect(notifier.announced.count == 1)
        // Output flipping the state never withdraws the banner (seeing the
        // tab does, through AppModel).
        #expect(notifier.withdrawn.isEmpty)

        // idle_prompt: nothing new.
        try write(#"{"hook_event_name":"Notification","notification_type":"idle_prompt","session_id":"A"}"#, tab: tabID, in: dir, at: at(40))
        await tick(41)
        await tick(45)
        #expect(tab.claudeState == .finished)
        #expect(notifier.announced.count == 1)

        // A turn Claude started on its own (no prompt): finishes silently.
        try write(#"{"hook_event_name":"PreToolUse","session_id":"A"}"#, tab: tabID, in: dir, at: at(50))
        await tick(51)
        #expect(tab.claudeState == .working)
        try write(#"{"hook_event_name":"Stop","session_id":"A"}"#, tab: tabID, in: dir, at: at(60))
        await tick(61)
        await tick(64)
        #expect(tab.claudeState == .finished)
        #expect(notifier.announced.count == 1)

        // A permission question: once.
        try write(#"{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"m","session_id":"A"}"#,
                  tab: tabID, in: dir, at: at(70))
        await tick(71)
        await tick(74)
        await tick(75)
        #expect(notifier.announced.count == 2)

        // The human typed a new prompt (only its marker survives), then Stop: announced.
        try prompt(at: 80)
        try write(#"{"hook_event_name":"Stop","session_id":"A"}"#, tab: tabID, in: dir, at: at(90))
        await tick(91)
        await tick(94)
        #expect(notifier.announced.count == 3)
        #expect(notifier.announced.last?.1 == .finished)
    }

    /// `/goal`: its condition check continues right after the first Stop,
    /// so that Stop never settles; the real end announces once.
    @Test func goalAnnouncesItsEndNotItsCheckpoints() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "xylem-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tabID = UUID()
        let session = TerminalSessionFactory(autoStartClaude: { false }).makeSession(tabID: tabID, title: "t", directory: "/tmp")
        defer { session.close() }
        let tab = TerminalTab(id: tabID, title: "t", state: .session(session))
        tab.claudeSessionID = "A"
        let notifier = FakeNotifier()
        let tracker = ClaudeTabStateTracker(eventsDirectory: dir, notifier: notifier, hooksInstalled: true, rememberVersion: { _ in }, accountConfigFile: { nil })
        let start = Date().addingTimeInterval(1)
        func at(_ offset: TimeInterval) -> Date { start.addingTimeInterval(offset) }
        func tick(_ offset: TimeInterval) async {
            await tracker.refresh(tabs: [tab], activeTabID: nil, appIsActive: true, now: at(offset))
        }
        let marker = ClaudeHookBridge.promptMarker(forTab: tabID, in: dir)
        try Data().write(to: marker)
        try FileManager.default.setAttributes([.modificationDate: at(1)], ofItemAtPath: marker.path)

        try write(#"{"hook_event_name":"Stop","session_id":"A"}"#, tab: tabID, in: dir, at: at(5))
        await tick(6)
        for i in 0..<20 { session.activity.noteOutput(at: at(6.6 + Double(i) * 0.1)) }
        await tick(8)
        #expect(tab.claudeState == .working)
        try write(#"{"hook_event_name":"Stop","session_id":"A"}"#, tab: tabID, in: dir, at: at(20))
        await tick(21)
        await tick(24)
        #expect(tab.claudeState == .finished)
        #expect(notifier.announced.count == 1)
    }

    /// An agent-team teammate runs under the same tab id: its prompt is not
    /// the user's and doesn't allow a "finished" banner for the lead.
    @Test func aTeammatesPromptIsNotTheUsers() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "xylem-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tabID = UUID()
        let session = TerminalSessionFactory(autoStartClaude: { false }).makeSession(tabID: tabID, title: "t", directory: "/tmp")
        defer { session.close() }
        let tab = TerminalTab(id: tabID, title: "t", state: .session(session))
        tab.claudeSessionID = "A"
        let notifier = FakeNotifier()
        let tracker = ClaudeTabStateTracker(eventsDirectory: dir, notifier: notifier, hooksInstalled: true, rememberVersion: { _ in }, accountConfigFile: { nil })
        let start = Date().addingTimeInterval(1)
        func at(_ offset: TimeInterval) -> Date { start.addingTimeInterval(offset) }
        func tick(_ offset: TimeInterval) async {
            await tracker.refresh(tabs: [tab], activeTabID: nil, appIsActive: true, now: at(offset))
        }
        let marker = ClaudeHookBridge.promptMarker(forTab: tabID, in: dir)
        func prompt(_ session: String, at offset: TimeInterval) throws {
            try Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(session)"}"#.utf8).write(to: marker)
            try FileManager.default.setAttributes([.modificationDate: at(offset)], ofItemAtPath: marker.path)
        }

        try prompt("A", at: 1)
        try write(#"{"hook_event_name":"Stop","session_id":"A"}"#, tab: tabID, in: dir, at: at(5))
        await tick(6); await tick(9)
        #expect(notifier.announced.count == 1)
        // The teammate's prompt, then the lead finishes a turn it started itself.
        try prompt("T", at: 20)
        try write(#"{"hook_event_name":"Stop","session_id":"A"}"#, tab: tabID, in: dir, at: at(30))
        await tick(31); await tick(34)
        #expect(notifier.announced.count == 1)
        // The user's own prompt: the next Stop announces.
        try prompt("A", at: 40)
        try write(#"{"hook_event_name":"Stop","session_id":"A"}"#, tab: tabID, in: dir, at: at(50))
        await tick(51); await tick(54)
        #expect(notifier.announced.count == 2)
    }

    /// A claude started with older hook settings leaves no prompt marker:
    /// its prompts can be missed, so each Stop announces once instead of a
    /// real turn going silent.
    @Test func withoutPromptMarkersEveryStopAnnouncesOnce() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "xylem-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tabID = UUID()
        let session = TerminalSessionFactory(autoStartClaude: { false }).makeSession(tabID: tabID, title: "t", directory: "/tmp")
        defer { session.close() }
        let tab = TerminalTab(id: tabID, title: "t", state: .session(session))
        tab.claudeSessionID = "A"
        let notifier = FakeNotifier()
        let tracker = ClaudeTabStateTracker(eventsDirectory: dir, notifier: notifier, hooksInstalled: true, rememberVersion: { _ in }, accountConfigFile: { nil })
        let start = Date().addingTimeInterval(1)
        func tick(_ offset: TimeInterval) async {
            await tracker.refresh(tabs: [tab], activeTabID: nil, appIsActive: true, now: start.addingTimeInterval(offset))
        }

        for stop in [5.0, 30.0] {
            try write(#"{"hook_event_name":"Stop","session_id":"A"}"#, tab: tabID, in: dir, at: start.addingTimeInterval(stop))
            await tick(stop + 1)
            await tick(stop + 4)
            await tick(stop + 6)
        }
        #expect(notifier.announced.count == 2)
    }

    /// Esc (or a denied permission) left the tab idle; the idle_prompt that
    /// follows a minute later must not call it finished.
    @Test func idlePromptKeepsAnInterruptedTabIdle() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "xylem-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tabID = UUID()
        let session = TerminalSessionFactory(autoStartClaude: { false }).makeSession(tabID: tabID, title: "t", directory: "/tmp")
        defer { session.close() }
        let tab = TerminalTab(id: tabID, title: "t", state: .session(session))
        tab.claudeSessionID = "A"
        let notifier = FakeNotifier()
        let tracker = ClaudeTabStateTracker(eventsDirectory: dir, notifier: notifier, hooksInstalled: true, rememberVersion: { _ in }, accountConfigFile: { nil })
        let start = Date().addingTimeInterval(1)

        try write(#"{"hook_event_name":"UserPromptSubmit","session_id":"A"}"#, tab: tabID, in: dir, at: start.addingTimeInterval(5))
        await tracker.refresh(tabs: [tab], activeTabID: nil, appIsActive: true, now: start.addingTimeInterval(20))
        #expect(tab.claudeState == .idle)
        try write(#"{"hook_event_name":"Notification","notification_type":"idle_prompt","session_id":"A"}"#,
                  tab: tabID, in: dir, at: start.addingTimeInterval(65))
        await tracker.refresh(tabs: [tab], activeTabID: nil, appIsActive: true, now: start.addingTimeInterval(66))
        await tracker.refresh(tabs: [tab], activeTabID: nil, appIsActive: true, now: start.addingTimeInterval(70))
        #expect(tab.claudeState == .idle)
        #expect(!tab.needsAttention)
        #expect(notifier.announced.isEmpty)
    }

    /// "No, exit" at the trust question: claude ends without an event and
    /// the terminal is back at the shell - Doctor stays quiet about it.
    @Test func aTabWhoseClaudeExitedDoesNotTurnDoctorAmber() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "xylem-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tabID = UUID()
        // `/usr/bin/true` exits at once, like claude after "No, exit".
        let factory = TerminalSessionFactory(autoStartClaude: { true }, claudeBinaryPath: { "/usr/bin/true" },
                                             hookSettingsPath: { "/nonexistent/settings.json" })
        let session = factory.makeSession(tabID: tabID, title: "t", directory: "/tmp")
        defer { session.close() }
        let tab = TerminalTab(id: tabID, title: "work", state: .session(session))
        let tracker = ClaudeTabStateTracker(eventsDirectory: dir, notifier: FakeNotifier(), hooksInstalled: true, rememberVersion: { _ in }, accountConfigFile: { nil })
        let start = try #require(session.startedAt)
        session.activity.noteInput(at: start.addingTimeInterval(2))
        try await waitUntil { session.shellIsInForeground }
        await tracker.refresh(tabs: [tab], activeTabID: nil, appIsActive: false,
                              now: start.addingTimeInterval(HookBridgeHealth.silenceLimit + 30))
        #expect(tracker.hookHealth == .unknown)
    }

    /// Closing a tab ends what runs in it even when the program ignores
    /// SIGHUP and SIGTERM. Not only the shell is signalled but the foreground
    /// process group, and whatever survives is killed after a grace period.
    @Test func closingATabEndsAProgramThatIgnoresHangup() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "xylem-stubborn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stubborn = dir.appending(path: "fake-claude")
        try Data("#!/bin/sh\ntrap '' HUP TERM\nexec /bin/sleep 60\n".utf8).write(to: stubborn)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubborn.path)
        let factory = TerminalSessionFactory(autoStartClaude: { true }, claudeBinaryPath: { stubborn.path },
                                             hookSettingsPath: { "/nonexistent/settings.json" })
        let session = factory.makeSession(tabID: UUID(), title: "t", directory: "/tmp")
        try await waitUntil { session.foregroundProcessName == "sleep" }
        let group = try #require(session.foregroundProcessGroup)
        #expect(kill(-group, 0) == 0)
        session.close()
        for _ in 0..<100 where kill(-group, 0) == 0 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(kill(-group, 0) == -1, "the program of a closed tab is still running")
        kill(-group, SIGKILL)   // never leave it behind, whatever the result
    }

    /// After a PATH fix the Doctor offers to restart only tabs whose claude
    /// never started; a tab where claude ran and was quit is left alone.
    @Test func onlyTabsWhoseClaudeNeverStartedAreOfferedARestart() async throws {
        let factory = TerminalSessionFactory(autoStartClaude: { true }, claudeBinaryPath: { "/usr/bin/true" },
                                             hookSettingsPath: { "/nonexistent/settings.json" })
        let folder = FileManager.default.temporaryDirectory.appending(path: "xylem-restart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let vm = TabsViewModel(store: TabsStateStore(fileURL: folder.appending(path: "tabs.json")), sessionFactory: factory)
        let session = factory.makeSession(tabID: vm.tabs[0].id, title: "t", directory: "/tmp")
        defer { session.close() }
        vm.tabs[0].state = .session(session)
        try await waitUntil { session.shellIsInForeground }
        #expect(vm.tabsWithoutClaude().map(\.id) == [vm.tabs[0].id])
        vm.tabs[0].claudeState = .notRunning   // claude ran (events came) and was quit
        #expect(vm.tabsWithoutClaude().isEmpty)
    }

    /// Polls up to 10 s (a login shell reads the user's rc files first).
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Timed out waiting for the terminal")
    }

    /// A claude started with the hooks that never reports turns Doctor
    /// amber after the silence limit; its first event clears it. Only
    /// events of the current claude count, not one left from before.
    @Test func hookHealthFollowsTheTabsOwnEvents() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "xylem-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tabID = UUID()
        // A script that keeps running stands in for claude, with a hook
        // settings path, so the shell counts as launched with hooks without
        // running Claude Code (and Doctor sees a claude still running).
        let fakeClaude = dir.appending(path: "fake-claude")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: fakeClaude)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaude.path)
        let factory = TerminalSessionFactory(autoStartClaude: { true }, claudeBinaryPath: { fakeClaude.path },
                                             hookSettingsPath: { "/nonexistent/settings.json" })
        let session = factory.makeSession(tabID: tabID, title: "t", directory: "/tmp")
        defer { session.close() }
        let tab = TerminalTab(id: tabID, title: "work", state: .session(session))
        let tracker = ClaudeTabStateTracker(eventsDirectory: dir, notifier: FakeNotifier(), hooksInstalled: true, rememberVersion: { _ in }, accountConfigFile: { nil })
        let start = try #require(session.startedAt)
        // The fake claude (`sleep`) is in front, not the shell still starting.
        try await waitUntil { session.foregroundProcessName == "sleep" }

        session.activity.noteInput(at: start.addingTimeInterval(2))   // the user typed in it
        // An event from an earlier claude (before this shell): no proof.
        try write(#"{"hook_event_name":"Stop","session_id":"A"}"#, tab: tabID, in: dir, at: start.addingTimeInterval(-60))
        await tracker.refresh(tabs: [tab], activeTabID: nil, appIsActive: false, now: start.addingTimeInterval(10))
        #expect(tracker.hookHealth == .unknown)
        await tracker.refresh(tabs: [tab], activeTabID: nil, appIsActive: false,
                              now: start.addingTimeInterval(HookBridgeHealth.silenceLimit + 1))
        #expect(tracker.hookHealth == .silent(tabs: ["tmp"]))   // named by its folder

        try write(#"{"hook_event_name":"SessionStart","source":"startup","session_id":"A"}"#,
                  tab: tabID, in: dir, at: start.addingTimeInterval(HookBridgeHealth.silenceLimit + 2))
        await tracker.refresh(tabs: [tab], activeTabID: nil, appIsActive: false,
                              now: start.addingTimeInterval(HookBridgeHealth.silenceLimit + 3))
        #expect(tracker.hookHealth == .reporting)
        #expect(tracker.lastHookEventAt != nil)
    }
}
