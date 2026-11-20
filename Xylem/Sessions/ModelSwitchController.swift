//
//  ModelSwitchController.swift
//  Xylem
//
//  Switches the model or the effort level of a running Claude session from
//  the toolbar menus and remembers the pick until the transcript confirms it.
//
//  The header otherwise shows the model of the newest assistant message in
//  the session file. Claude Code queues `/model` until the current turn
//  ends, so the transcript keeps naming the old model for the rest of that
//  turn (an agentic turn can run for minutes). The pick therefore stays on
//  screen until the user has sent a new prompt after it AND a reply to that
//  prompt exists; from then on the transcript is authoritative again, which
//  also covers a model changed later by typing `/model` in the terminal.
//  No timers, nothing to clear by hand.
//
//  Effort follows the same rule (set for the session only, see
//  `switchEffort`). Claude Code 2.1.328 applies `/effort` from
//  the next request, but typed while a reply streams it leaves no line in
//  the transcript, and the replies still streaming name the old level.
//

import AppKit
import Observation

extension TerminalSession {
    /// True when the tab was started with `claude` (auto-start on). A tab
    /// without it is a bare shell, where typing `/model opus` makes no sense.
    var launchedClaude: Bool {
        configuration.initialCommand?.isEmpty == false
    }

    /// Its claude was started with the tab-event hooks (`--settings`).
    var launchedWithHooks: Bool {
        configuration.initialCommand?.contains("--settings") == true
    }
}

@Observable
final class ModelSwitchController {
    nonisolated struct Pick: Equatable, Sendable {
        let choice: ClaudeModelChoice
        let at: Date
    }

    nonisolated struct EffortPick: Equatable, Sendable {
        let choice: ClaudeEffortChoice
        let at: Date
    }

    private(set) var picks: [UUID: Pick] = [:]
    private(set) var effortPicks: [UUID: EffortPick] = [:]

    /// Types `/model <alias>` into the session. Claude Code queues it if a
    /// reply is still streaming.
    func switchModel(of session: TerminalSession, to choice: ClaudeModelChoice) {
        session.runCommand(choice.command)
        picks[session.id] = Pick(choice: choice, at: Date())
    }

    /// Sets the effort of this session only. `/effort <level>` typed with an
    /// argument also saves the level as the model's default for new
    /// sessions, except for max, which can't be a saved default (Claude Code
    /// 2.1.329): max is typed that way. The other levels go through the
    /// `/effort` picker, a slider over the levels the model has: left until
    /// it stops at low, right to the pick, then "s", "this session only" on
    /// every stop but max (where Enter saves a default; Enter is never sent).
    /// Picks for one session run one after another, and each first closes a
    /// picker left open with Esc, so no text lands in a picker. The
    /// confirmation Claude Code prints replaces the pick.
    func switchEffort(of session: TerminalSession, to choice: ClaudeEffortChoice) {
        // Claude has exited: `/effort` would go to the shell as a command.
        guard !session.shellIsInForeground else { NSSound.beep(); return }
        let pick = EffortPick(choice: choice, at: Date())
        effortPicks[session.id] = pick
        let previous = effortTasks[session.id]
        effortTasks[session.id] = Task { [weak self] in
            await previous?.value
            let succeeded = await Self.runEffort(in: session, to: choice) { confirmed in
                guard self?.effortPicks[session.id] == pick else { return }
                self?.effortPicks[session.id] = EffortPick(choice: confirmed, at: pick.at)
            }
            // A later pick owns the label now.
            guard !succeeded, self?.effortPicks[session.id] == pick else { return }
            self?.effortPicks[session.id] = nil
            NSSound.beep()
        }
    }

    @ObservationIgnored private var effortTasks: [UUID: Task<Void, Never>] = [:]

