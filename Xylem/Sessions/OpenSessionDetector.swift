//
//  OpenSessionDetector.swift
//  Xylem
//
//  Is a Claude session already open somewhere else? A restored tab resumes
//  its own session, but the same session may be running in another app
//  (another Claude Code GUI, a terminal) by then, and two claude processes
//  would append to one transcript. Then the tab forks it instead
//  (TerminalSessionFactory.forkLaunch): same conversation, new session id,
//  nothing written to the other process's file.
//
//  The check reads every process's command line (`ps`, ~40 ms) for the id
//  as the value of `--resume`/`-r`/`--session-id` - that is how Xylem,
//  other Claude Code GUIs and a typed `claude --resume <id>` start a session. The bare id
//  alone isn't enough: any `grep <id>` would count, so the line must name
//  claude too (`grep -r <id>` has a `-r`). A session opened from
//  the `/resume` picker has no id on its command line and isn't seen.
//

import Foundation

nonisolated enum OpenSessionDetector {
    /// Whether a running process was started on `sessionID`. Processes a
    /// Xylem tab started (they carry our hook settings) don't count: when
    /// a restored tab starts, no tab of this Xylem runs that session, so
    /// such a process is the previous launch's claude still shutting down
    /// (a quick relaunch) - forking for it would be needless. Runs `ps` on
    /// a GCD thread.
    static func isOpen(sessionID: String) async -> Bool {
        let ownMarker = ClaudeHookBridge.settingsFileMarker
        return await withCheckedContinuation { continuation in
            queue.async {
                let listing = processListing()
                continuation.resume(returning: listing.map {
                    mentions(sessionID: sessionID, in: $0, ignoringLinesContaining: ownMarker)
                } ?? false)
            }
        }
    }

    /// Pure: `ps -o pid=,command=` output → does a command start `sessionID`?
    static func mentions(sessionID: String, in listing: String, ignoringLinesContaining ignored: String? = nil) -> Bool {
        guard !sessionID.isEmpty else { return false }
        let flags: Set<String> = ["--resume", "-r", "--session-id"]
        for line in listing.split(separator: "\n") where line.contains(sessionID) && line.contains("claude") {
            if let ignored, line.contains(ignored) { continue }
            // ~1100 processes: only the few lines naming the id get split.
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let pidField = fields.first, Int32(pidField) != nil else { continue }
            let arguments = fields.dropFirst()
            // A flag followed by the id, or `--resume=<id>`. Quotes and a
            // trailing `;` are how shell wrappers show it (`zsh -c 'claude'
            // '--resume' 'id'`, `… --resume id; exec …`).
            let tokens = arguments.map(strip)
            for (flag, value) in zip(tokens, tokens.dropFirst()) where flags.contains(flag) {
                if value == sessionID { return true }
            }
            for token in tokens where token.hasPrefix("--resume=") || token.hasPrefix("--session-id=") {
                if token.drop(while: { $0 != "=" }).dropFirst() == sessionID { return true }
            }
        }
        return false
    }

    private static let wrapperPunctuation = CharacterSet(charactersIn: "'\";")

    private static func strip(_ value: Substring) -> String {
        value.trimmingCharacters(in: wrapperPunctuation)
    }

    private static let queue = DispatchQueue(label: "xylem.open-sessions", qos: .userInitiated)

    /// At most 5 s: a restored tab starts only after this answers, so a
    /// stuck `ps` must not keep it from starting (nil = "not open
    /// elsewhere", the tab resumes in place).
    private static func processListing() -> String? {
        guard let result = ProcessRunner.run("/bin/ps", ["-axww", "-o", "pid=,command="], timeout: 5),
              result.exited, result.status == 0
        else { return nil }
        return String(decoding: result.output, as: UTF8.self)
    }
}
