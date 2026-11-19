//
//  ClaudePromptDraft.swift
//  Xylem
//
//  Keeps what the user has typed into Claude Code's prompt when Xylem types
//  a command there (the model and effort menus, Compact, Clear, Goal…):
//  without it the command was appended to the draft and the two went out as
//  one prompt.
//
//  Claude Code's prompt stash (Ctrl+S, `chat:stash`; 2.1.328) puts a draft
//  away, shows "draft stashed" under the prompt (within ~25 ms) and puts the
//  draft back after the next submit. On an empty prompt Ctrl+S does
//  nothing, unless something is stashed already: then it brings that back,
//  so with "draft stashed" on screen the key is not sent.
//

import Foundation

enum ClaudePromptDraft {
    /// Ctrl+S. Claude Code takes the plain control byte in kitty keyboard
    /// mode too.
    static let stashKey = "\u{13}"

    /// Puts a draft away before a command is typed. Only while Claude runs
    /// in the tab: a shell would take Ctrl+S as XOFF and stop all output.
    static func stash(in session: TerminalSession) async {
        guard session.launchedClaude, !session.shellIsInForeground,
              !isStashed(onScreen: session.visibleText())
        else { return }
        session.send(text: stashKey)
        // Nothing appears for an empty prompt: then this just runs out.
        _ = await session.waitForScreen(timeout: 0.3) { isStashed(onScreen: $0) }
    }

    nonisolated static func isStashed(onScreen screen: String) -> Bool {
        ScreenText.flattened(screen).contains("draftstashed")
    }
}

/// Text read off a terminal screen with the whitespace gone and lowercased,
/// so a line the terminal wrapped or padded still matches.
nonisolated enum ScreenText {
    static func flattened(_ screen: String) -> String {
        String(screen.lowercased().unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(Character.init))
    }
}
