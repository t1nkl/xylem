//
//  TerminalTab.swift
//  Xylem
//
//  Observable tab. One tab = one terminal pane (picker until the user
//  picks a folder, then a live shell session). Pane-tree splits used to
//  live here but were removed - the use case was thin (tmux audience
//  already had tmux) and they kept producing edge cases on restore.
//

import Foundation
import Observation

enum TerminalTabState {
    case picker
    case session(TerminalSession)
}

@Observable
final class TerminalTab: Identifiable {
    let id: UUID
    var title: String
    /// Set once the user explicitly renames the tab so we stop auto-updating
    /// the visible title from the shell's reported cwd.
    var hasCustomTitle: Bool = false
    var state: TerminalTabState
    /// True while Claude is working in this tab (hook state, or the
    /// transcript advancing when there is none). Written by
    /// TabActivityViewModel, read by the tab row. Lives on the tab (not in a
    /// central dict) so only that one row re-diffs when the flag flips.
    var isBusy: Bool = false
    /// Current git branch for this tab's live cwd, if it lives in a repo.
    /// Written by TabActivityViewModel (on cwd or `HEAD` change, equality-
    /// guarded); nil for non-repo dirs and pickers.
    var gitBranch: String?
    /// Most recent user prompt parsed from the session jsonl. Updated by
    /// TabActivityViewModel on the same poll that flips `isBusy`. nil for
    /// picker tabs or sessions that have no user-typed messages yet.
    var lastPrompt: String?

    /// The Claude session this tab's claude writes to. Set when the tab
    /// starts claude (`--session-id` / `--resume`), then follows the tab's
    /// hook events (`/clear` and `/resume` switch to another id). Persisted,
    /// so a relaunch continues it. nil = unbound (bare shell, or claude
    /// started by hand): readers fall back to the folder's newest session.
    var claudeSessionID: String?
    /// Set when the tab forked a session that was open elsewhere: until the
    /// fork's transcript exists (first message), a relaunch must go back to
    /// `original`, or the tab would find nothing and start empty.
    var pendingFork: SessionFork?
    /// Transcript path as reported by the hooks; more exact than deriving
    /// it from the working directory.
    var transcriptPath: String?
    /// What the tab's claude is doing, from hook events + pty output. nil
    /// = no hook data (yet): the busy flag falls back to transcript mtime.
    var claudeState: ClaudeTabState?
    /// Claude finished or asks for input while the user was looking
    /// elsewhere; cleared when the tab is seen.
    var needsAttention: Bool = false

    init(
        id: UUID = UUID(),
        title: String = "New Tab",
        state: TerminalTabState = .picker
    ) {
        self.id = id
        self.title = title
        self.state = state
        if case .session(let session) = state {
            self.claudeSessionID = session.claudeSessionID
        }
    }

    /// This tab's own transcript: the hook-reported path, else the bound
    /// id under the folder Claude Code files the working directory in.
    /// nil when the tab is unbound or its claude has exited.
    var transcriptURL: URL? {
        // claude exited: whatever runs next (e.g. `claude` typed by hand,
        // without our hooks) is followed through the folder's newest
        // session, as before binding existed. The id stays for a relaunch.
        if claudeState == .notRunning { return nil }
        let own: URL? = if let transcriptPath {
            URL(fileURLWithPath: transcriptPath)
        } else if let id = claudeSessionID, let directory = workingDirectory {
            TerminalSessionFactory.transcriptURL(directory: directory, sessionID: id)
        } else {
            nil
        }
        // An unwritten fork is still the original's conversation: show that
        // until the first message creates the fork's file.
        if let fork = pendingFork, fork.fork == claudeSessionID, let directory = workingDirectory,
           let own, !FileManager.default.fileExists(atPath: own.path) {
            return TerminalSessionFactory.transcriptURL(directory: directory, sessionID: fork.original)
        }
        return own
    }

    // MARK: - Convenience accessors

    var session: TerminalSession? {
        if case .session(let s) = state { return s }
        return nil
    }

    var workingDirectory: String? { session?.configuration.workingDirectory }

    /// True when this tab has a live shell session (vs a picker waiting on
    /// the user to pick a folder).
    var hasAnyRunningSession: Bool { session != nil }

    /// Still waiting for a folder (the New Tab screen).
    var isPicker: Bool {
        if case .picker = state { return true }
        return false
    }

    /// Cwd used by persistence - shells aren't serialised, only their working
    /// directories, so a relaunch can spawn a fresh shell in the same place.
    var primaryCwd: String? { workingDirectory }

    /// Live cwd as reported by the shell's OSC 7 stream - reflects `cd`
    /// after the session started. Null-safe fallback to the configured cwd.
    var liveCwd: String? {
        session?.reportedDirectory ?? session?.configuration.workingDirectory
    }

    /// What the tab list and the window title render. If the user has renamed
    /// the tab we respect that; otherwise it tracks the shell's live cwd so
    /// `cd ../other` retitles the tab to `other`.
    var displayTitle: String {
        if hasCustomTitle { return title }
        if let cwd = liveCwd, !cwd.isEmpty {
            let last = (cwd as NSString).lastPathComponent
            return last.isEmpty ? title : last
        }
        return title
    }

    /// A closed tab lets go of its session (terminal, buffers). SwiftUI keeps
    /// closed rows of the tab list cached and they hold the tab, so without
    /// this every closed tab kept its whole terminal in memory (measured:
    /// 8 opened, 7 closed, all 8 sessions alive).
    func releaseSession() {
        if case .session = state { state = .picker }
    }

    /// Replaces the picker with a live session - used by TabsViewModel when
    /// resuming a session or attaching to a freshly-picked folder. Today the
    /// previous state is always a picker; if it ever is a session, that
    /// shell is closed here so a replaced state can't leak a zsh.
    func attach(session: TerminalSession, title: String) {
        if let previous = self.session, previous !== session {
            previous.close()
        }
        self.state = .session(session)
        self.title = title
        self.claudeSessionID = session.claudeSessionID
        self.transcriptPath = nil
        self.claudeState = nil
        self.needsAttention = false
    }
}

extension TerminalTab: Hashable {
    static func == (lhs: TerminalTab, rhs: TerminalTab) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A restored tab's session forked under a new id (`--fork-session`).
struct SessionFork: Equatable {
    let original: String
    let fork: String
}
