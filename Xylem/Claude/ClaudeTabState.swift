//
//  ClaudeTabState.swift
//  Xylem
//
//  What the claude in a tab is doing, from two signals:
//
//  · the tab's latest hook event (ClaudeHookBridge) - says when a turn
//    starts, when it stops and when Claude asks for permission;
//  · the pty's own output (TerminalActivityMonitor) - Claude's spinner
//    redraws several times a second for as long as a turn runs (measured:
//    largest gap 0.23 s during a 15 s Bash command; in Xylem ~15 batches
//    per 1.5 s also in a background tab) and the screen is silent at the
//    prompt.
//
//  Hooks alone are not enough: Esc interrupts a turn without any hook, so a tab
//  that goes silent mid-turn is idle (and stays idle for that turn -
//  `interrupted`, also when the user switches tabs right after Esc); and with
//  `/goal` the turn goes on after a Stop event (the goal's own Stop hook
//  evaluates for ~3 s with the spinner on, then Claude continues), so a Stop is
//  "finished" only once the spinner stays quiet. Output alone is not enough
//  either: a permission prompt keeps redrawing (~1.6 batches per second), so
//  "needs input" ends when the user answers in that tab (keyboard input) or the
//  next hook event arrives. A question dialog (AskUserQuestion) arrives as a
//  permission prompt too. A turn an API error ended (StopFailure, sent
//  instead of Stop) is "failed" until the next event.
//
//  Everything here is pure; the view model feeds it times and events.
//

import Foundation

