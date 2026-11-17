//
//  ShellConfigurationTests.swift
//  XylemTests
//
//  A tab's claude must start as its own session even when Xylem was
//  launched from inside a Claude Code session: the parent's session
//  markers are dropped, the user's own settings are kept.
//

import Testing

@MainActor
struct ShellConfigurationTests {

    @Test func parentSessionMarkersAreDropped() {
        let inherited = [
            "PATH": "/usr/bin",
            "CLAUDECODE": "1",
            "CLAUDE_CODE_CHILD_SESSION": "1",
            "CLAUDE_CODE_SESSION_ID": "abc",
            "CLAUDE_CODE_ENTRYPOINT": "cli",
            "CLAUDE_EFFORT": "medium",
            "CLAUDE_PID": "42",
            // A user setting, not a session marker.
            "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
        ]
        let cleaned = ShellConfiguration.removingParentClaudeSession(from: inherited)
        #expect(cleaned == [
            "PATH": "/usr/bin",
            "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
        ])
    }

    @Test func loginShellEnvironmentHasNoParentMarkers() {
        let env = ShellConfiguration.loginShell().environment
        for key in ShellConfiguration.parentClaudeSessionKeys {
            #expect(env[key] == nil)
        }
        #expect(env["COLORTERM"] == "truecolor")
    }
}

// MARK: - OSC 7 working directory

struct OSC7PathTests {
    @Test func plainAndHostPathsParse() {
        #expect(TerminalSession.pathFromOSC7("file://host.local/Users/someone/code") == "/Users/someone/code")
        #expect(TerminalSession.pathFromOSC7("file:///Users/someone/code") == "/Users/someone/code")
        #expect(TerminalSession.pathFromOSC7("file://host/") == "/")
    }

    /// What our zsh hook sends for awkward folder names: `$PWD` as is, `%`
    /// encoded. A URL parser cut the path at `#` / `?` and decoded `%41`.
    @Test func awkwardFolderNamesSurvive() {
        #expect(TerminalSession.pathFromOSC7("file://h/tmp/osc dir #1 ?x %2541 кир") == "/tmp/osc dir #1 ?x %41 кир")
        #expect(TerminalSession.pathFromOSC7("file://h/a#b") == "/a#b")
        #expect(TerminalSession.pathFromOSC7("file://h/a?b") == "/a?b")
    }

    /// Other OSC 7 senders encode the whole path.
    @Test func fullyEncodedPathsDecode() {
        #expect(TerminalSession.pathFromOSC7("file://h/a%20b/%D0%BA") == "/a b/к")
    }

    @Test func notAFileURLStaysAsIs() {
        #expect(TerminalSession.pathFromOSC7("/plain/path") == "/plain/path")
        #expect(TerminalSession.pathFromOSC7("file://hostonly") == "file://hostonly")
    }
}
