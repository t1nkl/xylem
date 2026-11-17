//
//  HookBridgeHealth.swift
//  Xylem
//
//  Whether the tab-event hooks (ClaudeHookBridge) actually report. Tab
//  states, the "waiting for you" marks, the Dock badge and the session
//  binding all stand on them, and when they stop - `disableAllHooks` in
//  someone's settings, a managed policy that allows only its own hooks,
//  `~/.xylem` not writable, a Claude Code release that changes hooks -
//  everything quietly falls back to the old transcript-mtime guess. Doctor
//  shows this so the fallback is never silent.
//
//  The test is behavioural, not a config parse: every claude a tab starts
//  with our `--settings` fires SessionStart within seconds, so one that has
//  run for `silenceLimit` without a single event means the bridge is dead
//  for it, whatever the reason. The settings files are read only to explain
//  a failure (Doctor popover), never to decide it.
//
//  One exception, checked with a pty driver on 2.1.325: in a folder Claude
//  Code doesn't trust yet, nothing fires while the "trust this folder?"
//  question is open - SessionStart comes only after the answer. So a tab
//  counts only once the user has typed in it (that answer, or a prompt) and
//  `inputGrace` has passed since; an untouched tab proves nothing. Picking
//  "No, exit" there ends claude without a single event: a tab whose
//  terminal is back at a shell prompt (`claudeRunning` false) isn't judged
//  either - its claude is gone, so silence says nothing about the bridge.
//

import Foundation

nonisolated enum HookBridgeHealth: Equatable, Sendable {
    /// `~/.xylem/hooks` could not be written: tabs run without the bridge.
    case notInstalled
    /// No claude started with the hooks has run long enough to judge.
    case unknown
    /// Events arrive.
    case reporting
    /// These tabs' claude ran past `silenceLimit` without one event.
    case silent(tabs: [String])

    /// SessionStart comes within a few seconds even when resuming a large
    /// session; a minute leaves room for a slow machine.
    static let silenceLimit: TimeInterval = 60
    /// After the user's last keystroke: answering the trust question or
    /// submitting a prompt fires a hook at once.
    static let inputGrace: TimeInterval = 10

    /// One tab, as the evaluation needs it.
    struct Probe: Equatable, Sendable {
        let title: String
        /// The tab's claude was started with our `--settings`.
        let launchedWithHooks: Bool
        let startedAt: Date
        /// Latest event of THIS claude (not one left from before a relaunch).
        let lastEventAt: Date?
        /// The user's latest input to the tab, if any since it started.
        let lastInputAt: Date?
        /// False once the terminal is back at a shell prompt: claude exited
        /// (e.g. "No, exit" at the trust question). Only looked up for a tab
        /// that would otherwise count as silent.
        var claudeRunning = true

        /// Ran long enough, and was used, without one event.
        func isSilent(now: Date) -> Bool {
            guard claudeRunning, lastEventAt == nil, let input = lastInputAt, input >= startedAt else { return false }
            return now.timeIntervalSince(startedAt) >= silenceLimit
                && now.timeIntervalSince(input) >= inputGrace
        }
    }

    static func evaluate(installed: Bool, probes: [Probe], now: Date) -> HookBridgeHealth {
        guard installed else { return .notInstalled }
        let judged = probes.filter(\.launchedWithHooks)
        // One tab reporting proves the bridge; a silent one beside it is
        // still named.
        let silent = judged.filter { $0.isSilent(now: now) }
        if !silent.isEmpty { return .silent(tabs: silent.map(\.title)) }
        return judged.contains { $0.lastEventAt != nil } ? .reporting : .unknown
    }

    var isProblem: Bool {
        switch self {
        case .notInstalled, .silent: return true
        case .unknown, .reporting: return false
        }
    }
}

/// Settings that switch our hooks off, for the Doctor popover's "why".
nonisolated enum HookBlockers {
    /// Claude Code's managed policy file on macOS.
    static let managedSettings = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json")

    /// Human-readable reasons, e.g. "disableAllHooks in ~/.claude/settings.json".
    /// `home` only shortens paths for display.
    static func find(projectDirectory: String?,
                     userSettings: URL = ClaudeConfigDirectory.root.appending(path: "settings.json"),
                     home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     managed: URL = managedSettings) -> [String] {
        var files: [URL] = [userSettings]
        if let projectDirectory, !projectDirectory.isEmpty {
            let base = URL(fileURLWithPath: projectDirectory).appending(path: ".claude", directoryHint: .isDirectory)
            files += [base.appending(path: "settings.json"), base.appending(path: "settings.local.json")]
        }
        var reasons: [String] = []
        for file in files + [managed] {
            guard let data = SafeFileRead.data(file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let name = abbreviate(file.path, home: home)
            if object["disableAllHooks"] as? Bool == true { reasons.append("disableAllHooks in \(name)") }
            if file == managed, object["allowManagedHooksOnly"] as? Bool == true {
                reasons.append("allowManagedHooksOnly in \(name)")
            }
        }
        return reasons
    }

    private static func abbreviate(_ path: String, home: URL) -> String {
        let homePath = home.path
        return path.hasPrefix(homePath + "/") ? "~" + path.dropFirst(homePath.count) : path
    }
}
