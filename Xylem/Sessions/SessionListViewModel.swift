//
//  SessionListViewModel.swift
//  Xylem
//
//  Sessions and projects for the right panel and the new-tab picker:
//    · `sessions`         newest sessions across all projects (welcome
//                         sheet "Resume", sidebar in "All" mode)
//    · `projectSessions`  newest sessions of the active project (sidebar in
//                         "This project" mode)
//    · `projects`         every project folder (Directories, always global)
//
//  The active project's session folder is watched, so a new Claude session
//  appears without a manual refresh. All file work runs off the main actor.
//

import Foundation
import Observation

@Observable
final class SessionListViewModel {
    private(set) var sessions: [ClaudeSession] = []
    private(set) var projectSessions: [ClaudeSession] = []
    private(set) var projects: [ClaudeProject] = []
    private(set) var isLoading = false
    private(set) var projectDirectory: String?

    @ObservationIgnored private let sessionReader: ClaudeSessionReading
    @ObservationIgnored private let projectRepository: ClaudeProjectRepositoryProtocol
    @ObservationIgnored private let watcher = FileSystemWatcher()
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var lastCheckedNewest: NewestSession?

    nonisolated private static let limit = 50

    init(
        sessionReader: ClaudeSessionReading = ClaudeSessionReader(),
        projectRepository: ClaudeProjectRepositoryProtocol = ClaudeProjectRepository()
    ) {
        self.sessionReader = sessionReader
        self.projectRepository = projectRepository
        watcher.setHandler { [weak self] in
            let target = self
            Task { @MainActor in target?.reload() }
        }
    }

    /// Switches the project the panel is scoped to and reloads.
    func setProjectDirectory(_ directory: String?) {
        guard directory != projectDirectory else { return }
        projectDirectory = directory
        if directory == nil, !projectSessions.isEmpty { projectSessions = [] }
        watcher.watch(paths: directory.map(Self.watchPaths(for:)) ?? [])
        reload()
    }

    /// Reloads everything; a newer call cancels an in-flight one.
    func reload() {
        reloadTask?.cancel()
        if !isLoading { isLoading = true }
        let directory = projectDirectory
        reloadTask = Task { [weak self, sessionReader, projectRepository] in
            let loaded = await Self.load(
                projectDirectory: directory,
                sessionReader: UncheckedSendable(sessionReader),
                projectRepository: UncheckedSendable(projectRepository)
            )
            guard !Task.isCancelled, let self else { return }
            if self.sessions != loaded.sessions { self.sessions = loaded.sessions }
            if self.projects != loaded.projects { self.projects = loaded.projects }
            if self.projectDirectory == directory, self.projectSessions != loaded.projectSessions {
                self.projectSessions = loaded.projectSessions
            }
            if self.isLoading { self.isLoading = false }
        }
    }

    /// Polled: reloads when the project's newest session file is not listed
    /// yet. The folder watcher only sees a file being created, and Claude
    /// Code can create it before the first prompt (no title yet), so the
    /// session would otherwise stay missing until the next tab switch.
    /// Reloads at most once per (file, mtime): a session that never gets a
    /// prompt (only `/clear`) does not trigger a reload every tick.
    func reloadIfNewestSessionMissing() async {
        guard let directory = projectDirectory, !isLoading else { return }
        guard let newest = await Self.newestSession(in: directory),
              projectDirectory == directory,
              newest != lastCheckedNewest
        else { return }
        lastCheckedNewest = newest
        if !projectSessions.contains(where: { $0.id == newest.id }) {
            reload()
        }
    }

    nonisolated struct NewestSession: Equatable, Sendable {
        let id: String
        let modified: Date
    }

    @concurrent nonisolated
    private static func newestSession(in directory: String) async -> NewestSession? {
        guard let url = SessionFileLocator.latestSessionFile(for: directory),
              let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return nil }
        return NewestSession(id: url.deletingPathExtension().lastPathComponent, modified: modified)
    }

    /// Awaitable variant for callers that need the result (onboarding).
    func reloadAndWait() async {
        reload()
        await reloadTask?.value
    }

    @concurrent nonisolated
    private static func load(
        projectDirectory: String?,
        sessionReader: UncheckedSendable<ClaudeSessionReading>,
        projectRepository: UncheckedSendable<ClaudeProjectRepositoryProtocol>
    ) async -> (sessions: [ClaudeSession], projectSessions: [ClaudeSession], projects: [ClaudeProject]) {
        let reader = sessionReader.value
        async let all = reader.loadSessions(limit: limit)
        async let scoped = projectDirectory.map { reader.loadSessions(projectDirectory: $0, limit: limit) } ?? []
        async let projects = (try? projectRepository.value.loadProjects()) ?? []
        return await (all, scoped, projects)
    }

    /// The folder Claude Code writes this project's sessions to; a new
    /// session file changes the folder and triggers a reload.
    nonisolated private static func watchPaths(for directory: String) -> [String] {
        let folder = SessionFileLocator.defaultProjectsDirectory
            .appending(path: SessionFileLocator.encodedFolderName(for: directory)).path
        return FileManager.default.fileExists(atPath: folder) ? [folder] : []
    }
}
