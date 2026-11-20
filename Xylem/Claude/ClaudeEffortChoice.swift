//
//  ClaudeEffortChoice.swift
//  Xylem
//
//  The effort levels the toolbar's effort menu offers, and how a pick
//  reaches Claude Code, for this session only (see
//  `ModelSwitchController.switchEffort`; Claude Code 2.1.329 levels: low,
//  medium, high, xhigh, max). Which Claude Code can do it (checked on every
//  npm release around the edges): `/effort max` from 2.1.76 (it can't be a
//  saved default, so it is session-only); the other levels for one session
//  from 2.1.257, whose picker added "s" for this session only (EffortSupport).
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

/// Claude Code's `/effort` picker as it appears on screen. Its hint names
/// the keys: "←/→ to adjust · Enter to confirm · s for this session only ·
/// Esc to cancel" (2.1.325), "←/→ to adjust · s to use this session only ·
/// Enter to save · Esc to cancel" on every stop but max and "←/→ to adjust ·
/// Enter to use this session only · Esc to cancel" on max (2.1.329). Then
/// "Set effort level to high (this session only): …". Matching ignores
/// whitespace and case: the terminal may wrap or pad it.
nonisolated enum EffortPicker {
    static let left = "\u{1B}[D"
    static let right = "\u{1B}[C"
    static let cancel = "\u{1B}"
    /// "this session only" on every stop but max, in both wordings.
    static let sessionKey = "s"

    /// A picker is on screen (its hint, in any of the wordings above).
    static func isOpen(onScreen screen: String) -> Bool {
        let text = flattened(screen)
        return text.contains("toadjust") && text.contains("esctocancel")
    }

    /// The open picker offers "s" for this session only.
    static func offersSessionKey(onScreen screen: String) -> Bool {
        let text = flattened(screen)
        return text.contains("sforthissessiononly") || text.contains("stousethissessiononly")
    }

    /// Claude Code turning `/effort` down on screen, counted so a new one
    /// can be told from one already there: "Unknown skill: effort" or
    /// "Unknown slash command: effort" (before 2.1.76), or the level printed
    /// instead of a picker ("Effort level: …", 2.1.76 to about 2.1.150).
    static func unsupportedMarks(onScreen screen: String) -> Int {
        let text = flattened(screen)
        return ["unknownskill:effort", "unknownslashcommand:effort", "effortlevel:"]
            .reduce(0) { $0 + text.components(separatedBy: $1).count - 1 }
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

/// What the effort menu needs from Claude Code, for the explanation shown
/// when a pick is turned down.
nonisolated enum EffortSupport {
    static let maxSince = "2.1.76"
    static let sessionLevelsSince = "2.1.257"

    /// Whether the menu can set `choice` for one session with Claude Code
    /// `version`; unknown versions are let through (the pick then explains
    /// itself if Claude Code turns it down).
    static func isAvailable(_ choice: ClaudeEffortChoice, version: String?) -> Bool {
        guard let version else { return true }
        let since = choice == ClaudeEffortChoice.levels.last ? maxSince : sessionLevelsSince
        return isVersion(version, atLeast: since)
    }

    /// Whether the menu can set any level at all (`/effort` exists).
    static func canSetAnything(version: String?) -> Bool {
        guard let version else { return true }
        return isVersion(version, atLeast: maxSince)
    }

    /// The menu's short header over levels this Claude Code can't set for
    /// one session.
    static let unavailableHeader = "Needs Claude Code \(sessionLevelsSince)+"

    /// The tooltip when the menu can't set anything.
    static func cantSetHelp(version: String) -> String {
        "Claude Code \(version) can't set the effort. Update Claude Code (claude update): Max needs \(maxSince)+, the other levels \(sessionLevelsSince)+"
    }

    /// Dotted versions compared number by number ("2.1.76" < "2.1.257").
    static func isVersion(_ version: String, atLeast minimum: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = minimum.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    /// The alert text; `version` is the running claude's when its process
    /// name gives it (the native build is named by its version).
    static func explanation(for choice: ClaudeEffortChoice, version: String?) -> (title: String, message: String) {
        let running = version.map { "Claude Code \($0)" } ?? "This version of Claude Code"
        let needs = choice == ClaudeEffortChoice.levels.last
            ? "Max needs Claude Code \(maxSince) or later."
            : "Setting \(choice.title) for one session needs Claude Code \(sessionLevelsSince) or later (Max works from \(maxSince))."
        return ("Effort can't be set for this session",
                "\(running) can't set the effort for one session. \(needs) Update Claude Code (claude update), then pick the level again.")
    }
}
