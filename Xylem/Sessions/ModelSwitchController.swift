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
    @ObservationIgnored private let input: ClaudePromptInput

    init(input: ClaudePromptInput) {
        self.input = input
    }

    /// Types `/model <alias>` into the session, with the user's draft put
    /// away first (ClaudePromptInput). Claude Code queues it if a reply is
    /// still streaming.
    func switchModel(of session: TerminalSession, to choice: ClaudeModelChoice) {
        picks[session.id] = Pick(choice: choice, at: Date())
        input.run(choice.command, in: session)
    }

    /// Sets the effort of this session only, through Claude Code's `/effort`
    /// picker: `/effort <level>` typed with an argument also saves the level
    /// as the model's default for new sessions, the picker's "s" does not
    /// (Claude Code 2.1.328). The picker is a slider over the levels the
    /// model has, read off the screen: left until it stops at the first,
    /// right to the pick, "s". Keys go out only while the picker is on
    /// screen; a picker already open is closed with Esc first (its Enter
    /// would save a default), and the user's draft is put away
    /// (ClaudePromptDraft). Runs after the tab's earlier commands
    /// (ClaudePromptInput), so a Compact pressed meanwhile can't land in the
    /// picker. The confirmation Claude Code prints replaces the pick.
    func switchEffort(of session: TerminalSession, to choice: ClaudeEffortChoice) {
        // Claude has exited: `/effort` would go to the shell as a command.
        guard !session.shellIsInForeground else { NSSound.beep(); return }
        let pick = EffortPick(choice: choice, at: Date())
        effortPicks[session.id] = pick
        input.enqueue(session) { [weak self] in
            let succeeded = await Self.runEffortPicker(in: session, to: choice) { confirmed in
                guard self?.effortPicks[session.id] == pick else { return }
                self?.effortPicks[session.id] = EffortPick(choice: confirmed, at: pick.at)
            }
            // A later pick owns the label now.
            guard !succeeded, self?.effortPicks[session.id] == pick else { return }
            self?.effortPicks[session.id] = nil
            NSSound.beep()
        }
    }

    /// The key sequence of `switchEffort`. False when the picker never came
    /// up or the model has no such level (nothing set).
    private static func runEffortPicker(in session: TerminalSession, to choice: ClaudeEffortChoice,
                                        confirmed: (ClaudeEffortChoice) -> Void) async -> Bool {
        if EffortPicker.isOpen(onScreen: session.visibleText()) {
            session.send(text: EffortPicker.cancel)
            let closed = await session.waitForScreen(timeout: 2) { !EffortPicker.isOpen(onScreen: $0) }
            guard closed != nil else { return false }
        }
        ClaudePromptDraft.stash(in: session)
        session.send(text: "/effort\r")
        guard let open = await session.waitForScreen(timeout: 3, { EffortPicker.isOpen(onScreen: $0) }) else { return false }
        let stops = EffortPicker.stops(onScreen: open) ?? ClaudeEffortChoice.levels.map(\.level)
        guard let index = stops.firstIndex(of: choice.level) else {
            session.send(text: EffortPicker.cancel)
            return false
        }
        let earlier = EffortPicker.confirmations(onScreen: open).count
        session.send(text: String(repeating: EffortPicker.left, count: stops.count)
                     + String(repeating: EffortPicker.right, count: index)
                     + EffortPicker.thisSessionOnly)
        // A new confirmation below the earlier ones is this pick's answer.
        if let screen = await session.waitForScreen(timeout: 3, {
               !EffortPicker.isOpen(onScreen: $0) && EffortPicker.confirmations(onScreen: $0).count > earlier
           }),
           let level = EffortPicker.confirmations(onScreen: screen).last,
           let answer = ClaudeEffortChoice.matching(level: level), answer != choice {
            confirmed(answer)
        }
        return true
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
