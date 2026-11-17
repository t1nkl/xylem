//
//  TerminalTabTests.swift
//  XylemTests
//
//  One tab = one terminal session: picker vs session state, cwd tracking and
//  the display title rules.
//

import Testing
import Foundation

@MainActor
struct TerminalTabTests {

    @Test func startsAsPickerWithoutSession() {
        let tab = TerminalTab(title: "t", state: .picker)
        #expect(tab.session == nil)
        #expect(!tab.hasAnyRunningSession)
    }

    @Test func leafHostingSessionSurfacesItThroughHelpers() {
        let session = TerminalSession(title: "s", configuration: .loginShell())
        let tab = TerminalTab(title: "t", state: .session(session))
        #expect(tab.session?.id == session.id)
        #expect(tab.hasAnyRunningSession)
        #expect(tab.primaryCwd != nil)
    }

    @Test func liveCwdFallsBackToConfiguredDirectory() {
        let session = TerminalSession(title: "s", configuration: .loginShell(workingDirectory: "/tmp"))
        let tab = TerminalTab(title: "t", state: .session(session))
        #expect(tab.liveCwd == "/tmp")
    }

    @Test func displayTitleTracksLiveCwdUntilRenamed() {
        let session = TerminalSession(title: "s", configuration: .loginShell(workingDirectory: "/tmp/zzz"))
        let tab = TerminalTab(title: "s", state: .session(session))
        #expect(tab.displayTitle == "zzz")

        tab.title = "Custom"
        tab.hasCustomTitle = true
        #expect(tab.displayTitle == "Custom")
    }
}

@MainActor
struct TabAvatarInitialTests {
    @Test func initialIsTheFirstLetterOrDigitUppercased() {
        #expect(TabAvatar.initial(of: "sample-api") == "S")
        #expect(TabAvatar.initial(of: ".dotfiles") == "D")
        #expect(TabAvatar.initial(of: "_tools") == "T")
        #expect(TabAvatar.initial(of: "проєкт") == "П")
        #expect(TabAvatar.initial(of: "2048-game") == "2")
        #expect(TabAvatar.initial(of: "---") == "?")
    }
}
