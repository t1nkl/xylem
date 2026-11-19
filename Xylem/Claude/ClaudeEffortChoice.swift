//
//  ClaudeEffortChoice.swift
//  Xylem
//
//  The effort levels the toolbar's effort menu offers, and how a pick
//  reaches Claude Code: its `/effort` picker, set for this session only
//  (see `ModelSwitchController.switchEffort`; Claude Code 2.1.328 levels:
//  low, medium, high, xhigh, max).
//
//  What a session runs at is read from its transcript: every assistant line
//  carries the level its request was sent with (`"effort":"medium"`), and
//  "auto" is written as the level it resolved to. The settings can't tell:
//  with `"effortLevel": "xhigh"` in settings.json, Claude Code 2.1.328 ran
//  new sessions at auto (medium); `CLAUDE_CODE_EFFORT_LEVEL` and an
//  organization cap override both.
//
//  `/effort <level>` typed with an argument would also save the level as
//  the default for new sessions of that model
//  (`modelSettings.<model>.effortLevel` in ~/.claude/settings.json); the
//  picker's "this session only" key keeps it to the session. "auto" has no place on the picker's
//  slider, so the menu doesn't offer it.
//

import Foundation

nonisolated struct ClaudeEffortChoice: Identifiable, Hashable, Sendable {
    /// `/effort` argument, also the value in the transcript.
    let level: String
    let title: String

    var id: String { level }

    /// Lowest to highest. A model with a lower cap gets the cap instead
    /// (Claude Code says so in the terminal; the next reply shows it here).
    static let levels: [ClaudeEffortChoice] = [
        ClaudeEffortChoice(level: "low", title: "Low"),
        ClaudeEffortChoice(level: "medium", title: "Medium"),
        ClaudeEffortChoice(level: "high", title: "High"),
        ClaudeEffortChoice(level: "xhigh", title: "Extra High"),
        ClaudeEffortChoice(level: "max", title: "Max")
    ]

    /// The choice for a transcript's level, if it is a known one.
    static func matching(level: String?) -> ClaudeEffortChoice? {
        guard let level = level?.lowercased() else { return nil }
        return levels.first { $0.level == level }
    }
}

/// Claude Code's `/effort` picker as it appears on screen (2.1.329). Its
/// hint depends on where the slider is: "←/→ to adjust · s to use this
/// session only · Enter to save · Esc to cancel" on every stop but the last
/// (max), "←/→ to adjust · Enter to use this session only · Esc to cancel"
/// there. Then "Set effort level to high (this session only): …". Matching
/// ignores whitespace and case: the terminal may wrap or pad it.
nonisolated enum EffortPicker {
    static let left = "\u{1B}[D"
    static let right = "\u{1B}[C"
    static let cancel = "\u{1B}"
    static let sessionKey = "s"
    static let enter = "\r"

    /// The key the picker on screen names for "this session only"; nil when
    /// no picker is open. Never the Enter that saves a default.
    static func sessionOnlyKey(onScreen screen: String) -> String? {
        let text = flattened(screen)
        guard text.contains("esctocancel") else { return nil }
        if text.contains("entertousethissessiononly") { return enter }
        if text.contains("stousethissessiononly") { return sessionKey }
        return nil
    }

    static func isOpen(onScreen screen: String) -> Bool {
        sessionOnlyKey(onScreen: screen) != nil
    }

    /// The levels of the "this session only" confirmations on screen, top
    /// to bottom.
    static func confirmations(onScreen screen: String) -> [String] {
        flattened(screen).matches(of: /seteffortlevelto([a-z]+)\(thissessiononly\)/).map { String($0.1) }
    }

    /// The slider's stops, left to right, from its label row ("low medium
    /// high xhigh max"; a model with a lower cap has fewer). Read with the
    /// whitespace gone, so a row split or padded by the terminal still
    /// matches. Nil when no such row is on screen.
    static func stops(onScreen screen: String) -> [String]? {
        let row = flattened(screen).firstMatch(of: /lowmedium(high)?(xhigh)?(max)?/)
        guard let row else { return nil }
        return ["low", "medium"] + [row.1, row.2, row.3].compactMap { $0.map(String.init) }
    }

    /// Lowercased, whitespace gone.
    static func flattened(_ screen: String) -> String {
        String(screen.lowercased().unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(Character.init))
    }
}
