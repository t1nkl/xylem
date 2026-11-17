//
//  AgentTeamsStore.swift
//  Xylem
//
//  Observable holder for the AGENT TEAMS section. Reads
//  `~/.claude/teams/*/config.json` off the main actor via AgentTeamsReader
//  and keeps only the teams worth showing (see `isVisible`).
//

import Foundation
import Observation

@Observable
final class AgentTeamsStore {
    private(set) var teams: [AgentTeam] = []

    @ObservationIgnored private let reader: AgentTeamsReading
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    init(reader: AgentTeamsReading = AgentTeamsReader()) {
        self.reader = reader
    }

    /// Directory of the last `reload`; nil means "every project's teams".
    @ObservationIgnored private var lastDirectory: String?

    /// Re-reads with the directory of the previous `reload` (periodic poll).
    func reloadLast() {
        reload(projectDirectory: lastDirectory)
    }

    func reload(projectDirectory: String?) {
        lastDirectory = projectDirectory
        reloadTask?.cancel()
        let reader = reader
        reloadTask = Task { [weak self] in
            let all = await Self.load(reader)
            guard !Task.isCancelled, let self else { return }
            let visible = all.filter { Self.isVisible($0, projectDirectory: projectDirectory) }
            if self.teams != visible { self.teams = visible }
        }
    }

    /// Directory listing + config parsing; `@concurrent` so it never runs on
    /// the main actor.
    @concurrent nonisolated
    private static func load(_ reader: AgentTeamsReading) async -> [AgentTeam] {
        reader.loadTeams()
    }

    /// Claude Code leaves a lone-lead `session-*` team behind for every
    /// session, so only teams with at least one teammate besides the lead
    /// count. With a project open, teams are scoped to it by the lead's cwd.
    nonisolated static func isVisible(_ team: AgentTeam, projectDirectory: String?) -> Bool {
        guard team.members.count > 1 else { return false }
        guard let projectDirectory, let cwd = team.leadCwd else { return true }
        return cwd == projectDirectory || cwd.hasPrefix(projectDirectory + "/")
    }
}
