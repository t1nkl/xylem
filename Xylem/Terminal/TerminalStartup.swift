//
//  TerminalStartup.swift
//  Xylem
//
//  When a starting terminal is ready to be shown, so the "Starting Claude
//  Code…" loader (TerminalStartingOverlay) can go. Pure: TerminalSession
//  feeds it what the terminal shows, every 100 ms while starting.
//
//  claude, once it starts drawing, turns on the kitty keyboard protocol or
//  bracketed paste (checked live: before the folder trust question);
//  output before that is the user's shell start-up, which the loader
//  covers. A plain shell is ready with its first output. Nothing waiting
//  for the user stays hidden: a key typed, or start-up output that went
//  quiet (a `.zshrc` question, claude not found), shows the terminal.
//

import Foundation
import Synchronization

nonisolated enum TerminalStartup {
    /// The longest a loader stays, whatever happens in the terminal.
    static let limit: TimeInterval = 10

    /// Start-up output followed by this much quiet, before claude took
    /// over, is waiting for something. claude's first output comes ~0.3 s
    /// after it starts (measured on both Macs, 2.1.32x); a cold start on
    /// the Intel Mac took 2.75 s.
    static let quietLimit: TimeInterval = 3

    static func isFinished(
        launchesClaude: Bool,
        claudeTookTheTerminal: Bool,
        quietSinceOutput: TimeInterval?,
        typed: Bool,
        processRunning: Bool,
        elapsed: TimeInterval
    ) -> Bool {
        if elapsed >= limit || typed { return true }
        // The process may not be up in the very first moment.
        if !processRunning && elapsed > 1 { return true }
        guard let quiet = quietSinceOutput else { return false }
        return launchesClaude ? claudeTookTheTerminal || quiet >= quietLimit : true
    }
}

/// When output last arrived: set from SwiftTerm's I/O thread, read on main.
nonisolated final class LastOutput: Sendable {
    private let time = Mutex<Date?>(nil)
    func mark() { time.withLock { $0 = Date() } }
    var value: Date? { time.withLock { $0 } }
}
