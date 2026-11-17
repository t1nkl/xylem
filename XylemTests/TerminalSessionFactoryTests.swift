//
//  TerminalSessionFactoryTests.swift
//  XylemTests
//
//  The one place that decides what a new tab's shell runs first.
//

import Testing
import Foundation

@MainActor
struct TerminalSessionFactoryTests {

    private func factory(autoStart: Bool, binary: String = "/opt/claude") -> TerminalSessionFactory {
        TerminalSessionFactory(
            autoStartClaude: { autoStart },
            claudeBinaryPath: { binary },
            hookSettingsPath: { "/h/settings.json" },
            makeSessionID: { "new-id" }
        )
    }

    @Test func freshStartPinsANewSessionIDAndTheHooks() {
        let launch = factory(autoStart: true).freshLaunch()
        #expect(launch.command == ["/opt/claude", "--session-id", "new-id", "--settings", "/h/settings.json"])
        #expect(launch.sessionID == "new-id")
    }

    @Test func noHookFlagWhenTheHookFilesAreMissing() {
        var f = factory(autoStart: true)
        f.hookSettingsPath = { nil }
        #expect(f.freshLaunch().command == ["/opt/claude", "--session-id", "new-id"])
    }

    @Test func resumeIgnoresAutoStartAndHonoursBinaryOverride() {
        let f = factory(autoStart: false)
        #expect(f.resumeLaunch(sessionID: "abc").command == ["/opt/claude", "--resume", "abc", "--settings", "/h/settings.json"])
        #expect(f.resumeLaunch(sessionID: "abc", claudeBinary: "/x/claude").command.prefix(3) == ["/x/claude", "--resume", "abc"])
        #expect(f.resumeLaunch(sessionID: "abc").sessionID == "abc")
    }

    private func projectFactory(continueLast: Bool, latest: String?, autoStart: Bool = true) -> TerminalSessionFactory {
        TerminalSessionFactory(
            autoStartClaude: { autoStart },
            claudeBinaryPath: { "/opt/claude" },
            continueLastSession: { continueLast },
            latestSessionID: { _, _ in latest },
            hookSettingsPath: { nil },
            makeSessionID: { "new-id" }
        )
    }

    @Test func openingAProjectContinuesItsNewestSession() {
        #expect(projectFactory(continueLast: true, latest: "s-1").projectLaunch(directory: "/p")?.command
                == ["/opt/claude", "--resume", "s-1"])
    }

    @Test func freshClaudeWhenNoSessionSettingOffOrDirectoryAlreadyOpen() {
        let fresh = ["/opt/claude", "--session-id", "new-id"]
        #expect(projectFactory(continueLast: true, latest: nil).projectLaunch(directory: "/p")?.command == fresh)
        #expect(projectFactory(continueLast: false, latest: "s-1").projectLaunch(directory: "/p")?.command == fresh)
        #expect(projectFactory(continueLast: true, latest: "s-1").projectLaunch(directory: "/p", allowContinue: false)?.command == fresh)
        #expect(projectFactory(continueLast: true, latest: "s-1", autoStart: false).projectLaunch(directory: "/p") == nil)
    }

    @Test func projectContinueSkipsSessionsBoundToOtherTabs() {
        var seen: Set<String> = []
        var f = projectFactory(continueLast: true, latest: nil)
        f.latestSessionID = { _, excluded in seen = excluded; return nil }
        _ = f.projectLaunch(directory: "/p", excluding: ["a", "b"])
        #expect(seen == ["a", "b"])
    }

    @Test func restoreResumesTheTabsOwnSessionOnlyWhenItExists() {
        var f = projectFactory(continueLast: true, latest: "someone-else")
        f.sessionExists = { _, id in id == "mine" }
        #expect(f.restoreLaunch(directory: "/p", sessionID: "mine")?.command == ["/opt/claude", "--resume", "mine"])
        // Never prompted (no transcript yet) or unbound: fresh, and never
        // the folder's newest - that may be another tab's.
        #expect(f.restoreLaunch(directory: "/p", sessionID: "gone")?.command == ["/opt/claude", "--session-id", "new-id"])
        #expect(f.restoreLaunch(directory: "/p", sessionID: nil)?.command == ["/opt/claude", "--session-id", "new-id"])
        // Setting off: fresh; auto-start off: bare shell.
        var off = f; off.continueLastSession = { false }
        #expect(off.restoreLaunch(directory: "/p", sessionID: "mine")?.command == ["/opt/claude", "--session-id", "new-id"])
        var bare = f; bare.autoStartClaude = { false }
        #expect(bare.restoreLaunch(directory: "/p", sessionID: "mine") == nil)
    }

    @Test func transcriptLivesUnderTheEncodedWorkingDirectory() {
        let root = URL(fileURLWithPath: "/r")
        #expect(TerminalSessionFactory.transcriptURL(directory: "/Users/me/my_app", sessionID: "abc", projectsDirectory: root)?.path
                == "/r/-Users-me-my-app/abc.jsonl")
        #expect(TerminalSessionFactory.transcriptURL(directory: "", sessionID: "abc") == nil)
    }

    @Test func aSessionWrittenToJustNowIsNotResumed() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "xylem-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: SessionFileLocator.encodedFolderName(for: "/tmp/app"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "abc.jsonl")
        try Data("{}\n".utf8).write(to: file)
        let written = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: file.path)

        // Still being written (another terminal): start fresh.
        #expect(TerminalSessionFactory.resumableSessionID(in: "/tmp/app", projectsDirectory: root,
                                                          now: written.addingTimeInterval(30)) == nil)
        // Quiet for a while: safe to continue.
        #expect(TerminalSessionFactory.resumableSessionID(in: "/tmp/app", projectsDirectory: root,
                                                          now: written.addingTimeInterval(600)) == "abc")
        // Bound to another tab: not offered.
        #expect(TerminalSessionFactory.resumableSessionID(in: "/tmp/app", excluding: ["abc"], projectsDirectory: root,
                                                          now: written.addingTimeInterval(600)) == nil)
    }
}
