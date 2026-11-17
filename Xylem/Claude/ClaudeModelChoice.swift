//
//  ClaudeModelChoice.swift
//  Xylem
//
//  The models the header's model menu offers, and how a pick reaches
//  Claude Code: `/model <alias>` typed into the session switches at once
//  (no picker). Aliases follow the Claude Code docs: on the Anthropic API
//  `fable` → Fable 5.2, `opus` → Opus 5.5, `sonnet` → Sonnet 5.5,
//  `haiku` → Haiku 5.5. Aliases are used instead of full ids so the menu
//  keeps working when Claude Code moves an alias to a newer model.
//
//  Note: Claude Code also saves a `/model` pick as the default for new
//  sessions (the `model` field in ~/.claude/settings.json).
//

import Foundation

nonisolated struct ClaudeModelChoice: Identifiable, Hashable, Sendable {
    /// `/model` argument.
    let alias: String
    /// Menu title: the family only. The alias always resolves to the newest
    /// version, so a version number in the menu would just go stale.
    let title: String
    let subtitle: String
    /// Family keyword found in the full model id (`claude-opus-5-5`).
    let family: String

    var id: String { alias }
    var command: String { "/model \(alias)" }

    static let all: [ClaudeModelChoice] = [
        ClaudeModelChoice(alias: "fable", title: "Fable", subtitle: "Most capable", family: "fable"),
        ClaudeModelChoice(alias: "opus", title: "Opus", subtitle: "Default for complex work", family: "opus"),
        ClaudeModelChoice(alias: "sonnet", title: "Sonnet", subtitle: "Fast everyday coding", family: "sonnet"),
        ClaudeModelChoice(alias: "haiku", title: "Haiku", subtitle: "Fastest, cheapest", family: "haiku")
    ]

    /// The choice whose family appears in a full model id, if any.
    static func matching(modelID: String) -> ClaudeModelChoice? {
        let lower = modelID.lowercased()
        return all.first { lower.contains($0.family) }
    }
}
