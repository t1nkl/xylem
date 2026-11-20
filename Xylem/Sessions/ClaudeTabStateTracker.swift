//
//  ClaudeTabStateTracker.swift
//  Xylem
//
//  Keeps every tab's Claude state current from its hook events
//  (ClaudeHookBridge) and its pty output (TerminalActivityMonitor):
//  `claudeState`, `isBusy`, the "waiting for you" mark and the session
//  binding (`/clear` and `/resume` move a tab to another session id).
//
//  Only events of the tab's own session count. Anything else that runs
//  under the tab's `XYLEM_TAB_ID` with our hooks (a teammate process an
//  agent team spawns, say) must not move the tab or drive its state; the
//  binding moves only on SessionStart with source clear/resume (verified:
//  `/resume <id>` sends SessionEnd(resume) + SessionStart(resume) with the
//  new id), or when the tab has no binding yet.
//
//  Driven by its own 1 s loop in AppModel that does NOT pause while the
//  window is hidden - Claude finishing in the background is exactly when
//  the Dock badge and the notification matter. A tick costs one `stat` per
//  tab; an event file is read only when its mtime changed, off main (a
//  UserPromptSubmit event carries the whole prompt).
//
//  The same tick also tells whether the hooks report at all
//  (`hookHealth`, shown by Doctor): the only observed property, so the
//  per-tab bookkeeping below never re-renders anything.
//

import Foundation
import Observation

@MainActor
@Observable
final class ClaudeTabStateTracker {
    private nonisolated struct Query: Sendable {
        let id: UUID
        let previousMtime: Date?
        let previousStatusMtime: Date?
    }

    private nonisolated struct Read: Sendable {
        let id: UUID
        /// The event file changed (nil: only the status line input did).
        let events: EventRead?
        /// The status line input changed.
        let status: (mtime: Date, live: ClaudeLiveStatus?)?
    }

    private nonisolated struct EventRead: Sendable {
        let mtime: Date
        let event: ClaudeTabEvent?
        /// The tab's prompt marker (ClaudeHookBridge): when, which session.
        let prompt: (time: Date, sessionID: String?)?
    }

    /// Whether the tab-event hooks report (Doctor). Equality-guarded.
    private(set) var hookHealth: HookBridgeHealth = .unknown
    /// Newest event of any tab's current claude, for Doctor's "last event".
    /// Read only by the Doctor popover while it is open.
    private(set) var lastHookEventAt: Date?
    /// The plan's usage limits from the newest status line input of any tab
    /// that had them, windows whose reset has passed left out (their
    /// percentage is old). nil without any (API keys, no request yet).
    /// Account-wide, so not tied to a tab's session. Equality-guarded.
    private(set) var planLimits: ClaudeLiveStatus.RateLimits?
    /// When Claude Code passed `planLimits` (it may be from before this
    /// launch: the numbers are as of then).
    private(set) var planLimitsReportedAt: Date?
    /// The input `planLimits` comes from.
    @ObservationIgnored private var newestLimits: (limits: ClaudeLiveStatus.RateLimits, at: Date)?

    /// Latest event that carries state, per tab (an `.other` event such as
    /// an auth notice doesn't replace it).
    @ObservationIgnored private var events: [UUID: ClaudeTabEvent] = [:]
    @ObservationIgnored private var eventMtimes: [UUID: Date] = [:]
    @ObservationIgnored private var statusMtimes: [UUID: Date] = [:]
    /// Time of the newest event of each tab's CURRENT claude (any session,
    /// any kind): proof the hooks fire for it.
    @ObservationIgnored private var lastEventAt: [UUID: Date] = [:]
    /// When each tab's current attention episode started.
    @ObservationIgnored private var attentionSince: [UUID: Date] = [:]
    /// Which hook events already produced a banner, per tab. Survives the
    /// mark being seen and the state flipping on output alone.
    @ObservationIgnored private var announcements: [UUID: AttentionAnnouncements] = [:]
    /// Tabs whose banner is still delivered (withdrawn when the mark goes).
    @ObservationIgnored private var bannerShown: Set<UUID> = []
    /// Newest human prompt of each tab's current claude.
    @ObservationIgnored private var lastPromptAt: [UUID: Date] = [:]
    /// Tabs whose claude leaves prompt markers. One started before this
    /// version (older hook settings) doesn't, and a prompt replaced in the
    /// event file within a second goes unseen: for it every Stop announces
    /// once rather than a real turn going silent.
    @ObservationIgnored private var leavesPromptMarkers: Set<UUID> = []
    /// Per tab: the time of the turn event already seen interrupted (Esc).
    @ObservationIgnored private var interruptedTurn: [UUID: Date] = [:]
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var ticksSincePrune = 0

