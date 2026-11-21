//
//  LiveStatusAndFailureTests.swift
//  XylemTests
//
//  The status line input's context and plan limits, the "stopped on an API
//  error" tab state (StopFailure), the hook settings per Claude Code version
//  and the next-waiting-tab order. Payload shapes are those of Claude Code
//  2.1.329, with made-up values.
//

import Testing
import Foundation

struct LiveStatusParsingTests {
    private func parse(_ json: String, at time: TimeInterval = 100) -> ClaudeLiveStatus? {
        ClaudeLiveStatus.parse(Data(json.utf8), at: Date(timeIntervalSince1970: time))
    }

    @Test func readsContextNumbers() throws {
        let status = try #require(parse(#"""
            {"version":"2.1.329","session_id":"s","context_window":{"total_input_tokens":250000,"total_output_tokens":8,
             "context_window_size":1000000,"current_usage":{"input_tokens":4},"used_percentage":25,"remaining_percentage":75}}
            """#))
        #expect(status.context == .init(usedPercentage: 25, usedTokens: 250_000, size: 1_000_000))
        #expect(status.rateLimits == nil)
    }

    /// Before the first reply and after /compact: null percentage.
    @Test func nullPercentageIsUnknown() throws {
        let status = try #require(parse(#"""
            {"version":"2.1.329","context_window":{"total_input_tokens":0,"context_window_size":200000,
             "current_usage":null,"used_percentage":null,"remaining_percentage":null}}
            """#))
        #expect(status.context == .init(usedPercentage: nil, usedTokens: 0, size: 200_000))
    }

    @Test func readsOneOrBothLimitWindows() throws {
        let week = try #require(parse(#"{"version":"2.1.329","rate_limits":{"seven_day":{"used_percentage":44,"resets_at":1800000000}}}"#))
        #expect(week.rateLimits == .init(fiveHour: nil,
                                         sevenDay: .init(usedPercentage: 44, resetsAt: Date(timeIntervalSince1970: 1_800_000_000))))
        let both = try #require(parse(#"""
            {"version":"2.1.329","rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1800000100.5},
             "seven_day":{"used_percentage":44,"resets_at":1800000000}}}
            """#))
        #expect(both.rateLimits?.fiveHour == .init(usedPercentage: 23.5, resetsAt: Date(timeIntervalSince1970: 1_800_000_100.5)))
        #expect(both.rateLimits?.sevenDay?.usedPercentage == 44)
    }

    @Test func oddLimitShapesAreDropped() {
        #expect(parse(#"{"version":"2.1.329","rate_limits":null}"#)?.rateLimits == nil)
        #expect(parse(#"{"version":"2.1.329","rate_limits":{}}"#)?.rateLimits == nil)
        // No percentage: nothing to show.
        #expect(parse(#"{"version":"2.1.329","rate_limits":{"seven_day":{"resets_at":1800000000}}}"#)?.rateLimits == nil)
        #expect(parse(#"{"version":"2.1.329","rate_limits":{"seven_day":{"used_percentage":"44"}}}"#)?.rateLimits == nil)
        #expect(parse(#"{"version":"2.1.329","rate_limits":{"seven_day":{"used_percentage":true}}}"#)?.rateLimits == nil)
        // A window without a reset time still shows.
        #expect(parse(#"{"version":"2.1.329","rate_limits":{"five_hour":{"used_percentage":5}}}"#)?.rateLimits
                == .init(fiveHour: .init(usedPercentage: 5, resetsAt: nil), sevenDay: nil))
    }

    @Test func windowsPastTheirResetAreLeftOut() {
        let now = Date(timeIntervalSince1970: 1_000)
        let limits = ClaudeLiveStatus.RateLimits(
            fiveHour: .init(usedPercentage: 90, resetsAt: Date(timeIntervalSince1970: 900)),
            sevenDay: .init(usedPercentage: 44, resetsAt: Date(timeIntervalSince1970: 2_000)))
        #expect(ClaudeTabStateTracker.current(limits, now: now)
                == .init(fiveHour: nil, sevenDay: .init(usedPercentage: 44, resetsAt: Date(timeIntervalSince1970: 2_000))))
        let allPast = ClaudeLiveStatus.RateLimits(fiveHour: .init(usedPercentage: 90, resetsAt: Date(timeIntervalSince1970: 1_000)),
                                                  sevenDay: nil)
        #expect(ClaudeTabStateTracker.current(allPast, now: now) == nil)
    }
}

struct ContextReadingTests {
    private let reply = Date(timeIntervalSince1970: 1_000)

    private var transcript: StatsSnapshot {
        StatsSnapshot(contextUsed: 800_000, contextLimit: 1_000_000, model: "Opus 5.5", lastAssistantAt: reply)
    }

    private func live(_ percent: Double?, at offset: TimeInterval, tokens: Int? = 250_000) -> ClaudeLiveStatus {
        ClaudeLiveStatus(version: "2.1.329", context: .init(usedPercentage: percent, usedTokens: tokens, size: 1_000_000),
                         at: reply.addingTimeInterval(offset))
    }

    @Test func claudeCodesCountWins() {
        let reading = ContextReading.make(stats: transcript, live: live(25, at: 1))
        #expect(reading == ContextReading(usedTokens: 250_000, limit: 1_000_000, percent: 25))
        #expect(reading.display == "25%")
        #expect(reading.fraction == 0.25)
    }

    /// After /compact: the transcript still ends with the big reply, the
    /// input (newer) has no count yet.
    @Test func newerInputWithoutCountIsNotKnownYet() {
        let reading = ContextReading.make(stats: transcript, live: live(nil, at: 20, tokens: 0))
        #expect(reading.percent == nil)
        #expect(reading.display == "-")
        #expect(reading.fraction == 0)
    }

    @Test func olderInputWithoutCountFallsBackToTheTranscript() {
        let reading = ContextReading.make(stats: transcript, live: live(nil, at: -5, tokens: 0))
        #expect(reading == ContextReading(usedTokens: 800_000, limit: 1_000_000, percent: 80))
    }

    @Test func noInputUsesTheTranscript() {
        #expect(ContextReading.make(stats: transcript, live: nil).display == "80%")
        #expect(ContextReading.make(stats: nil, live: nil).display == "-")
        // An input without a context block (older Claude Code).
        let bare = ClaudeLiveStatus(version: "2.1.100", at: reply.addingTimeInterval(9))
        #expect(ContextReading.make(stats: transcript, live: bare).display == "80%")
    }

    @Test func ringTooltipSaysWhatIsLeft() {
        #expect(ContextRingItem.help(ContextReading(usedTokens: 86_000, limit: 200_000, percent: 43))
                == "Context: 43% used, 57% left (86K of 200K tokens)")
        #expect(ContextRingItem.help(ContextReading(usedTokens: 0, limit: 0, percent: 99.6)) == "Context: 99% used, 1% left")
        #expect(ContextRingItem.help(ContextReading(limit: 1_000_000)) == "Context: not known until the next reply")
    }

    @Test func tokensFromThePercentageWhenMissing() {
        let reading = ContextReading.make(stats: nil, live: live(10, at: 1, tokens: nil))
        #expect(reading.usedTokens == 100_000)
        #expect(ContextReading(percent: 140).display == "100%")
    }
}

struct StopFailureStateTests {
    private func event(_ json: String, at time: TimeInterval = 100) -> ClaudeTabEvent? {
        ClaudeTabEvent.parse(Data(json.utf8), at: Date(timeIntervalSince1970: time))
    }

    @Test func parsesTheErrorKindAndText() {
        let e = event(#"{"hook_event_name":"StopFailure","session_id":"s","error":"rate_limit","last_assistant_message":"API Error: Request rejected (429)"}"#)
        #expect(e?.kind == .stopFailure(error: "rate_limit", message: "API Error: Request rejected (429)"))
        #expect(e?.carriesState == true)
        #expect(e?.startsWork == false)
        let long = String(repeating: "x", count: 1_000)
        let capped = event(#"{"hook_event_name":"StopFailure","error":"","last_assistant_message":"\#(long)"}"#)
        #expect(capped?.kind == .stopFailure(error: nil, message: String(repeating: "x", count: ClaudeTabState.failureMessageLimit)))
    }

    @Test func failedUnlessTheSpinnerComesBack() throws {
        let e = try #require(event(#"{"hook_event_name":"StopFailure","error":"server_error"}"#))
        let quiet = TerminalActivitySnapshot()
        #expect(ClaudeTabState.resolve(event: e, activity: quiet, now: e.time.addingTimeInterval(5))
                == .failed(error: "server_error", message: nil))
        // A turn that goes on after the event (spinner after the margin).
        let spinning = TerminalActivitySnapshot(outputTimes: (0..<10).map { e.time.addingTimeInterval(4 + Double($0) * 0.1) })
        #expect(ClaudeTabState.resolve(event: e, activity: spinning, now: e.time.addingTimeInterval(5)) == .working)
        #expect(ClaudeTabState.failed(error: nil, message: nil).wantsAttention)
    }

    @Test func labelsAndBanner() {
        #expect(ClaudeTabState.failureLabel("rate_limit") == "Rate limit reached")
        #expect(ClaudeTabState.failureLabel("authentication_failed") == "Authentication failed")
        #expect(ClaudeTabState.failureLabel("something_new") == "API error")
        #expect(ClaudeTabState.failureLabel(nil) == "API error")
        #expect(AttentionNotifier.body(for: .failed(error: "server_error", message: "API Error: 500"), lastPrompt: "p")
                == "Stopped: API server error\nAPI Error: 500")
        #expect(AttentionNotifier.body(for: .failed(error: "rate_limit", message: nil), lastPrompt: nil)
                == "Stopped: Rate limit reached")
    }

    @Test func announcedOncePerEvent() throws {
        let e = try #require(event(#"{"hook_event_name":"StopFailure","error":"rate_limit"}"#))
        var memory = AttentionAnnouncements()
        let state = ClaudeTabState.failed(error: "rate_limit", message: nil)
        #expect(memory.allows(state, event: e, lastPromptAt: nil))
        memory.record(e)
        #expect(!memory.allows(state, event: e, lastPromptAt: nil))
        let next = try #require(event(#"{"hook_event_name":"StopFailure","error":"rate_limit"}"#, at: 200))
        #expect(memory.allows(state, event: next, lastPromptAt: nil))
    }
}

@MainActor
struct StopFailureTrackerTests {
    @Test func markedBadgedAnnouncedAndPlanLimitsKept() async throws {
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
        func write(_ json: String, to url: URL, at offset: TimeInterval) throws {
            try Data(json.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(offset)], ofItemAtPath: url.path)
        }
        let reset = Int(start.addingTimeInterval(3_600).timeIntervalSince1970)
        // The input of another session (a teammate) still tells the plan's limits.
        try write(#"{"version":"2.1.329","session_id":"B","rate_limits":{"seven_day":{"used_percentage":44,"resets_at":\#(reset)}}}"#,
                  to: ClaudeHookBridge.statusFile(forTab: tabID, in: dir), at: 1)
        try write(#"{"hook_event_name":"StopFailure","session_id":"A","error":"rate_limit"}"#,
                  to: ClaudeHookBridge.eventFile(forTab: tabID, in: dir), at: 2)
        for offset in [5.0, 8, 9] {
            await tracker.refresh(tabs: [tab], activeTabID: nil, appIsActive: false, now: start.addingTimeInterval(offset))
        }
        #expect(tab.claudeState == .failed(error: "rate_limit", message: nil))
        #expect(tab.needsAttention)
        #expect(notifier.badge == 1)
        #expect(notifier.announced.count == 1)
        #expect(tracker.planLimits?.sevenDay?.usedPercentage == 44)
        let reported = start.addingTimeInterval(1).timeIntervalSince1970
        #expect(tracker.planLimitsReportedAt == Date(timeIntervalSince1970: (reported / 60).rounded(.down) * 60))
        #expect(tab.liveStatus == nil)   // not the tab's own session
        // Past the reset: the old percentage goes.
        await tracker.refresh(tabs: [tab], activeTabID: nil, appIsActive: false, now: start.addingTimeInterval(3_700))
        #expect(tracker.planLimits == nil)
        #expect(tracker.planLimitsReportedAt == nil)
    }
}

/// Behind a Claude gateway: `rate_limits.spend_limit` (Claude Code 2.1.330's
/// documented shape: percent, reset, optional dollars and period).
@MainActor
struct GatewaySpendLimitTests {
    private func parse(_ json: String) -> ClaudeLiveStatus.RateLimits? {
        ClaudeLiveStatus.parse(Data(json.utf8), at: Date(timeIntervalSince1970: 100))?.rateLimits
    }

    @Test func readsTheSpendLimit() throws {
        let full = try #require(parse(#"""
            {"version":"2.1.330","rate_limits":{"spend_limit":{"used_percentage":12.4,"resets_at":1800000000,
             "used_usd":12.4,"limit_usd":100,"period":"monthly"}}}
            """#))
        #expect(full.spend == .init(usedPercentage: 12.4, resetsAt: Date(timeIntervalSince1970: 1_800_000_000),
                                    usedUSD: 12.4, limitUSD: 100, period: "monthly"))
        #expect(full.fiveHour == nil && full.sevenDay == nil && !full.isEmpty)
        // An older gateway: the percent only.
        let bare = try #require(parse(#"{"version":"2.1.330","rate_limits":{"spend_limit":{"used_percentage":130,"resets_at":1800000000}}}"#))
        #expect(bare.spend == .init(usedPercentage: 130, resetsAt: Date(timeIntervalSince1970: 1_800_000_000)))
        // No percent: nothing to show.
        #expect(parse(#"{"version":"2.1.330","rate_limits":{"spend_limit":{"used_usd":3}}}"#) == nil)
        // Windows of a plan alongside are kept.
        let both = try #require(parse(#"{"version":"2.1.330","rate_limits":{"seven_day":{"used_percentage":40,"resets_at":1800000000},"spend_limit":{"used_percentage":5,"resets_at":1800000000}}}"#))
        #expect(both.sevenDay?.usedPercentage == 40 && both.spend?.usedPercentage == 5)
    }

    @Test func spendPastItsResetIsLeftOut() {
        let now = Date(timeIntervalSince1970: 1_000)
        let passed = ClaudeLiveStatus.RateLimits(spend: .init(usedPercentage: 50, resetsAt: Date(timeIntervalSince1970: 999)))
        #expect(ClaudeTabStateTracker.current(passed, now: now) == nil)
        let ahead = ClaudeLiveStatus.RateLimits(spend: .init(usedPercentage: 50, resetsAt: Date(timeIntervalSince1970: 2_000)))
        #expect(ClaudeTabStateTracker.current(ahead, now: now) == ahead)
    }

    @Test func toolbarAndTooltipText() {
        let spend = ClaudeLiveStatus.RateLimits.Spend(usedPercentage: 12.4, resetsAt: nil, usedUSD: 12.4, limitUSD: 100, period: "monthly")
        #expect(PlanLimitsToolbarItem.spendText(spend) == "$12.40/$100")
        #expect(PlanLimitsToolbarItem.spendText(.init(usedPercentage: 130, resetsAt: nil)) == "$ 130%")
        #expect(PlanLimitsToolbarItem.spendText(.init(usedPercentage: 24, resetsAt: nil, usedUSD: 12, limitUSD: 50)) == "$12/$50")
        #expect(PlanLimitsToolbarItem.dollars(1234.5) == "$1235")
        #expect(PlanLimitsToolbarItem.dollars(0.5) == "$0.50")
        let help = PlanLimitsToolbarItem.help(.init(spend: spend), reportedAt: nil)
        #expect(help == "Spend limit (from Claude Code)\nSpend: $12.40 of $100 this month (12%)")
        let over = PlanLimitsToolbarItem.help(.init(spend: .init(usedPercentage: 130, resetsAt: nil, period: "weekly")), reportedAt: nil)
        #expect(over == "Spend limit (from Claude Code)\nSpend: 130% used this week")
        // A plan's windows keep their text; the spend is one more line.
        let plan = ClaudeLiveStatus.RateLimits(sevenDay: .init(usedPercentage: 44, resetsAt: nil))
        #expect(PlanLimitsToolbarItem.help(plan, reportedAt: nil) == "Plan usage limits (from Claude Code)\nWeekly: 44% used")
        #expect(PlanLimitsToolbarItem.accessibilityText(.init(sevenDay: .init(usedPercentage: 44, resetsAt: nil), spend: spend))
                == "Plan usage: weekly 44%, spend limit 12%")
    }
}

/// The models the account's plan includes, as Claude Code keeps them in
/// `modelAccessCache` (`apiName` + `entitled`).
@MainActor
struct PlanModelAccessTests {
    @Test func familiesWithNoEntitledModelAreUnavailable() {
        #expect(ClaudeAccountPlan.unavailableFamilies(nil) == [])
        #expect(ClaudeAccountPlan.unavailableFamilies([[String: Any]]()) == [])
        let pro: [[String: Any]] = [["apiName": "claude-opus-5-5", "entitled": false],
                                    ["apiName": "claude-opus-5-1", "entitled": false],
                                    ["apiName": "claude-sonnet-5-5", "entitled": true],
                                    ["apiName": "claude-fable-5-2", "entitled": false],
                                    ["apiName": "claude-fable-5-1", "entitled": true],
                                    ["apiName": "some-other-model", "entitled": false],
                                    ["entitled": false]]
        // Fable still has an entitled model: Claude Code steps a refused alias
        // down to the newest model it may use, so the pick isn't blocked here.
        #expect(ClaudeAccountPlan.unavailableFamilies(pro) == ["opus"])
    }

    @Test func menuPaletteAndSwitchSplitByPlan() {
        let none = ClaudeModelChoice.byPlan(unavailableFamilies: [])
        #expect(none.included == ClaudeModelChoice.all && none.excluded.isEmpty)
        let pro = ClaudeModelChoice.byPlan(unavailableFamilies: ["opus"])
        #expect(pro.included.map(\.alias) == ["fable", "sonnet", "haiku"])
        #expect(pro.excluded.map(\.alias) == ["opus"])
        // A family name no choice has changes nothing.
        #expect(ClaudeModelChoice.byPlan(unavailableFamilies: ["mythos"]).included == ClaudeModelChoice.all)
    }

    @Test func trackerPublishesThemFromTheConfig() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "xylem-access-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appending(path: "claude.json")
        try JSONSerialization.data(withJSONObject: [
            "oauthAccount": ["accountUuid": "a1"],
            "modelAccessCache": [["apiName": "claude-opus-5-5", "entitled": false]]
        ]).write(to: configURL)
        let tracker = ClaudeTabStateTracker(eventsDirectory: dir, notifier: FakeNotifier(), hooksInstalled: true,
                                            rememberVersion: { _ in }, accountConfigFile: { configURL })
        await tracker.refresh(tabs: [], activeTabID: nil, appIsActive: true)
        #expect(tracker.unavailableModelFamilies == ["opus"])
        #expect(ClaudeAccountPlan.read(configURL) == .init(accountID: "a1", unavailableFamilies: ["opus"]))
    }
}

/// A `/login` to another account drops the limits the old one reported.
@MainActor
struct AccountSwitchLimitsTests {
    @Test func anotherAccountForgetsTheOldLimits() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "xylem-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let configURL = dir.appending(path: "claude.json")
        func account(_ id: String, at time: Date) throws {
            try JSONSerialization.data(withJSONObject: ["oauthAccount": ["accountUuid": id, "organizationType": "claude_max"]])
                .write(to: configURL)
            try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: configURL.path)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let tabID = UUID()
        let session = TerminalSessionFactory(autoStartClaude: { false }).makeSession(tabID: tabID, title: "t", directory: "/tmp")
        defer { session.close() }
        let tab = TerminalTab(id: tabID, title: "t", state: .session(session))
        tab.claudeSessionID = "A"
        let tracker = ClaudeTabStateTracker(eventsDirectory: dir, notifier: FakeNotifier(), hooksInstalled: true,
                                            rememberVersion: { _ in }, accountConfigFile: { configURL })
        let start = Date().addingTimeInterval(1)
        try account("one", at: start)
        #expect(ClaudeAccountPlan.read(configURL)?.accountID == "one")
        #expect(ClaudeAccountPlan.read(dir.appending(path: "missing.json")) == nil)
        let reset = Int(start.addingTimeInterval(3_600).timeIntervalSince1970)
        let status = ClaudeHookBridge.statusFile(forTab: tabID, in: dir)
        try Data(#"{"version":"2.1.330","session_id":"A","rate_limits":{"seven_day":{"used_percentage":44,"resets_at":\#(reset)}}}"#.utf8).write(to: status)
        try FileManager.default.setAttributes([.modificationDate: start], ofItemAtPath: status.path)
        await tracker.refresh(tabs: [tab], activeTabID: tabID, appIsActive: true, now: start.addingTimeInterval(1))
        #expect(tracker.planLimits?.sevenDay?.usedPercentage == 44)
        // The config caught mid-write (not JSON) is read again later, not taken for another account.
        try Data("{\"oauthAcc".utf8).write(to: configURL)
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(3)], ofItemAtPath: configURL.path)
        for offset in 2...(ClaudeTabStateTracker.accountCheckInterval + 2) {
            await tracker.refresh(tabs: [tab], activeTabID: tabID, appIsActive: true, now: start.addingTimeInterval(Double(offset)))
        }
        #expect(tracker.planLimits?.sevenDay?.usedPercentage == 44)
        // Signed in as another account; its first input has no limits yet.
        try account("two", at: start.addingTimeInterval(5))
        for offset in 2...(ClaudeTabStateTracker.accountCheckInterval + 2) {
            await tracker.refresh(tabs: [tab], activeTabID: tabID, appIsActive: true, now: start.addingTimeInterval(Double(offset)))
        }
        #expect(tracker.planLimits == nil)
    }

    /// An input that is read again every tick (older than its tab's claude,
    /// or a teammate's) doesn't bring the old account's limits back; the
    /// new account's input from after the switch shows.
    @Test func oldInputsStayOutAfterTheSwitch() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "xylem-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appending(path: "claude.json")
        func account(_ id: String, at time: Date) throws {
            try JSONSerialization.data(withJSONObject: ["oauthAccount": ["accountUuid": id]]).write(to: configURL)
            try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: configURL.path)
        }
        func status(_ tab: UUID, session: String, percent: Int, at time: Date) throws {
            let url = ClaudeHookBridge.statusFile(forTab: tab, in: dir)
            let reset = Int(time.addingTimeInterval(86_400).timeIntervalSince1970)
            try Data(#"{"version":"2.1.330","session_id":"\#(session)","rate_limits":{"seven_day":{"used_percentage":\#(percent),"resets_at":\#(reset)}}}"#.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: url.path)
        }
        let tabID = UUID()
        let session = TerminalSessionFactory(autoStartClaude: { false }).makeSession(tabID: tabID, title: "t", directory: "/tmp")
        defer { session.close() }
        let tab = TerminalTab(id: tabID, title: "t", state: .session(session))
        tab.claudeSessionID = "A"
        let tracker = ClaudeTabStateTracker(eventsDirectory: dir, notifier: FakeNotifier(), hooksInstalled: true,
                                            rememberVersion: { _ in }, accountConfigFile: { configURL })
        let start = Date().addingTimeInterval(1)
        try account("one", at: start)
        // A teammate's input under the same tab id: never marked read, read every tick.
        try status(tabID, session: "teammate", percent: 44, at: start)
        func ticks(from first: Int, count: Int) async {
            for offset in first..<(first + count) {
                await tracker.refresh(tabs: [tab], activeTabID: tabID, appIsActive: true, now: start.addingTimeInterval(Double(offset)))
            }
        }
        await ticks(from: 1, count: 1)
        #expect(tracker.planLimits?.sevenDay?.usedPercentage == 44)
        try account("two", at: start.addingTimeInterval(5))
        await ticks(from: 2, count: ClaudeTabStateTracker.accountCheckInterval + 2)
        #expect(tracker.planLimits == nil)
        // The new account's first input.
        try status(tabID, session: "teammate", percent: 3, at: start.addingTimeInterval(40))
        await ticks(from: 41, count: 1)
        #expect(tracker.planLimits?.sevenDay?.usedPercentage == 3)
    }
}

@MainActor
struct HookSettingsVersionTests {
    @Test func stopFailureOnlyFrom2_1_78() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "xylem-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = try #require(ClaudeHookBridge.install(root: root, userSettings: NoClaudeSettings()))
        func events(_ path: String) throws -> Set<String> {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any]
            return Set((object?["hooks"] as? [String: Any])?.keys.map { $0 } ?? [])
        }
        let legacy = try #require(ClaudeHookBridge.settingsPath(installed: installed, claudeVersion: "2.1.77"))
        #expect(legacy.hasSuffix("/hooks/settings-legacy.json"))
        #expect(try events(installed).contains("StopFailure"))
        #expect(try events(legacy) == Set(ClaudeHookBridge.events).subtracting(["StopFailure"]))
        #expect(ClaudeHookBridge.settingsPath(installed: installed, claudeVersion: "2.1.78") == installed)
        #expect(ClaudeHookBridge.settingsPath(installed: installed, claudeVersion: "2.1.329") == installed)
        #expect(ClaudeHookBridge.settingsPath(installed: installed, claudeVersion: nil) == legacy)
        #expect(ClaudeHookBridge.settingsPath(installed: nil, claudeVersion: "2.1.329") == nil)
        // Both files carry the status line.
        let legacyObject = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: legacy))) as? [String: Any]
        #expect(legacyObject?["statusLine"] != nil)
        // ps lines of either file are Xylem's own.
        let own = "12 claude --resume s1 --settings /Users/x/.xylem/hooks/settings-legacy.json\n"
        #expect(!OpenSessionDetector.mentions(sessionID: "s1", in: own, ignoringLinesContaining: ClaudeHookBridge.settingsFileMarker))
    }

    /// An npm install is `#!/usr/bin/env node`: the version is read with the
    /// PATH given, not the app's own (which has no node).
    @Test func versionOfAScriptThatNeedsItsInterpreterOnPath() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "xylem-version-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let interpreter = dir.appending(path: "xylemfakenode")
        try "#!/bin/sh\necho '2.1.80 (Claude Code)'\n".write(to: interpreter, atomically: true, encoding: .utf8)
        let claude = dir.appending(path: "claude")
        try "#!/usr/bin/env xylemfakenode\n".write(to: claude, atomically: true, encoding: .utf8)
        for file in [interpreter, claude] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        #expect(ClaudeCLIVersion.read(executable: claude.path, searchPath: [dir.path]) == "2.1.80")
        #expect(ClaudeCLIVersion.read(executable: claude.path, searchPath: []) == nil)
    }

    /// A failed read keeps what is known; a new answer replaces it.
    @Test func failedReadKeepsTheKnownVersion() {
        let suite = "xylem-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("2.1.329", forKey: ClaudeCLIVersion.defaultsKey)
        ClaudeCLIVersion.remember(nil, in: defaults)
        #expect(ClaudeCLIVersion.known(in: defaults) == "2.1.329")
        ClaudeCLIVersion.remember("2.1.330", in: defaults)
        #expect(ClaudeCLIVersion.known(in: defaults) == "2.1.330")
        #expect(ClaudeCLIVersion.isVersion("2.1.78", atLeast: "2.1.78"))
        #expect(!ClaudeCLIVersion.isVersion("2.1.77", atLeast: "2.1.78"))
        #expect(ClaudeCLIVersion.isVersion("2.1.329", atLeast: "2.1.78"))
    }

    /// A restored tab picks its hook settings when it starts, not at restore.
    @Test func restoredLaunchTakesTheSettingsChosenAtStart() {
        let legacy = "/Users/x/.xylem/hooks/settings-legacy.json"
        let full = "/Users/x/.xylem/hooks/settings.json"
        let command = ["claude", "--resume", "s1", "--settings", legacy]
        #expect(TerminalSessionFactory.replacingHookSettings(in: command, with: full)
                == ["claude", "--resume", "s1", "--settings", full])
        #expect(TerminalSessionFactory.replacingHookSettings(in: command, with: legacy) == nil)
        // Someone else's settings file, or none: left alone.
        #expect(TerminalSessionFactory.replacingHookSettings(in: ["claude", "--settings", "/p/my.json"], with: full) == nil)
        #expect(TerminalSessionFactory.replacingHookSettings(in: ["claude", "--settings"], with: full) == nil)
        #expect(TerminalSessionFactory.replacingHookSettings(in: ["claude"], with: full) == nil)
    }

    @Test func versionFromTheBinary() {
        #expect(ClaudeCLIVersion.parse("2.1.329 (Claude Code)\n") == "2.1.329")
        #expect(ClaudeCLIVersion.parse("  2.0.50 (Claude Code)") == "2.0.50")
        #expect(ClaudeCLIVersion.parse("claude 2.1.3") == nil)
        #expect(ClaudeCLIVersion.parse("") == nil)
        #expect(ClaudeCLIVersion.parse("2.1 (Claude Code)") == nil)
    }
}

@MainActor
struct NextWaitingTabTests {
    private func tabs(_ count: Int) -> [TerminalTab] { (0..<count).map { TerminalTab(title: "t\($0)") } }

    @Test func cyclesAfterTheActiveTab() {
        let list = tabs(5)
        list[1].needsAttention = true
        list[3].claudeState = .needsInput(message: nil)   // seen, still unanswered
        #expect(TabsViewModel.nextWaitingTab(in: list, after: list[2].id) == list[3].id)
        #expect(TabsViewModel.nextWaitingTab(in: list, after: list[3].id) == list[1].id)   // wraps
        #expect(TabsViewModel.nextWaitingTab(in: list, after: nil) == list[1].id)
    }

    @Test func neverTheActiveTabAndNilWhenNoneWait() {
        let list = tabs(3)
        list[1].needsAttention = true
        #expect(TabsViewModel.nextWaitingTab(in: list, after: list[1].id) == nil)
        list[1].needsAttention = false
        list[0].claudeState = .finished   // seen: not waiting any more
        list[2].claudeState = .failed(error: "rate_limit", message: nil)
        #expect(TabsViewModel.nextWaitingTab(in: list, after: list[1].id) == nil)
        #expect(TabsViewModel.nextWaitingTab(in: [], after: nil) == nil)
    }
}
