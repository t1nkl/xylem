//
//  ShellPathFix.swift
//  Xylem
//
//  Doctor's "not on your PATH" fix: one command the user runs once in
//  Terminal that adds the folder to the startup file their login shell
//  really reads. Only the `export` line used to be shown; pasted into a
//  terminal it changes that window alone, so nothing seemed to happen.
//
//  Which file, by shell (a tab runs `$SHELL -l -i`):
//  - zsh: `.zshrc` in `$ZDOTDIR` (most people: the home folder).
//  - bash: a login bash reads only the FIRST of `.bash_profile`,
//    `.bash_login`, `.profile` that exists - creating a `.bash_profile`
//    next to a `.profile` would silently stop the `.profile` from loading.
//  - fish: `fish_add_path` (saved by fish itself, no file).
//  - csh / tcsh: `setenv` in `.cshrc` / `.tcshrc`; `export` is an error there.
//  - anything else (sh, ksh, dash): `.profile`.
//

import Foundation

nonisolated struct ShellPathFix: Equatable {
    /// For the sentence around the command, e.g. "~/.zshrc".
    let startupFile: String
    /// The real file to look into (nil for fish).
    let startupFilePath: String?
    /// Ready to paste into Terminal.
    let command: String

    /// - Parameters:
    ///   - folder: the folder that holds `claude`, e.g. `/Users/me/.local/bin`.
    ///   - shell: the user's login shell (`$SHELL`).
    ///   - home: the home folder; shown as `$HOME` inside the command.
    ///   - zdotdir: `$ZDOTDIR` when it is set (zsh reads its files there).
    ///   - fileExists: injected for tests.
    static func make(
        folder: String,
        shell: String,
        home: String,
        zdotdir: String? = nil,
        fileExists: (String) -> Bool
    ) -> ShellPathFix {
        let shown = homeRelative(folder, home: home)
        switch (shell as NSString).lastPathComponent {
        case "zsh":
            let dir = zdotdir.flatMap { $0.isEmpty ? nil : $0 } ?? home
            let display = homeRelative(dir, home: home, tilde: true) + "/.zshrc"
            // `${ZDOTDIR:-$HOME}`: right even when ZDOTDIR is set only by
            // the user's own .zshenv (Xylem's environment can't see that).
            return append(exportLine(shown), to: "\"${ZDOTDIR:-$HOME}/.zshrc\"",
                          display: display, path: dir + "/.zshrc")
        case "bash":
            let name = [".bash_profile", ".bash_login", ".profile"]
                .first { fileExists(home + "/" + $0) } ?? ".bash_profile"
            return append(exportLine(shown), to: "~/" + name, display: "~/" + name, path: home + "/" + name)
        case "fish":
            return ShellPathFix(startupFile: "fish's saved paths", startupFilePath: nil,
                                command: "fish_add_path \(doubleQuoted(shown))")
        case "csh", "tcsh":
            let name = fileExists(home + "/.tcshrc") ? ".tcshrc" : ".cshrc"
            let line = "setenv PATH \(doubleQuoted(shown + ":$PATH"))"
            return append(line, to: "~/" + name, display: "~/" + name, path: home + "/" + name)
        default:
            return append(exportLine(shown), to: "~/.profile", display: "~/.profile", path: home + "/.profile")
        }
    }

    /// The startup file already names the folder, yet the login shell's
    /// PATH lacks it: the line is there but doesn't work (commented out,
    /// PATH reset later, a typo), so the same line again wouldn't help.
    static func mentions(folder: String, home: String, in contents: String) -> Bool {
        let spellings = Set([folder,
                             homeRelative(folder, home: home),
                             homeRelative(folder, home: home, tilde: true),
                             homeRelative(folder, home: home).replacingOccurrences(of: "$HOME", with: "${HOME}")])
        return spellings.contains { contents.contains($0) }
    }

    private static func exportLine(_ folder: String) -> String {
        "export PATH=\(doubleQuoted(folder + ":$PATH"))"
    }

    private static func append(_ line: String, to target: String, display: String, path: String) -> ShellPathFix {
        ShellPathFix(startupFile: display, startupFilePath: path,
                     command: "echo \(singleQuoted(line)) >> \(target)")
    }

    /// `$HOME/.local/bin` (or `~/.local/bin`) instead of `/Users/me/.local/bin`.
    static func homeRelative(_ path: String, home: String, tilde: Bool = false) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return (tilde ? "~" : "$HOME") + path.dropFirst(home.count)
    }

    /// Double quotes keep `$HOME` / `$PATH` expanding; escape what would
    /// end or change the string.
    private static func doubleQuoted(_ s: String) -> String {
        var out = ""
        for c in s {
            if c == "\"" || c == "\\" || c == "`" { out.append("\\") }
            out.append(c)
        }
        return "\"\(out)\""
    }

    private static func singleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
