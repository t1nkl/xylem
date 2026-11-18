//
//  ShellConfiguration.swift
//  Xylem
//
//  Declarative description of how to launch a login shell in a pty.
//  Decoupled from SwiftTerm: this type knows nothing about UI or rendering.
//

import Foundation

struct ShellConfiguration {
    let executablePath: String
    let arguments: [String]
    let workingDirectory: String?
    let environment: [String: String]
    let termName: String
    /// If present, executed *inside* the login shell before the user gets an
    /// interactive prompt, then the shell is re-exec'd so the session stays
    /// alive. Eliminates the race between zshrc and post-hoc `send(claude\n)`.
    /// Stored as argv-style tokens (not a single string) so arguments with
    /// spaces or shell metachars can be quoted safely before splicing.
    let initialCommand: [String]?

    var execName: String {
        "-" + (executablePath as NSString).lastPathComponent
    }

    /// The same shell running another first command.
    func replacingInitialCommand(_ command: [String]?) -> ShellConfiguration {
        ShellConfiguration(executablePath: executablePath, arguments: arguments,
                           workingDirectory: workingDirectory, environment: environment,
                           termName: termName, initialCommand: command)
    }

    var environmentList: [String] {
        var merged = environment
        merged["TERM"] = termName
        return merged.map { "\($0.key)=\($0.value)" }
    }

    /// Variables by which Claude Code marks the processes it starts. When
    /// Xylem itself was launched from inside a Claude Code session (e.g.
    /// `open Xylem.app` in its terminal), they would reach every tab's
    /// claude, which then runs as that session's child: transcript saving
    /// off, the parent's effort and session id. Each tab is its own
    /// top-level session, so they are dropped.
    nonisolated static let parentClaudeSessionKeys: Set<String> = [
        "CLAUDECODE",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_SESSION_ATTENDED",
        "CLAUDE_CODE_MESSAGING_SOCKET",
        "CLAUDE_CODE_MESSAGING_TOKEN",
        "CLAUDE_CODE_EXECPATH",
        "CLAUDE_PID",
        "CLAUDE_EFFORT"
    ]

    nonisolated static func removingParentClaudeSession(from environment: [String: String]) -> [String: String] {
        environment.filter { !parentClaudeSessionKeys.contains($0.key) }
    }

    /// A UTF-8 locale for tabs that would otherwise run without one. An app
    /// opened from the Finder or the Dock gets no LANG, and macOS 15's
    /// `/etc/zprofile` sets none (newer releases export `LANG=C.UTF-8` when
    /// it is unset; bash and fish never do). Without it `pbcopy`, which
    /// Claude Code copies with, reads its input as Mac Roman: copied
    /// Cyrillic pasted as "–ü—Ä–∏–≤—ñ—Ç". `C.UTF-8` is what macOS itself now
    /// picks: UTF-8 text without changing messages, dates or numbers. A
    /// locale the user set (LANG, LC_ALL or LC_CTYPE) is left alone.
    nonisolated static func addingUTF8Locale(to environment: [String: String]) -> [String: String] {
        let localeKeys = ["LANG", "LC_ALL", "LC_CTYPE"]
        guard localeKeys.allSatisfy({ environment[$0]?.isEmpty ?? true }) else { return environment }
        var env = environment
        env["LANG"] = "C.UTF-8"
        return env
    }

    /// The user's login shell: `$SHELL`, `/bin/zsh` when unset or empty.
    /// What every tab runs and what the Doctor asks.
    nonisolated static func userShell(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    }

