//
//  ClaudePromptDraft.swift
//  Xylem
//
//  Typing Xylem's commands into Claude's prompt (the model and effort
//  menus, Compact, Clear, Goal…) without touching what the user has typed
//  there and not sent yet.
//
//  Claude Code's prompt stash (Ctrl+S, `chat:stash`; 2.1.328) puts a draft
//  away, shows "draft stashed" under the prompt (within ~25 ms) and puts the
//  draft back after the next submit. A command typed right after Ctrl+S,
//  before that shows, was sometimes still added to the draft, so the command
//  waits for it. On an empty prompt Ctrl+S does nothing, unless something is
//  stashed already: then it brings that back. So the key goes out only for
//  a draft on screen: the prompt row holds text that isn't dim (the empty
//  prompt's "Try …" hint is drawn dim).
//

import Foundation
import SwiftTerm

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

    /// Runs `body` after the tab's earlier commands. `submits`: the body
    /// presses Return, so a draft it put away comes back and the next
    /// command waits for that; text typed without Return keeps it away
    /// until the user sends it.
    func enqueue(_ session: TerminalSession, submits: Bool = true,
                 _ body: @escaping @MainActor () async -> Void) {
        let previous = queues[session.id]?.task
        let token = UUID()
        let task = Task { [weak self] in
            if let previous {
                await previous.value
                try? await Task.sleep(for: Self.gap)
                // Keys typed while the previous command's picker is still
                // open would act in it: wait for the input box again.
                if session.claudeIsInForeground {
                    _ = await session.waitForScreen(timeout: 2) { screen in
                        ClaudePromptDraft.promptRowIndex(screen.components(separatedBy: "\n")) != nil
                            && !EffortPicker.isOpen(onScreen: screen)
                    }
                }
            }
            await body()
            // A draft put away comes back only once Claude Code has taken the
            // command; the next command waits for that, or it would be typed
            // into the returning draft.
            if submits {
                try? await Task.sleep(for: Self.gap)
                _ = await session.waitForScreen(timeout: 3) { !ClaudePromptDraft.isStashed(onScreen: $0) }
            }
            if self?.queues[session.id]?.token == token { self?.queues[session.id] = nil }
        }
        queues[session.id] = (token, task)
    }

    /// Types `command` and Return, with the draft put away first.
    func run(_ command: String, in session: TerminalSession) {
        enqueue(session) {
            await ClaudePromptDraft.stash(in: session)
            session.runCommand(command)
        }
    }

    /// Types `text` without Return, with the draft put away first, then
    /// runs `then` (Goal gives the terminal the keyboard only now, so
    /// nothing the user types lands before the text).
    func type(_ text: String, in session: TerminalSession, then: @escaping @MainActor () -> Void = {}) {
        enqueue(session, submits: false) {
            await ClaudePromptDraft.stash(in: session)
            session.send(text: text)
            then()
        }
    }
}

enum ClaudePromptDraft {
    /// Ctrl+S. Claude Code takes the plain control byte in kitty keyboard
    /// mode too.
    static let stashKey = "\u{13}"

    /// Puts a draft away, so the command typed next lands on an empty
    /// prompt. Only while claude itself is in front: a shell takes Ctrl+S as
    /// XOFF and stops all output, an editor opened by `/memory` saves. With a
    /// stash of the user's own on screen nothing is sent (Ctrl+S would bring
    /// it back), so a new draft typed after it still gets the command
    /// appended.
    static func stash(in session: TerminalSession) async {
        guard session.launchedClaude, session.claudeIsInForeground else { return }
        let rows = session.visibleRows()
        let texts = rows.map(\.text)
        guard !isStashed(onScreen: texts.joined(separator: "\n")),
              let prompt = promptRowIndex(texts),
              hasDraft(promptCells: rows[prompt].cells.map { ($0.text, $0.attribute.style.contains(.dim)) })
        else { return }
        session.send(text: stashKey)
        _ = await session.waitForScreen(timeout: 1) { isStashed(onScreen: $0) }
    }

    /// The prompt row: the last "❯" row inside the input box, i.e. right
    /// under a horizontal rule and with another rule below it (a draft may
    /// take several rows). Lists in Claude's dialogs mark their selected row
    /// with "❯" too, outside such a box.
    nonisolated static func promptRowIndex(_ rows: [String]) -> Int? {
        func isRule(_ row: String) -> Bool { row.trimmingCharacters(in: .whitespaces).hasPrefix("─") }
        return rows.indices.last { index in
            guard index > 0, rows[index].contains("❯"), isRule(rows[index - 1]) else { return false }
            let below = rows[(index + 1)...]
            guard let bottom = below.firstIndex(where: isRule) else { return false }
            return !rows[(index + 1)..<bottom].contains { $0.contains("❯") }
        }
    }

    /// Text after "❯" that is not dim: a draft, not the empty prompt's hint.
    nonisolated static func hasDraft(promptCells: [(text: String, dim: Bool)]) -> Bool {
        guard let marker = promptCells.firstIndex(where: { $0.text == "❯" }) else { return false }
        return promptCells[(marker + 1)...].contains { cell in
            !cell.dim && !cell.text.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) || $0 == "\0" }
        }
    }

    /// "draft stashed" in the rows under Claude's prompt row (not in the
    /// conversation above it).
    nonisolated static func isStashed(onScreen screen: String) -> Bool {
        let rows = screen.components(separatedBy: "\n")
        guard let prompt = promptRowIndex(rows) else { return false }
        let below = rows[(prompt + 1)...].joined(separator: "\n")
        return ScreenText.flattened(below).contains("draftstashed")
    }
}
