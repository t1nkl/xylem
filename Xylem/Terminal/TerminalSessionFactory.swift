//
//  TerminalSessionFactory.swift
//  Xylem
//
//  Builds the ShellConfiguration + TerminalSession for a tab, for every
//  path (configure, open project, resume, restore, seed), so none of them
//  can drift from the others (e.g. restored tabs ignoring the "auto-start
//  Claude" switch). This type owns that decision and nothing else - it
//  doesn't know about tabs, selection or persistence.
//
//  Every claude it starts is bound to its tab:
//  · a fresh start gets `--session-id <new uuid>`, so the tab knows which
//    transcript is its own from the first second (two tabs in one folder
//    don't share the newest jsonl);
//  · `--settings <hooks>` reports the session's events back to the tab
//    (ClaudeHookBridge), which follows `/clear` and `/resume` to new ids;
//  · the shell exports `XYLEM_TAB_ID`, the key the hook writes under.
//

import Foundation

struct TerminalSessionFactory {
    /// Read at build time (not captured at init) so a Settings change
    /// applies to the next tab without recreating the factory.
    var autoStartClaude: () -> Bool = { AppSettings.autoStartClaude }
    var claudeBinaryPath: () -> String = { AppSettings.claudeBinaryPath }
    var continueLastSession: () -> Bool = { AppSettings.continueLastSession }
    /// Newest session of a project directory that nobody is writing to,
    /// leaving out sessions other tabs are bound to.
    var latestSessionID: (String, Set<String>) -> String? = { directory, excluded in
        Self.resumableSessionID(in: directory, excluding: excluded)
    }
    /// Newest session of a folder, however recent - for tabs saved before
    /// tabs remembered their session (one-time migration on restore).
    var newestSessionID: (String, Set<String>) -> String? = { directory, excluded in
        SessionFileLocator.latestSessionFile(for: directory, excluding: excluded)?
            .deletingPathExtension().lastPathComponent
    }
    /// `--settings` file with the tab-event hooks; nil runs claude without
    /// them (tests, or the files could not be written).
    var hookSettingsPath: () -> String? = { ClaudeHookBridge.installedSettingsPath }
    /// Whether a session's transcript exists, i.e. `--resume` can open it.
    var sessionExists: (_ directory: String, _ sessionID: String) -> Bool = { directory, id in
        Self.transcriptURL(directory: directory, sessionID: id).map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
    }
    var makeSessionID: () -> String = { UUID().uuidString.lowercased() }
    /// Whether a session is already running in another process (another
    /// app, a terminal): a restored tab then forks it (`forkLaunch`).
    var isSessionOpenElsewhere: (String) async -> Bool = { id in
        await OpenSessionDetector.isOpen(sessionID: id)
    }

    /// What a tab's claude is started with, and the session it writes to.
    struct Launch: Equatable {
        let command: [String]
        let sessionID: String
    }

    /// The project's newest session id, unless that session was written to
    /// in the last `quietPeriod`: then it is most likely open in another
    /// terminal (e.g. Claude Code running outside Xylem), and resuming it
    /// would put two claude processes on one session file. Sessions bound
    /// to other tabs are skipped for the same reason.
    nonisolated static func resumableSessionID(
        in directory: String,
        excluding excluded: Set<String> = [],
        projectsDirectory: URL = SessionFileLocator.defaultProjectsDirectory,
        now: Date = Date(),
        quietPeriod: TimeInterval = 120
    ) -> String? {
        guard let url = SessionFileLocator.latestSessionFile(
                for: directory,
                projectsDirectory: projectsDirectory,
                excluding: excluded
              ),
              let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              now.timeIntervalSince(modified) >= quietPeriod
        else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }

    /// Where Claude Code keeps a session started in `directory`.
    nonisolated static func transcriptURL(
        directory: String,
        sessionID: String,
        projectsDirectory: URL = SessionFileLocator.defaultProjectsDirectory
    ) -> URL? {
        guard !directory.isEmpty, !sessionID.isEmpty else { return nil }
        return projectsDirectory
            .appending(path: SessionFileLocator.encodedFolderName(for: directory), directoryHint: .isDirectory)
            .appending(path: sessionID + ".jsonl")
    }

    // MARK: - Sessions

    /// A login shell in `directory` (nil = home) that runs a fresh `claude`
    /// first when `launchClaude` and the user's auto-start setting allow it.
    func makeSession(
        tabID: UUID,
        title: String,
        directory: String?,
        launchClaude: Bool = true
    ) -> TerminalSession {
        session(tabID: tabID, title: title, directory: directory,
                launch: launchClaude && autoStartClaude() ? freshLaunch() : nil)
    }

    /// Opening a project: continues the project's newest Claude session
    /// (`claude --resume <id>`) when the "continue last session" setting is
    /// on and one exists, else starts a fresh `claude` (or a bare shell when
    /// auto-start is off). `allowContinue` is false when the directory is
    /// already open in another tab; `excluding` lists the sessions other
    /// tabs are bound to.
    func makeProjectSession(
        tabID: UUID,
        title: String,
        directory: String,
        launchClaude: Bool = true,
        allowContinue: Bool = true,
        excluding: Set<String> = []
    ) -> TerminalSession {
        session(tabID: tabID, title: title, directory: directory,
                launch: projectLaunch(directory: directory, launchClaude: launchClaude,
                                      allowContinue: allowContinue, excluding: excluding))
    }

