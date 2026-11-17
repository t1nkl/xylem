//
//  TerminalSessionFactory.swift
//  Xylem
//
//  Builds the ShellConfiguration + TerminalSession for a tab. TabsViewModel
//  used to assemble the `initialCommand` inline in five places (configure,
//  open project, resume, restore, seed), each re-reading AppSettings; one
//  copy drifting from the others would mean, e.g., restored tabs ignoring
//  the "auto-start Claude" switch. This type owns that decision and nothing
//  else - it doesn't know about tabs, selection or persistence.
//
//  Every claude it starts is bound to its tab:
//  · a fresh start gets `--session-id <new uuid>`, so the tab knows which
//    transcript is its own from the first second (two tabs in one folder
//    used to share the newest jsonl);
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
    /// Xylem no longer throws the conversation away. `startsImmediately:
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
        TerminalSession(
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