    static func loginShell(
        workingDirectory: String? = nil,
        extraEnvironment: [String: String] = [:],
        initialCommand: [String]? = nil
    ) -> ShellConfiguration {
        let systemEnv = ProcessInfo.processInfo.environment
        let shell = userShell(environment: systemEnv)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cwd = workingDirectory ?? home

        var env = Self.addingUTF8Locale(to: Self.removingParentClaudeSession(from: systemEnv))
        env["HOME"] = env["HOME"] ?? home

        // Tell anything that reads TERM_PROGRAM (e.g. custom .zshrc logic)
        // which terminal it's running inside.
        env["TERM_PROGRAM"] = "Xylem"

        // SwiftTerm renders 24-bit colour, but nothing tells programs so:
        // with TERM=xterm-256color and an unknown TERM_PROGRAM, Claude Code's
        // colour detection (supports-color) settles on 256 colours and
        // quantises its RGB theme: wrong greys, a muddy prompt band and an
        // off-tone orange. COLORTERM=truecolor is the standard signal
        // (Ghostty, iTerm2, kitty and WezTerm all set it).
        env["COLORTERM"] = "truecolor"

        // Point zsh at our dotdir for its first startup file: our
        // `.zshenv` hands ZDOTDIR straight back to the user's own (saved in
        // XYLEM_USER_ZDOTDIR; unset = $HOME), sources their `.zshenv` and
        // installs the OSC 7 cwd hook, and zsh then reads the user's
        // `.zprofile`, `.zshrc` and `.zlogin` from their own ZDOTDIR - the
        // same trick Ghostty and VS Code use. Programs started from the shell
        // (claude, and the zsh scripts it runs) inherit the user's ZDOTDIR,
        // not ours.
        if shell.hasSuffix("/zsh") {
            env[userZDotDirKey] = systemEnv["ZDOTDIR"] ?? ""
            env["ZDOTDIR"] = Self.ensureZDotDir(home: home)
        }

        for (key, value) in extraEnvironment {
            env[key] = value
        }

        return ShellConfiguration(
            executablePath: shell,
            arguments: ["-l"],
            workingDirectory: cwd,
            environment: env,
            termName: "xterm-256color",
            initialCommand: initialCommand
        )
    }

    /// The user's ZDOTDIR while ours is in effect ("" = unset).
    static let userZDotDirKey = "XYLEM_USER_ZDOTDIR"

    /// Keeps `~/.xylem/zdotdir/.zshenv` in sync with the template below.
    /// It is the only file zsh reads from our dir: it restores the user's
    /// ZDOTDIR first, so the user's `.zshenv` (it used to be skipped - zsh
    /// looks for it in ZDOTDIR), `.zprofile`, `.zshrc` and `.zlogin` load as
    /// in any terminal. In interactive shells it then adds a precmd hook that
    /// emits OSC 7 with the cwd - what SwiftTerm's
    /// `hostCurrentDirectoryUpdate` delegate turns into the tab title.
    ///
    /// Runs on main for every new session, so it only writes when the
    /// content differs; the `.zshrc` / `.zprofile` of older versions are
    /// removed (nothing reads them any more).
    static func ensureZDotDir(home: String) -> String {
        let dir = home + "/.xylem/zdotdir"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        writeIfChanged(zshenvSource, to: dir + "/.zshenv")
        for stale in [".zshrc", ".zprofile"] where fm.fileExists(atPath: dir + "/" + stale) {
            try? fm.removeItem(atPath: dir + "/" + stale)
        }
        return dir
    }

    static let zshenvSource = """
    # Auto-generated by Xylem - rewritten on every launch, don't edit.
    # Xylem points ZDOTDIR here only so zsh runs this file first. Hand ZDOTDIR
    # back to the user's own right away: zsh then reads the user's .zshenv
    # (below) and later .zprofile, .zshrc and .zlogin from there, and nothing
    # started from this shell inherits Xylem's directory.
    if [[ -n "${\(userZDotDirKey)-}" ]]; then
        export ZDOTDIR="$\(userZDotDirKey)"
    else
        unset ZDOTDIR
    fi
    unset \(userZDotDirKey)
    if [[ -r "${ZDOTDIR:-$HOME}/.zshenv" ]]; then
        source "${ZDOTDIR:-$HOME}/.zshenv"
    fi
    if [[ -o interactive ]]; then
        autoload -Uz add-zsh-hook
        _xylem_report_cwd() {
            printf '\\033]7;file://%s%s\\033\\\\' "${HOST}" "${PWD//\\%/%25}"
        }
        add-zsh-hook precmd _xylem_report_cwd
        _xylem_report_cwd
    fi

    """

    private static func writeIfChanged(_ content: String, to path: String) {
        if let existing = try? String(contentsOfFile: path, encoding: .utf8), existing == content {
            return
        }
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
