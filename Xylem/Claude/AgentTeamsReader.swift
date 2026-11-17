//
//  AgentTeamsReader.swift
//  Xylem
//
//  Reads Claude Code agent teams from `~/.claude/teams/<team>/config.json`.
//  Each config carries a `members` array (`name`, optional `agentType`, and
//  the lead's `cwd`). `nonisolated` so callers can run it off the main
//  actor; unreadable or malformed configs are skipped.
//
//  Claude Code leaves a team directory behind for every session, and the
//  sidebar re-reads them on a timer, so parsed configs are cached by
//  modification date: an unchanged team costs one stat, not a JSON decode.
//

import Foundation

nonisolated struct AgentTeam: Identifiable, Hashable, Sendable {
    nonisolated struct Member: Hashable, Sendable {
        let name: String
        let agentType: String?
    }

    var id: String { name }
    let name: String
    let createdAt: Date?
    /// Working directory of the first member that declares one (the lead).
    let leadCwd: String?
    let members: [Member]
}

nonisolated protocol AgentTeamsReading: Sendable {
    func loadTeams() -> [AgentTeam]
}

nonisolated struct AgentTeamsReader: AgentTeamsReading {
    private let teamsOverride: URL?
    var teamsDirectory: URL { teamsOverride ?? ClaudeConfigDirectory.root.appending(path: "teams") }
    private let cache = ParsedConfigCache()

    init(teamsDirectory: URL? = nil) {
        self.teamsOverride = teamsDirectory
    }

    func loadTeams() -> [AgentTeam] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: teamsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let teams = entries.compactMap { entry -> AgentTeam? in
            let configURL = entry.appending(path: "config.json")
            let modified = (try? configURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified else { return nil }
            if let hit = cache.team(at: configURL.path, modified: modified) { return hit }
            let team = Self.readTeam(at: configURL, fallbackName: entry.lastPathComponent)
            cache.store(team, at: configURL.path, modified: modified)
            return team
        }
        cache.retain(only: Set(entries.map { $0.appending(path: "config.json").path }))
        return teams.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    static func readTeam(at configURL: URL, fallbackName: String) -> AgentTeam? {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(Config.self, from: data) else { return nil }
        let members = (config.members ?? []).compactMap { member -> AgentTeam.Member? in
            guard let name = member.name, !name.isEmpty else { return nil }
            return AgentTeam.Member(name: name, agentType: member.agentType)
        }
        return AgentTeam(
            name: config.name ?? fallbackName,
            // `createdAt` is epoch milliseconds.
            createdAt: config.createdAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            leadCwd: config.members?.lazy.compactMap(\.cwd).first,
            members: members
        )
    }

    /// Parsed teams keyed by config path; an entry is valid only for the
    /// modification date it was parsed at. Malformed configs are cached as
    /// nil so they are not re-decoded every tick either.
    private nonisolated final class ParsedConfigCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (modified: Date, team: AgentTeam?)] = [:]

        /// `.some(nil)` is a cached malformed config; `nil` is a miss.
        func team(at path: String, modified: Date) -> AgentTeam?? {
            lock.lock(); defer { lock.unlock() }
            guard let entry = entries[path], entry.modified == modified else { return nil }
            return .some(entry.team)
        }

        func store(_ team: AgentTeam?, at path: String, modified: Date) {
            lock.lock(); defer { lock.unlock() }
            entries[path] = (modified, team)
        }

        /// Drops teams whose directory is gone.
        func retain(only paths: Set<String>) {
            lock.lock(); defer { lock.unlock() }
            entries = entries.filter { paths.contains($0.key) }
        }
    }

    private nonisolated struct Config: Decodable, Sendable {
        let name: String?
        let createdAt: Double?
        let members: [MemberConfig]?
    }

    private nonisolated struct MemberConfig: Decodable, Sendable {
        let name: String?
        let agentType: String?
        let cwd: String?
    }
}