    /// `claude --resume <id>`. Resuming is an explicit request, so the
    /// auto-start setting doesn't apply.
    func makeResumeSession(
        tabID: UUID,
        title: String,
        directory: String,
        sessionID: String,
        claudeBinary: String? = nil
    ) -> TerminalSession {
        session(tabID: tabID, title: title, directory: directory,
                launch: resumeLaunch(sessionID: sessionID, claudeBinary: claudeBinary))
    }

    /// A tab coming back after a relaunch continues its own session when
    /// its transcript exists (and the "continue" setting is on), so quitting
    /// Xylem doesn't throw the conversation away. `startsImmediately:
    /// false` leaves the shell for `TerminalSession.start()` - the tab
    /// starts when the user first opens it.
    func makeRestoredSession(
        tabID: UUID,
        title: String,
        directory: String,
        sessionID: String?,
        startsImmediately: Bool = true
    ) -> TerminalSession {
        session(tabID: tabID, title: title, directory: directory,
                launch: restoreLaunch(directory: directory, sessionID: sessionID),
                startsImmediately: startsImmediately)
    }

    private func session(tabID: UUID, title: String, directory: String?, launch: Launch?,
                         startsImmediately: Bool = true) -> TerminalSession {
        if launch != nil, let hooks = hookSettingsPath() {
            // Off main: a few settings reads and a write per tab, done long
            // before claude draws its first status line.
            Task.detached(priority: .utility) {
                Self.keepUserStatusLine(tabID: tabID, directory: directory, hookSettingsPath: hooks)
            }
        }
        return TerminalSession(
            id: tabID,
            title: title,
            configuration: .loginShell(
                workingDirectory: directory,
                extraEnvironment: [ClaudeHookBridge.environmentKey: tabID.uuidString],
                initialCommand: launch?.command
            ),
            claudeSessionID: launch?.sessionID,
            startsImmediately: startsImmediately
        )
    }

    /// Keeps the user's own status line command for the folder where
    /// Xylem's status line script reads it: `tab-events` beside the hook
    /// settings the tab's claude starts with (ClaudeHookBridge), owner-only,
    /// not in the tab's environment where every program would see it.
    /// Nothing is written when that folder doesn't exist (hooks not
    /// installed there).
    nonisolated static func keepUserStatusLine(tabID: UUID, directory: String?, hookSettingsPath: String,
                                   settings: ClaudeSettingsReading = ClaudeSettingsReader()) {
        let events = URL(fileURLWithPath: hookSettingsPath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tab-events", directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: events.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return }
        ClaudeHookBridge.setUserStatusLine(userStatusLine(directory: directory, settings: settings)?.command,
                                           forTab: tabID, in: events)
    }

    /// The status line Claude Code would run in the folder without Xylem's:
    /// local, then project, then user settings (its padding is applied from
    /// the user's global one, see ClaudeHookBridge).
    nonisolated static func userStatusLine(directory: String?, settings: ClaudeSettingsReading) -> ClaudeSettings.StatusLine? {
        let project = directory.map { settings.readProjectSettings(at: $0) }
        let candidates = [project?.local?.statusLine, project?.shared?.statusLine, settings.readGlobalSettings()?.statusLine]
        return candidates.compactMap { $0 }.first { $0.command?.isEmpty == false }
    }

    // MARK: - Commands (pure, unit-tested)

    func freshLaunch(claudeBinary: String? = nil) -> Launch {
        let id = makeSessionID()
        return Launch(command: [claudeBinary ?? claudeBinaryPath(), "--session-id", id] + hookArguments(), sessionID: id)
    }

    func resumeLaunch(sessionID: String, claudeBinary: String? = nil) -> Launch {
        Launch(command: [claudeBinary ?? claudeBinaryPath(), "--resume", sessionID] + hookArguments(), sessionID: sessionID)
    }

    /// Continues `sessionID`'s conversation under a new id
    /// (`--fork-session`; Claude Code requires it for `--session-id` with
    /// `--resume`): for a session that another process still writes to.
    func forkLaunch(sessionID: String, claudeBinary: String? = nil) -> Launch {
        let id = makeSessionID()
        return Launch(
            command: [claudeBinary ?? claudeBinaryPath(), "--resume", sessionID, "--fork-session", "--session-id", id]
                + hookArguments(),
            sessionID: id
        )
    }

    /// The session a launch command resumes in place (not a fork), if any.
    nonisolated static func resumedSessionID(in command: [String]?) -> String? {
        guard let command, !command.contains("--fork-session"),
              let index = command.firstIndex(of: "--resume"), command.indices.contains(index + 1)
        else { return nil }
        return command[index + 1]
    }

    func projectLaunch(
        directory: String,
        launchClaude: Bool = true,
        allowContinue: Bool = true,
        excluding: Set<String> = []
    ) -> Launch? {
        guard launchClaude, autoStartClaude() else { return nil }
        if allowContinue, continueLastSession(), let id = latestSessionID(directory, excluding) {
            return resumeLaunch(sessionID: id)
        }
        return freshLaunch()
    }

    func restoreLaunch(directory: String, sessionID: String?) -> Launch? {
        guard autoStartClaude() else { return nil }
        if continueLastSession(), let id = sessionID, sessionExists(directory, id) {
            return resumeLaunch(sessionID: id)
        }
        return freshLaunch()
    }

    private func hookArguments() -> [String] {
        hookSettingsPath().map { ["--settings", $0] } ?? []
    }
}