    /// A state must hold this long before it is announced: a `/goal` turn
    /// that continues after its Stop should not ping.
    static let announceDelay: TimeInterval = 2

    @ObservationIgnored private let eventsDirectory: URL
    @ObservationIgnored private let notifier: AttentionNotifying
    @ObservationIgnored private let hooksInstalled: Bool
    /// Keeps the version a tab's claude reports (ClaudeCLIVersion); tests
    /// pass their own so they never write the app's preferences.
    @ObservationIgnored private let rememberVersion: (String?) -> Void
    /// Called when a tab moved to another Claude session (to persist it).
    @ObservationIgnored var onBindingChange: () -> Void = {}

    init(eventsDirectory: URL = ClaudeHookBridge.eventsDirectory, notifier: AttentionNotifying,
         hooksInstalled: Bool = ClaudeHookBridge.installedSettingsPath != nil,
         rememberVersion: @escaping (String?) -> Void = ClaudeCLIVersion.remember) {
        self.eventsDirectory = eventsDirectory
        self.notifier = notifier
        self.hooksInstalled = hooksInstalled
        self.rememberVersion = rememberVersion
    }

    func refresh(tabs: [TerminalTab], activeTabID: UUID?, appIsActive: Bool, now: Date = Date()) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // A restored tab not opened yet has no claude and no events.
        let queries = tabs.filter { $0.session?.isStarted == true }
            .map { Query(id: $0.id, previousMtime: eventMtimes[$0.id], previousStatusMtime: statusMtimes[$0.id]) }
        ticksSincePrune += 1
        let prune = ticksSincePrune >= 60
        if prune { ticksSincePrune = 0 }
        let reads = await Self.read(queries, in: eventsDirectory, pruneKeeping: prune ? Set(tabs.map(\.id)) : nil)
        apply(reads: reads, tabs: tabs, activeTabID: activeTabID, appIsActive: appIsActive, now: now)
    }

    /// The tab is on screen now: drop its mark right away instead of on
    /// the next tick.
    func markSeen(_ tab: TerminalTab) {
        if tab.needsAttention { tab.needsAttention = false }
        attentionSince[tab.id] = nil
        // AppModel withdraws the banner; which event it was for is kept, so
        // the same event never announces again.
        bannerShown.remove(tab.id)
    }

    private func apply(reads: [Read], tabs: [TerminalTab], activeTabID: UUID?, appIsActive: Bool, now: Date) {
        let byID = Dictionary(reads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var bindingChanged = false

        for tab in tabs {
            guard let session = tab.session, let startedAt = session.startedAt else {
                reset(tab)
                continue
            }
            if let read = byID[tab.id]?.events {
                eventMtimes[tab.id] = read.mtime
                // Events from before this shell started belong to an
                // earlier claude (e.g. before a relaunch).
                if let event = read.event, event.time >= startedAt.addingTimeInterval(-1) {
                    lastEventAt[tab.id] = event.time
                }
                if let event = read.event, event.time >= startedAt.addingTimeInterval(-1),
                   let id = event.sessionID {
                    if id != tab.claudeSessionID, event.switchesSession || tab.claudeSessionID == nil {
                        tab.claudeSessionID = id
                        tab.transcriptPath = nil
                        if tab.liveStatus != nil { tab.liveStatus = nil }
                        bindingChanged = true
                    }
                    if id == tab.claudeSessionID {
                        if event.carriesState { events[tab.id] = event }
                        if event.kind == .promptSubmitted { notePrompt(event.time, tab: tab.id) }
                        if let path = event.transcriptPath, tab.transcriptPath != path {
                            tab.transcriptPath = path
                        }
                    }
                }
                // After the binding moved (`/clear`), so its prompt counts.
                if let prompt = read.prompt, prompt.time >= startedAt.addingTimeInterval(-1) {
                    leavesPromptMarkers.insert(tab.id)
                    // A teammate's prompt (same tab id, its own session) isn't the user's.
                    if prompt.sessionID == nil || prompt.sessionID == tab.claudeSessionID {
                        notePrompt(prompt.time, tab: tab.id)
                    }
                }
            }

            // After the binding moved (`/clear`): a new session's input that
            // came in the same tick counts. One from another session (a
            // teammate runs under the tab id too) or an earlier claude is
            // read again on the next tick instead of being skipped for good.
            if let status = byID[tab.id]?.status {
                // Account-wide: any input counts, also one from before this
                // launch or from a teammate's session.
                if let live = status.live, let limits = live.rateLimits,
                   live.at >= (newestLimits?.at ?? .distantPast) {
                    newestLimits = (limits, live.at)
                }
                if let live = status.live, live.at >= startedAt.addingTimeInterval(-1),
                   live.sessionID == nil || live.sessionID == tab.claudeSessionID {
                    statusMtimes[tab.id] = status.mtime
                    if tab.liveStatus != live { tab.liveStatus = live }
                    // The claude this tab really runs: the next tabs' hook settings follow it.
                    rememberVersion(live.version)
                } else if status.live == nil {
                    statusMtimes[tab.id] = status.mtime
                }
            }

            let old = tab.claudeState
            var state: ClaudeTabState?
            if let event = events[tab.id] {
                let resolved = ClaudeTabState.resolve(
                    event: event,
                    activity: session.activity.snapshot(),
                    now: now,
                    interrupted: interruptedTurn[tab.id] == event.time
                )
                // A turn seen to stop without a hook stays stopped.
                if event.startsWork, resolved == .idle { interruptedTurn[tab.id] = event.time }
                state = resolved
            }
            if old != state { tab.claudeState = state }
            // Claude has exited: no level to show until the next one reports.
            if state == .notRunning, tab.liveStatus != nil { tab.liveStatus = nil }
            // Not running: claude exited, the busy flag goes back to the
            // transcript-mtime fallback (claude may be restarted by hand).
            if let state, state != .notRunning {
                let busy = state == .working
                if tab.isBusy != busy { tab.isBusy = busy }
            }

            let seen = appIsActive && tab.id == activeTabID
            let attention = state.map {
                ClaudeTabState.attention(previous: tab.needsAttention, from: old, to: $0, isSeen: seen)
            } ?? false
            if tab.needsAttention != attention { tab.needsAttention = attention }
            announceIfNeeded(tab, state: state, event: events[tab.id], attention: attention, seen: seen, now: now)
        }

        let live = Set(tabs.map(\.id))
        events = events.filter { live.contains($0.key) }
        eventMtimes = eventMtimes.filter { live.contains($0.key) }
        statusMtimes = statusMtimes.filter { live.contains($0.key) }
        lastEventAt = lastEventAt.filter { live.contains($0.key) }
        attentionSince = attentionSince.filter { live.contains($0.key) }
        interruptedTurn = interruptedTurn.filter { live.contains($0.key) }
        announcements = announcements.filter { live.contains($0.key) }
        bannerShown = bannerShown.filter { live.contains($0) }
        lastPromptAt = lastPromptAt.filter { live.contains($0.key) }
        leavesPromptMarkers = leavesPromptMarkers.filter { live.contains($0) }

        notifier.setBadgeCount(tabs.filter(\.needsAttention).count)
        let limits = newestLimits.flatMap { Self.current($0.limits, now: now) }
        if planLimits != limits { planLimits = limits }
        // To the minute, as the tooltip shows it: inputs arrive every second
        // while a tab streams, and each would re-render the limits.
        let reportedAt = limits == nil ? nil : newestLimits.map {
            Date(timeIntervalSince1970: ($0.at.timeIntervalSince1970 / 60).rounded(.down) * 60)
        }
        if planLimitsReportedAt != reportedAt { planLimitsReportedAt = reportedAt }
        if bindingChanged { onBindingChange() }
        updateHookHealth(tabs: tabs, now: now)
    }

    /// The windows whose reset is still ahead; nil when none is.
    nonisolated static func current(_ limits: ClaudeLiveStatus.RateLimits, now: Date) -> ClaudeLiveStatus.RateLimits? {
        func keep(_ window: ClaudeLiveStatus.RateLimits.Window?) -> ClaudeLiveStatus.RateLimits.Window? {
            guard let window else { return nil }
            if let reset = window.resetsAt, reset <= now { return nil }
            return window
        }
        let result = ClaudeLiveStatus.RateLimits(fiveHour: keep(limits.fiveHour), sevenDay: keep(limits.sevenDay))
        return result.isEmpty ? nil : result
    }

    private func updateHookHealth(tabs: [TerminalTab], now: Date) {
        let probes = tabs.compactMap { tab -> HookBridgeHealth.Probe? in
            guard let session = tab.session, let startedAt = session.startedAt else { return nil }
            var probe = HookBridgeHealth.Probe(
                title: tab.displayTitle,
                launchedWithHooks: session.launchedWithHooks,
                startedAt: startedAt,
                lastEventAt: lastEventAt[tab.id],
                lastInputAt: session.activity.snapshot().lastInput
            )
            // Two syscalls, and only for a tab that would turn Doctor amber.
            if probe.launchedWithHooks, probe.isSilent(now: now), session.shellIsInForeground {
                probe.claudeRunning = false
            }
            return probe
        }
        let health = HookBridgeHealth.evaluate(installed: hooksInstalled, probes: probes, now: now)
        if hookHealth != health { hookHealth = health }
        let newest = lastEventAt.values.max()
        if lastHookEventAt != newest { lastHookEventAt = newest }
    }

    private func notePrompt(_ time: Date, tab id: UUID) {
        if let known = lastPromptAt[id], known >= time { return }
        lastPromptAt[id] = time
    }

    private func announceIfNeeded(_ tab: TerminalTab, state: ClaudeTabState?, event: ClaudeTabEvent?,
                                  attention: Bool, seen: Bool, now: Date) {
        var memory = announcements[tab.id] ?? AttentionAnnouncements()
        // Watched landing: the Stop held (not `/goal` going on) while on screen.
        if seen, state == .finished, let event,
           now.timeIntervalSince(event.time) >= Self.announceDelay + ClaudeTabState.afterEventMargin {
            memory.watched(event)
            announcements[tab.id] = memory
        }
        guard attention, let state, let event else {
            attentionSince[tab.id] = nil
            // Seen, or a new event (Claude is at it again): the banner is
            // old news. Output alone flipping the state isn't: the banner
            // would go and, being for the same event, never come back.
            if seen || !memory.announced(event), bannerShown.remove(tab.id) != nil {
                notifier.withdraw(tabID: tab.id)
            }
            return
        }
        let since = attentionSince[tab.id] ?? now
        attentionSince[tab.id] = since
        guard now.timeIntervalSince(since) >= Self.announceDelay else { return }
        // A resize drops the redraw that would show `/goal` still going on:
        // wait until it can be told apart.
        if tab.session?.activity.snapshot().wasResized(now: now) == true { return }
        let prompts = leavesPromptMarkers.contains(tab.id) ? lastPromptAt[tab.id] : nil
        guard memory.allows(state, event: event, lastPromptAt: prompts) else { return }
        memory.record(event)
        announcements[tab.id] = memory
        bannerShown.insert(tab.id)
        notifier.announce(tabID: tab.id, title: tab.displayTitle, state: state, lastPrompt: tab.lastPrompt)
    }

    private func reset(_ tab: TerminalTab) {
        events[tab.id] = nil
        lastEventAt[tab.id] = nil
        leavesPromptMarkers.remove(tab.id)
        if tab.claudeState != nil { tab.claudeState = nil }
        if tab.needsAttention { tab.needsAttention = false }
        if tab.liveStatus != nil { tab.liveStatus = nil }
    }

    @concurrent nonisolated
    private static func read(_ queries: [Query], in directory: URL, pruneKeeping live: Set<UUID>?) async -> [Read] {
        // About once a minute: files of closed tabs (see pruneEvents).
        if let live { ClaudeHookBridge.pruneEvents(keeping: live, in: directory) }
        return queries.compactMap { query in
            var events: EventRead?
            if let mtime = ClaudeHookBridge.modificationDate(forTab: query.id, in: directory),
               mtime != query.previousMtime {
                // The marker is touched before the event file is written, so
                // it is current whenever the event file changed.
                events = EventRead(mtime: mtime,
                                   event: ClaudeHookBridge.latestEvent(forTab: query.id, in: directory),
                                   prompt: ClaudeHookBridge.lastPrompt(forTab: query.id, in: directory))
            }
            var status: (mtime: Date, live: ClaudeLiveStatus?)?
            if let mtime = ClaudeHookBridge.statusModificationDate(forTab: query.id, in: directory),
               mtime != query.previousStatusMtime {
                status = (mtime, ClaudeHookBridge.latestStatus(forTab: query.id, in: directory))
            }
            guard events != nil || status != nil else { return nil }
            return Read(id: query.id, events: events, status: status)
        }
    }
}
