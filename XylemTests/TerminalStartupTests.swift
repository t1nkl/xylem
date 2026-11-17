//
//  TerminalStartupTests.swift
//  XylemTests
//
//  When the "Starting Claude Code…" loader over a new terminal goes away.
//

import Testing
import Foundation

struct TerminalStartupTests {
    private func finished(claude: Bool = true, took: Bool = false, quiet: TimeInterval? = nil, typed: Bool = false,
                          running: Bool = true, elapsed: TimeInterval = 2) -> Bool {
        TerminalStartup.isFinished(launchesClaude: claude, claudeTookTheTerminal: took,
                                   quietSinceOutput: quiet, typed: typed,
                                   processRunning: running, elapsed: elapsed)
    }

    @Test func shellStartupOutputDoesNotEndClaudesLoader() {
        #expect(!finished(quiet: 0.2))
        #expect(finished(took: true, quiet: 0.1))
    }

    /// A `.zshrc` asking something before claude starts: shown, not hidden.
    @Test func startupOutputThatWentQuietIsShown() {
        #expect(!finished(quiet: TerminalStartup.quietLimit - 0.1))
        #expect(finished(quiet: TerminalStartup.quietLimit))
        // Nothing printed yet is not "quiet".
        #expect(!finished(quiet: nil, elapsed: 5))
    }

    @Test func aKeyTypedShowsTheTerminal() {
        #expect(finished(typed: true, elapsed: 0.5))
    }

    @Test func aPlainShellIsReadyWithItsFirstOutput() {
        #expect(!finished(claude: false))
        #expect(finished(claude: false, quiet: 0))
    }

    @Test func theLoaderNeverOutlivesTheLimitOrTheProcess() {
        #expect(finished(elapsed: TerminalStartup.limit))
        #expect(finished(running: false, elapsed: 2))
        // The process may not be up yet in the first moment.
        #expect(!finished(running: false, elapsed: 0.2))
    }
}
