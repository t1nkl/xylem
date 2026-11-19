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

    /// Sets the effort of this session only, through Claude Code's `/effort`
    /// picker: `/effort <level>` typed with an argument also saves the level
    /// as the model's default for new sessions, the picker's "s" does not
    /// (Claude Code 2.1.328). The picker is a slider from low to the model's
    /// highest level: left until it stops at low, right `index` times, "s".
    /// Keys go out only once the picker is on screen (else nothing more is
    /// sent), and the level Claude Code confirms replaces the pick (a model
    /// without some levels has fewer stops).
    func switchEffort(of session: TerminalSession, to choice: ClaudeEffortChoice) {
        guard let index = ClaudeEffortChoice.levels.firstIndex(of: choice) else { return }
        // Claude has exited: `/effort` would go to the shell as a command.
        guard !session.shellIsInForeground else { NSSound.beep(); return }
        effortTasks[session.id]?.cancel()
        effortPicks[session.id] = EffortPick(choice: choice, at: Date())
        effortTasks[session.id] = Task { [weak self] in
            session.send(text: "/effort\r")
            guard await Self.waitFor(session, timeout: 3, { EffortPicker.isOpen(onScreen: $0) }) != nil else {
                self?.effortPicks[session.id] = nil
                NSSound.beep()
                return
            }
            session.send(text: String(repeating: EffortPicker.left, count: ClaudeEffortChoice.levels.count)
                         + String(repeating: EffortPicker.right, count: index)
                         + EffortPicker.thisSessionOnly)
            // Closed = Claude Code has printed its answer; the newest one on
            // screen is this pick's.
            if let screen = await Self.waitFor(session, timeout: 3, { !EffortPicker.isOpen(onScreen: $0) }),
               let level = EffortPicker.confirmedLevel(onScreen: screen),
               let confirmed = ClaudeEffortChoice.matching(level: level), confirmed != choice {
                self?.effortPicks[session.id] = EffortPick(choice: confirmed, at: Date())
            }
        }
    }

    @ObservationIgnored private var effortTasks: [UUID: Task<Void, Never>] = [:]

    /// Polls the screen every 100 ms; the screen text once `found` holds.
    private static func waitFor(_ session: TerminalSession, timeout: TimeInterval,
                                _ found: (String) -> Bool) async -> String? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end, !Task.isCancelled {
            let screen = session.visibleText()
            if found(screen) { return screen }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// The effort to show for a session: the pick until a reply to a prompt
    /// sent after it exists, else the newest reply's level. Nil before the
    /// first reply: the level a new session runs at can't be read anywhere.
    static func displayedEffort(pick: EffortPick?, stats: StatsSnapshot) -> ClaudeEffortChoice? {
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
