//
//  ClaudePromptDraft.swift
//  Xylem
//
//  Typing Xylem's commands into Claude's prompt (the model and effort
//  menus, Compact, Clear, Goal…) without touching what the user has typed
//  there and not sent yet.
//
//  Claude Code's prompt stash (Ctrl+S, `chat:stash`; 2.1.328) puts a draft
//  away, shows "draft stashed" under the prompt and puts the draft back
//  after the next submit. Ctrl+S followed by a command in the same write
//  works: the draft is put away before the command's characters arrive. On
//  an empty prompt Ctrl+S does nothing, unless something is stashed
//  already: then it brings that back, so with "draft stashed" under the
//  prompt the key is not sent.
//

import Foundation

/// Runs the commands for one tab one after another, each once the draft the
/// previous one put away is back (or 3 s): a second press must not read the
/// screen before the first one's stash shows (its Ctrl+S would bring the
/// draft back), nor type into a draft that is coming back.
@MainActor
final class ClaudePromptInput {
    /// Room for Claude Code to take a command and redraw (the stash shows
    /// within ~25 ms) before the next one, when presses follow each other.
    static let gap: Duration = .milliseconds(250)

    private var queues: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]

    /// Runs `body` after the tab's earlier commands.
    func enqueue(_ session: TerminalSession, _ body: @escaping @MainActor () async -> Void) {
        let previous = queues[session.id]?.task
        let token = UUID()
        let task = Task { [weak self] in
            if let previous {
                await previous.value
                try? await Task.sleep(for: Self.gap)
            }
            await body()
            // A draft put away comes back only once Claude Code has taken the
            // command; the next command waits for that, or it would be typed
            // into the returning draft.
            try? await Task.sleep(for: Self.gap)
            _ = await session.waitForScreen(timeout: 3) { !ClaudePromptDraft.isStashed(onScreen: $0) }
            if self?.queues[session.id]?.token == token { self?.queues[session.id] = nil }
        }
        queues[session.id] = (token, task)
    }

    /// Types `command` and Return, with the draft put away first.
    func run(_ command: String, in session: TerminalSession) {
        enqueue(session) {
            ClaudePromptDraft.stash(in: session)
            session.runCommand(command)
        }
    }

    /// Types `text` without Return, with the draft put away first.
    func type(_ text: String, in session: TerminalSession) {
        enqueue(session) {
            ClaudePromptDraft.stash(in: session)
            session.send(text: text)
        }
    }
}

enum ClaudePromptDraft {
    /// Ctrl+S. Claude Code takes the plain control byte in kitty keyboard
    /// mode too.
    static let stashKey = "\u{13}"

    /// Puts a draft away; the command sent right after it lands on an empty
    /// prompt. Only while claude itself is in front: a shell takes Ctrl+S as
    /// XOFF and stops all output, an editor opened by `/memory` saves.
    static func stash(in session: TerminalSession) {
        guard session.launchedClaude, session.claudeIsInForeground,
              !isStashed(onScreen: session.visibleText())
        else { return }
        session.send(text: stashKey)
    }

    /// "draft stashed" in the rows under Claude's last prompt line (not in
    /// the conversation above it).
    nonisolated static func isStashed(onScreen screen: String) -> Bool {
        let rows = screen.components(separatedBy: "\n")
        guard let prompt = rows.lastIndex(where: { $0.contains("❯") }) else { return false }
        let below = rows[(prompt + 1)...].joined(separator: "\n")
        return ScreenText.flattened(below).contains("draftstashed")
    }
}
