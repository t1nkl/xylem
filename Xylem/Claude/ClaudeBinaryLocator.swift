//
//  ClaudeBinaryLocator.swift
//  Xylem
//
//  Where the `claude` a tab will run lives - what the Doctor reports. It
//  follows Settings → General → Binary path, the same value the tabs
//  launch. An absolute path is checked as is. A bare name is looked up the
//  way the tab's shell will look it up: on the PATH of an interactive login
//  shell. That is what finds claude installed through nvm, volta, mise or
//  asdf (their PATH entries come from `.zshrc`, which a GUI app never sees)
//  and what tells apart a claude the tab can't reach: Anthropic's installer
//  puts it in `~/.local/bin`, which isn't always on PATH - the folder alone
//  would say "found" for a tab that fails with "command not found".
//  Before, the Doctor checked three fixed folders and ignored the setting.
//
//  The usual install folders still matter: when the name isn't on PATH but
//  sits in one of them, the Doctor says where (and how to fix PATH); when
//  the shell can't be asked (timeout), they are the best guess.
//
//  The shell's PATH comes from LoginShellEnvironment (one interactive
//  login shell, off the main actor, with a timeout).
//

import Foundation

nonisolated enum ClaudeBinaryLocator {
    /// Install folders, in this order:
    /// Anthropic's installer, its older local install, Homebrew (Apple
    /// silicon, Intel), npm's documented user prefix, Volta and Bun.
    static func knownDirectories(home: String) -> [String] {
        [
            home + "/.local/bin",
            home + "/.claude/local",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            home + "/.npm-global/bin",
            home + "/.volta/bin",
            home + "/.bun/bin"
        ]
    }

    /// What the lookup found.
    enum Location: Equatable {
        /// The tabs will run this.
        case found(String)
        /// In an install folder, but not on the login shell's PATH: a tab
        /// asking for the bare name won't find it.
        case offPath(String)
    }

    /// Pure decision. `shellPath` is the login shell's PATH, nil when the
    /// shell couldn't be asked (then the install folders are trusted).
    static func resolve(
        configured: String,
        home: String,
        shellPath: [String]?,
        isExecutable: (String) -> Bool
    ) -> Location? {
        if configured.contains("/") {
            let path = expandingTilde(configured, home: home)
            return isExecutable(path) ? .found(path) : nil
        }
        if let shellPath, let found = firstExecutable(named: configured, in: shellPath, isExecutable: isExecutable) {
            return .found(found)
        }
        guard let folder = firstExecutable(named: configured, in: knownDirectories(home: home), isExecutable: isExecutable)
        else { return nil }
        return shellPath == nil ? .found(folder) : .offPath(folder)
    }

    static func firstExecutable(named name: String, in directories: [String], isExecutable: (String) -> Bool) -> String? {
        for directory in directories where !directory.isEmpty {
            let candidate = directory.hasSuffix("/") ? directory + name : directory + "/" + name
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    static func expandingTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst() }
        return path
    }

    /// Full lookup: a path as is, a bare name on the login shell's PATH
    /// (`LoginShellEnvironment`, passed in so one shell run serves the
    /// Doctor and the config folder).
    static func locate(configured: String, shellPath: [String]?) -> Location? {
        resolve(configured: configured,
                home: FileManager.default.homeDirectoryForCurrentUser.path,
                shellPath: shellPath,
                isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
    }
}