nonisolated struct ClaudeTabEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// `source`: startup, resume (also `/resume`), clear, compact.
        case sessionStart(source: String?)
        /// `reason`: clear and resume hand over to a new session.
        case sessionEnd(reason: String?)
        case promptSubmitted
        case toolActivity
        case stop
        /// An API error ended the turn (sent instead of Stop): `error` is
        /// Claude Code's kind (rate_limit, server_error, …), `message` the
        /// error text it showed.
        case stopFailure(error: String?, message: String?)
        /// Permission prompt or a question to the user.
        case needsInput(message: String?)
        /// Claude has been waiting at the prompt for a while.
        case idlePrompt
        /// Anything else (auth notices, …): carries no state.
        case other
    }

    let kind: Kind
    let sessionID: String?
    let transcriptPath: String?
    let time: Date
    /// `permission_mode` (default, plan, acceptEdits, auto, dontAsk,
    /// bypassPermissions); nil when the event has none.
    var permissionMode: String? = nil
    /// Background tasks still running or about to (`background_tasks`
    /// entries with status running or pending). Of the events Xylem
    /// subscribes to only Stop carries the list (2.1.332): nil on the others.
    var runningBackgroundTasks: Int? = nil

    /// Task statuses that still hold work the session would lose.
    static let liveTaskStatuses: Set<String> = ["running", "pending"]

    static func parse(_ data: Data, at time: Date) -> ClaudeTabEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["hook_event_name"] as? String
        else { return nil }
        let kind: Kind
        switch name {
        case "SessionStart": kind = .sessionStart(source: object["source"] as? String)
        case "SessionEnd": kind = .sessionEnd(reason: object["reason"] as? String)
        case "UserPromptSubmit": kind = .promptSubmitted
        case "PreToolUse", "PostToolUse": kind = .toolActivity
        case "Stop": kind = .stop
        case "StopFailure":
            kind = .stopFailure(error: (object["error"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                message: (object["last_assistant_message"] as? String).flatMap {
                                    $0.isEmpty ? nil : String($0.prefix(ClaudeTabState.failureMessageLimit))
                                })
        case "Notification":
            switch object["notification_type"] as? String {
            case "permission_prompt", "elicitation_dialog":
                kind = .needsInput(message: object["message"] as? String)
            case "idle_prompt":
                kind = .idlePrompt
            default:
                kind = .other
            }
        default: kind = .other
        }
        let sessionID = (object["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let transcript = (object["transcript_path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let tasks = (object["background_tasks"] as? [Any]).map { list in
            list.count(where: { (($0 as? [String: Any])?["status"] as? String).map(liveTaskStatuses.contains) ?? false })
        }
        return ClaudeTabEvent(kind: kind, sessionID: sessionID, transcriptPath: transcript, time: time,
                              permissionMode: (object["permission_mode"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                              runningBackgroundTasks: tasks)
    }

    /// The tab's claude moved to another session (`/clear`, `/resume`).
    var switchesSession: Bool {
        if case .sessionStart(let source) = kind { return source == "clear" || source == "resume" }
        return false
    }

    /// Whether the event replaces the tab's stored event. `idle_prompt`
    /// (~60 s at the prompt after a turn) says nothing new: kept, it would
    /// turn an idle tab (Esc, a denied permission) into "finished" and
    /// announce it again.
    var carriesState: Bool {
        switch kind {
        case .other, .idlePrompt: return false
        default: return true
        }
    }

    /// A turn is running from this event on.
    var startsWork: Bool {
        switch kind {
        case .promptSubmitted, .toolActivity: return true
        default: return false
        }
    }
}

/// Output and input timing of one terminal, as the state rules need it.
nonisolated struct TerminalActivitySnapshot: Equatable, Sendable {
    /// Last bytes the user (or Xylem on their behalf) sent to the shell.
    var lastInput: Date?
    /// Recent output batches that did not follow input (typing echo is
    /// not Claude working), oldest first.
    var outputTimes: [Date] = []
    /// What Claude was last told by focus reporting (true when it never
    /// asked for reports). Recorded so focus reports never count as input.
    var isFocused = true
    var focusChangedAt: Date?
    /// Last terminal size change: its redraw is dropped from `outputTimes`.
    var lastResize: Date?

    /// Input recent enough that output may have been dropped as its echo.
    func isTyping(now: Date) -> Bool {
        guard let input = lastInput else { return false }
        return now.timeIntervalSince(input) < TerminalActivityMonitor.echoWindow + ClaudeTabState.streamWindow
    }

    /// A size change recent enough that its dropped redraw may hide the
    /// spinner: silence then proves nothing, as with typing.
    func wasResized(now: Date) -> Bool {
        guard let resize = lastResize else { return false }
        return now.timeIntervalSince(resize) < TerminalActivityMonitor.resizeWindow + ClaudeTabState.streamWindow
    }

    /// Claude's spinner: steady output, not a one-off redraw.
    func isStreaming(now: Date, after start: Date = .distantPast) -> Bool {
        let from = max(start, now.addingTimeInterval(-ClaudeTabState.streamWindow))
        return outputTimes.filter { $0 > from }.count >= ClaudeTabState.streamMinBatches
    }
}

nonisolated enum ClaudeTabState: Equatable, Sendable {
    /// No claude in the tab (exited, or never started).
    case notRunning
    /// At the prompt, nothing new for the user.
    case idle
    /// A turn is running.
    case working
    /// The turn ended - the user's move.
    case finished
    /// An API error ended the turn (rate limit, authentication, server).
    case failed(error: String?, message: String?)
    /// Claude asks for permission or an answer.
    case needsInput(message: String?)

    /// Output batches needed within `streamWindow` to count as a running
    /// spinner (it gives ~10 per second; a permission prompt ~1.6).
    static let streamMinBatches = 5
    static let streamWindow: TimeInterval = 1.5
    /// A just-submitted prompt counts as working before the spinner starts.
    static let promptGrace: TimeInterval = 4
    /// Output in the first moments after Stop is the final redraw, not a
    /// continued turn.
    static let afterEventMargin: TimeInterval = 1.5
    /// Longest error text kept from a StopFailure event.
    static let failureMessageLimit = 300

    var wantsAttention: Bool {
        switch self {
        case .finished, .needsInput, .failed: return true
        default: return false
        }
    }

    /// Claude Code's error kind in words, for the tab and the banner.
    static func failureLabel(_ error: String?) -> String {
        switch error {
        case "rate_limit": return "Rate limit reached"
        case "overloaded": return "API overloaded"
        case "authentication_failed": return "Authentication failed"
        case "oauth_org_not_allowed": return "Organization not allowed"
        case "account_on_hold": return "Account on hold"
        case "verification_required": return "Verification required"
        case "billing_error": return "Billing problem"
        case "invalid_request": return "Request rejected"
        case "model_not_found": return "Model not found"
        case "server_error": return "API server error"
        case "max_output_tokens": return "Reply hit the output limit"
        case "cloud_credential_error": return "Cloud credentials problem"
        default: return "API error"
        }
    }

    /// `interrupted`: this event's turn was already seen to stop without
    /// a hook (Esc) - it stays idle even after the tab loses focus.
    static func resolve(
        event: ClaudeTabEvent,
        activity: TerminalActivitySnapshot,
        now: Date,
        interrupted: Bool = false
    ) -> ClaudeTabState {
        switch event.kind {
        case .sessionStart:
            return activity.isStreaming(now: now, after: event.time) ? .working : .idle
        case .sessionEnd(let reason):
            return reason == "clear" || reason == "resume" ? .idle : .notRunning
        case .promptSubmitted, .toolActivity:
            if interrupted { return .idle }
            if now.timeIntervalSince(event.time) < promptGrace { return .working }
            // Typing mid-turn: its echo window hides the spinner, so the
            // silence proves nothing (Esc still shows a moment later).
            if activity.isTyping(now: now) || activity.wasResized(now: now) { return .working }
            // Silence mid-turn: interrupted with Esc.
            return activity.isStreaming(now: now) ? .working : .idle
        case .idlePrompt:
            // Never stored (see `carriesState`); on its own it means the
            // prompt is waiting with nothing new.
            return .idle
        case .stop:
            // `/goal` evaluating or continuing: the spinner is on.
            let after = event.time.addingTimeInterval(afterEventMargin)
            return activity.isStreaming(now: now, after: after) ? .working : .finished
        case .stopFailure(let error, let message):
            // Like Stop: a turn that goes on (a retry) shows the spinner.
            let after = event.time.addingTimeInterval(afterEventMargin)
            return activity.isStreaming(now: now, after: after) ? .working : .failed(error: error, message: message)
        case .needsInput(let message):
            if let input = activity.lastInput, input > event.time {
                // Answered in the tab: running again, or denied and idle.
                if activity.isTyping(now: now) { return .working }
                return activity.isStreaming(now: now) ? .working : .idle
            }
            return .needsInput(message: message)
        case .other:
            return .idle
        }
    }

    /// Whether a tab should carry the "waiting for you" mark after a state
    /// change. A tab the user is looking at never gets it; a tab gets it
    /// when it ENTERS finished/needs-input unseen and keeps it until seen
    /// or until Claude works again.
    static func attention(previous: Bool, from old: ClaudeTabState?, to new: ClaudeTabState, isSeen: Bool) -> Bool {
        guard new.wantsAttention, !isSeen else { return false }
        if old != new { return true }
        return previous
    }
}

/// One tab's banner memory: a macOS notification is sent once per hook
/// event, not per entry into an attention state. A tab can leave and
/// re-enter "finished" on output alone (a redraw, `/goal` evaluating) or
/// lose and regain its mark (seen, then left); none of that is a new event.
/// "Claude finished" also needs a human prompt since the last Stop the user
/// already knows about - one that got a banner, or that they watched land:
/// a turn Claude starts on its own after that (a background
/// task reporting back) stays silent, while `/goal`, whose in-between Stops
/// nobody saw settle, still announces its end. A permission question and
/// a turn an API error ended always notify, once per event.
nonisolated struct AttentionAnnouncements: Equatable, Sendable {
    /// Time of the hook event behind the last banner.
    private(set) var lastAnnounced: Date?
    /// The newest Stop that got a banner or was watched.
    private(set) var lastKnownStop: Date?

    /// `lastPromptAt`: the newest human prompt of the tab's claude, nil when
    /// that can't be known (its hooks leave no prompt marker): then every
    /// Stop announces once.
    func allows(_ state: ClaudeTabState, event: ClaudeTabEvent, lastPromptAt: Date?) -> Bool {
        guard event.time != lastAnnounced else { return false }
        switch (state, event.kind) {
        case (.needsInput, .needsInput), (.failed, .stopFailure):
            return true
        case (.finished, .stop):
            guard let lastKnownStop, let lastPromptAt else { return true }
            return lastPromptAt > lastKnownStop
        default:
            return false
        }
    }

    mutating func record(_ event: ClaudeTabEvent) {
        lastAnnounced = event.time
        if case .stop = event.kind { lastKnownStop = event.time }
    }

    /// The user watched this Stop's turn end in the tab.
    mutating func watched(_ event: ClaudeTabEvent) {
        if case .stop = event.kind { lastKnownStop = event.time }
    }

    /// Whether `event` is the one the last banner was for.
    func announced(_ event: ClaudeTabEvent?) -> Bool {
        event != nil && event?.time == lastAnnounced
    }
}
