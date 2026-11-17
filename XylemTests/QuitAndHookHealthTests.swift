//
//  QuitAndHookHealthTests.swift
//  XylemTests
//
//  ⌘Q asks only when a tab would lose work; Doctor judges the hook bridge
//  by whether events arrive, and names the settings that switch it off.
//

import Testing
import Foundation

@MainActor
struct QuitConfirmationTests {
    private func tab(_ title: String, _ state: ClaudeTabState?, busy: Bool = false) -> TerminalTab {
        let tab = TerminalTab(title: title, state: .picker)
        tab.claudeState = state
        tab.isBusy = busy
        return tab
    }

    @Test func nothingToLoseQuitsWithoutAsking() {
        let tabs = [tab("a", .idle), tab("b", .finished), tab("c", .notRunning), tab("d", nil)]
        #expect(QuitConfirmation(tabs: tabs) == nil)
    }

    @Test func workingAndWaitingTabsAreNamed() throws {
        let tabs = [tab("api", .working), tab("web", .needsInput(message: nil)), tab("docs", .idle)]
        let confirmation = try #require(QuitConfirmation(tabs: tabs))
        #expect(confirmation.working == ["api"])
        #expect(confirmation.waiting == ["web"])
        #expect(confirmation.title == "Claude is busy in 2 tabs")
        #expect(confirmation.message.contains("Working: api"))
        #expect(confirmation.message.contains("Waiting for you: web"))
    }

    @Test func withoutHooksTheTranscriptBusyFlagCounts() throws {
        let confirmation = try #require(QuitConfirmation(tabs: [tab("x", nil, busy: true)]))
        #expect(confirmation.title == "Claude is still working in 1 tab")
    }

    @Test func aStaleBusyFlagDoesNotOverrideHookState() {
        // Hook state wins: idle at the prompt even if the flag lags a tick.
        #expect(QuitConfirmation(tabs: [tab("x", .idle, busy: true)]) == nil)
    }
}

struct HookBridgeHealthTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// `typed`: seconds ago the user last typed in the tab (nil = never).
    private func probe(_ title: String, hooks: Bool = true, age: TimeInterval, event: Bool,
                       typed: TimeInterval? = 30) -> HookBridgeHealth.Probe {
        HookBridgeHealth.Probe(title: title, launchedWithHooks: hooks,
                               startedAt: now.addingTimeInterval(-age),
                               lastEventAt: event ? now.addingTimeInterval(-1) : nil,
                               lastInputAt: typed.map { now.addingTimeInterval(-$0) })
    }

    @Test func notInstalledWinsOverEverything() {
        #expect(HookBridgeHealth.evaluate(installed: false, probes: [probe("a", age: 5, event: true)], now: now) == .notInstalled)
    }

    @Test func tooEarlyToJudge() {
        #expect(HookBridgeHealth.evaluate(installed: true, probes: [], now: now) == .unknown)
        #expect(HookBridgeHealth.evaluate(installed: true, probes: [probe("a", age: 10, event: false)], now: now) == .unknown)
        // A bare shell (no hooks) proves nothing either way.
        #expect(HookBridgeHealth.evaluate(installed: true, probes: [probe("a", hooks: false, age: 600, event: false)], now: now) == .unknown)
    }

    @Test func anUntouchedTabProvesNothing() {
        // e.g. Claude Code's "trust this folder?" question: no hook fires
        // until it is answered.
        #expect(HookBridgeHealth.evaluate(installed: true, probes: [probe("a", age: 600, event: false, typed: nil)], now: now) == .unknown)
        // Just answered / typing: give the hook a moment.
        #expect(HookBridgeHealth.evaluate(installed: true, probes: [probe("a", age: 600, event: false, typed: 3)], now: now) == .unknown)
    }

    @Test func aTabWhoseClaudeExitedIsNotJudged() {
        // "No, exit" at the trust question: typed in, long past the limit,
        // no event - but the terminal is back at the shell.
        var gone = probe("a", age: 600, event: false)
        gone.claudeRunning = false
        #expect(HookBridgeHealth.evaluate(installed: true, probes: [gone], now: now) == .unknown)
    }

    @Test func shellNames() {
        #expect(TerminalSession.isShell("zsh"))
        #expect(TerminalSession.isShell("-zsh"))
        #expect(TerminalSession.isShell("fish"))
        #expect(!TerminalSession.isShell("claude"))
        #expect(!TerminalSession.isShell("node"))
        #expect(!TerminalSession.isShell(nil))
        // A live process has a name (the test runner itself).
        #expect(TerminalSession.processName(getpid()) != nil)
    }

    @Test func silentPastTheLimit() {
        let health = HookBridgeHealth.evaluate(installed: true, probes: [probe("a", age: 61, event: false)], now: now)
        #expect(health == .silent(tabs: ["a"]))
        #expect(health.isProblem)
    }

    @Test func reportingTabProvesTheBridgeButAQuietOneIsStillNamed() {
        #expect(HookBridgeHealth.evaluate(installed: true, probes: [probe("a", age: 600, event: true)], now: now) == .reporting)
        let mixed = HookBridgeHealth.evaluate(installed: true,
                                              probes: [probe("a", age: 600, event: true), probe("b", age: 90, event: false)],
                                              now: now)
        #expect(mixed == .silent(tabs: ["b"]))
    }

    @Test func blockersAreFoundInEveryLayer() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "xylem-blockers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home")
        let project = root.appending(path: "proj")
        let managed = root.appending(path: "managed-settings.json")
        try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appending(path: ".claude"), withIntermediateDirectories: true)
        try Data(#"{"disableAllHooks": true}"#.utf8).write(to: home.appending(path: ".claude/settings.json"))
        try Data(#"{"disableAllHooks": false}"#.utf8).write(to: project.appending(path: ".claude/settings.json"))
        try Data(#"{"disableAllHooks": true}"#.utf8).write(to: project.appending(path: ".claude/settings.local.json"))
        try Data(#"{"allowManagedHooksOnly": true}"#.utf8).write(to: managed)

        let reasons = HookBlockers.find(projectDirectory: project.path,
                                        userSettings: home.appending(path: ".claude/settings.json"),
                                        home: home, managed: managed)
        #expect(reasons == [
            "disableAllHooks in ~/.claude/settings.json",
            "disableAllHooks in \(project.path)/.claude/settings.local.json",
            "allowManagedHooksOnly in \(managed.path)"
        ])
        #expect(HookBlockers.find(projectDirectory: nil, userSettings: root.appending(path: "none.json"),
                                  home: root, managed: root.appending(path: "none")).isEmpty)
    }
}
