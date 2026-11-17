//
//  ClaudeConfigDirectory.swift
//  Xylem
//
//  Where Claude Code keeps its user-level files - the one place Xylem
//  builds those paths. By default `~/.claude` (settings, plugins, skills,
//  agents, teams, projects) plus `~/.claude.json`; with CLAUDE_CONFIG_DIR
//  set, all of them live in that folder, `.claude.json` included (read
//  from Claude Code 2.1.325: `globalConfig = join(CLAUDE_CONFIG_DIR ||
//  homedir(), ".claude.json")`, `userSettings = join(CLAUDE_CONFIG_DIR ||
//  ~/.claude, "settings.json")`). People set it to keep separate accounts;
//  before, Xylem always read `~/.claude` - empty panels and usage for them,
//  and a relaunch couldn't find a tab's transcript to resume it.
//
//  The value that matters is the one the tabs' claude sees, i.e. the login
//  shell's (LoginShellEnvironment). It is saved, so launches start with the
//  last answer at once; the first launch without one asks the shell
//  synchronously (`bootstrap`), so restored tabs find their transcripts.
//  Paths are resolved (symlinks) once per change, not per read: Foundation
//  doesn't list a symlinked directory, and readers ask every few seconds.
//

import Foundation
import Synchronization

nonisolated enum ClaudeConfigDirectory {
    struct Paths: Equatable, Sendable {
        /// The configured value (CLAUDE_CONFIG_DIR, expanded); nil = default.
        let custom: String?
        /// The config folder, symlinks resolved.
        let root: URL
        /// `.claude.json` (MCP servers, per-project state).
        let globalConfigFile: URL
        /// `projects/`, symlinks resolved.
        let projects: URL
    }

    /// UserDefaults: the shell's last answer; "" = not set.
    static let defaultsKey = "claudeConfigDirectory"

    static func makePaths(custom: String?, home: URL) -> Paths {
        let expanded = custom.flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let tilde = ClaudeBinaryLocator.expandingTilde(trimmed, home: home.path)
            // Relative to the home folder - where a login shell starts.
            return tilde.hasPrefix("/") ? tilde : home.appending(path: tilde).path
        }
        let root = (expanded.map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? home.appending(path: ".claude", directoryHint: .isDirectory))
            .resolvingSymlinksInPath()
        let globalConfig = expanded.map { URL(fileURLWithPath: $0).appending(path: ".claude.json") }
            ?? home.appending(path: ".claude.json")
        return Paths(
            custom: expanded,
            root: root,
            globalConfigFile: globalConfig,
            projects: root.appending(path: "projects", directoryHint: .isDirectory).resolvingSymlinksInPath()
        )
    }

    private static let state = Mutex<Paths>(makePaths(
        custom: savedValue ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
        home: FileManager.default.homeDirectoryForCurrentUser
    ))

    private static var savedValue: String? {
        UserDefaults.standard.string(forKey: defaultsKey)
    }

    static var current: Paths { state.withLock { $0 } }
    static var root: URL { current.root }
    static var projects: URL { current.projects }
    static var globalConfigFile: URL { current.globalConfigFile }

    /// The shell's answer (nil = unset). Saves it; true when the folder
    /// changed, so the caller reloads what it read from the old one.
    @discardableResult
    static func apply(shellValue: String?) -> Bool {
        UserDefaults.standard.set(shellValue ?? "", forKey: defaultsKey)
        let next = makePaths(custom: shellValue, home: FileManager.default.homeDirectoryForCurrentUser)
        return state.withLock { paths in
            guard paths != next else { return false }
            paths = next
            return true
        }
    }

    /// First launch without a saved answer: ask the shell now (bounded), so
    /// tabs restored right after look in the right folder. Later launches
    /// use the saved answer and re-check in the background.
    static func bootstrap() {
        guard savedValue == nil else { return }
        // A shell that fails or hangs is saved as Xylem's own environment,
        // so it can't delay every launch; the background check corrects it.
        let fallback = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        let snapshot = LoginShellEnvironment.readBlocking(timeout: 3)
        apply(shellValue: snapshot.map(\.claudeConfigDirectory) ?? fallback)
    }
}
