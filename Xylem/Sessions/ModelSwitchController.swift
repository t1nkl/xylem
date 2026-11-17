//
//  ModelSwitchController.swift
//  Xylem
//
//  Switches the model of a running Claude session from the header menu and
//  remembers the pick until the transcript confirms it.
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

import Foundation
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

    private(set) var picks: [UUID: Pick] = [:]

    /// Types `/model <alias>` into the session. Claude Code queues it if a
    /// reply is still streaming.
    func switchModel(of session: TerminalSession, to choice: ClaudeModelChoice) {
        session.runCommand(choice.command)
        picks[session.id] = Pick(choice: choice, at: Date())
    }

    /// The model to show for a session: the pick until a reply to a prompt
    /// sent after it exists, else the transcript's model.
    static func displayedModel(pick: Pick?, stats: StatsSnapshot) -> (title: String?, choice: ClaudeModelChoice?) {
        if let pick, !transcriptConfirms(pick, stats: stats) {
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

    private static func transcriptConfirms(_ pick: Pick, stats: StatsSnapshot) -> Bool {
        guard let prompt = stats.lastPromptAt, prompt > pick.at,
              let reply = stats.lastAssistantAt, reply > prompt
        else { return false }
        return true
    }
}