    /// The key sequence of `switchEffort`. False when a picker left open
    /// didn't close, the picker never came up or the model has no such
    /// level (nothing set).
    private static func runEffort(in session: TerminalSession, to choice: ClaudeEffortChoice,
                                  confirmed: (ClaudeEffortChoice) -> Void) async -> Bool {
        if EffortPicker.isOpen(onScreen: session.visibleText()) {
            session.send(text: EffortPicker.cancel)
            let closed = await waitFor(session, timeout: 2) { !EffortPicker.isOpen(onScreen: $0) }
            guard closed != nil else { return false }
        }
        if choice == ClaudeEffortChoice.levels.last {
            session.runCommand("/effort \(choice.level)")
            return true
        }
        session.send(text: "/effort\r")
        guard let open = await waitFor(session, timeout: 3, { EffortPicker.isOpen(onScreen: $0) }) else {
            // One that comes up late isn't left open for the user's Enter.
            if EffortPicker.isOpen(onScreen: session.visibleText()) { session.send(text: EffortPicker.cancel) }
            return false
        }
        // The stops are always the first levels in order (a lower cap cuts
        // the top), so the index works for any model the pick exists on.
        let stops = EffortPicker.stops(onScreen: open) ?? ClaudeEffortChoice.levels.map(\.level)
        guard let index = stops.firstIndex(of: choice.level) else {
            session.send(text: EffortPicker.cancel)
            return false
        }
        let earlier = EffortPicker.confirmations(onScreen: open).count
        // Left as many times as there are levels at all reaches low from
        // any stop. "s" goes out once the picker, now on the pick, offers it
        // (it doesn't on max, where the picker may have opened); otherwise
        // the picker is left with Esc (Enter would save a default).
        session.send(text: String(repeating: EffortPicker.left, count: ClaudeEffortChoice.levels.count)
                     + String(repeating: EffortPicker.right, count: index))
        guard await waitFor(session, timeout: 1.5, { EffortPicker.offersSessionKey(onScreen: $0) }) != nil else {
            session.send(text: EffortPicker.cancel)
            return false
        }
        session.send(text: EffortPicker.sessionKey)
        // A new confirmation below the earlier ones is this pick's answer.
        if let screen = await waitFor(session, timeout: 3, {
               !EffortPicker.isOpen(onScreen: $0) && EffortPicker.confirmations(onScreen: $0).count > earlier
           }),
           let level = EffortPicker.confirmations(onScreen: screen).last,
           let answer = ClaudeEffortChoice.matching(level: level), answer != choice {
            confirmed(answer)
        }
        return true
    }

    /// Polls the screen every 20 ms (a read of the live rows); the screen
    /// text once `found` holds.
    private static func waitFor(_ session: TerminalSession, timeout: TimeInterval,
                                _ found: (String) -> Bool) async -> String? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end, !Task.isCancelled {
            let screen = session.visibleText()
            if found(screen) { return screen }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    /// The effort to show for a session. With a status line input (current
    /// at once, see LiveEffort): the pick until an input newer than the pick
    /// arrives, then the input. Without one (Claude Code that doesn't pass
    /// it, hooks off): the pick until a reply to a prompt sent after it
    /// exists, else the newest reply's level; nil before the first reply.
    static func displayedEffort(pick: EffortPick?, live: LiveEffort? = nil, stats: StatsSnapshot) -> ClaudeEffortChoice? {
        if let live {
            if let pick, pick.at >= live.at { return pick.choice }
            return ClaudeEffortChoice.matching(level: live.level)
        }
        if let pick, !transcriptConfirms(pickedAt: pick.at, stats: stats) {
            return pick.choice
        }
        return ClaudeEffortChoice.matching(level: stats.effort)
    }

    /// The model to show for a session: the pick until a reply to a prompt
    /// sent after it exists, else the transcript's model.
    static func displayedModel(pick: Pick?, stats: StatsSnapshot) -> (title: String?, choice: ClaudeModelChoice?) {
        if let pick, !transcriptConfirms(pickedAt: pick.at, stats: stats) {
            return (pick.choice.title, pick.choice)
        }
        // The selector names the family only ("Opus", not "Opus 5.5"); an
        // unknown model falls back to the formatter's display name.
        let choice = ClaudeModelChoice.matching(modelID: stats.modelID)
        let title = choice?.title ?? (stats.modelDisplay == "-" ? nil : stats.modelDisplay)
        return (title, choice)
    }

    /// The settings' default model (`opus[1m]`) as a menu choice.
    static func defaultModelDisplay(_ defaultModel: String?) -> (title: String?, choice: ClaudeModelChoice?) {
        guard let choice = defaultModel.flatMap(ClaudeModelChoice.matching(modelID:)) else { return (nil, nil) }
        return (choice.title, choice)
    }

    private static func transcriptConfirms(pickedAt: Date, stats: StatsSnapshot) -> Bool {
        guard let prompt = stats.lastPromptAt, prompt > pickedAt,
              let reply = stats.lastAssistantAt, reply > prompt
        else { return false }
        return true
    }
}
