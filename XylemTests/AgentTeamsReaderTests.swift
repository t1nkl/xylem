//
//  AgentTeamsReaderTests.swift
//  XylemTests
//
//  The reader is polled every few seconds, so it caches parsed configs by
//  modification date. These tests make sure that cache never hides an
//  edited, added or removed team.
//

import Testing
import Foundation

struct AgentTeamsReaderTests {

    private func makeTeamsDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "xylem-teams-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeTeam(
        _ name: String,
        members: [String],
        in root: URL,
        modified: Date
    ) throws {
        let dir = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let memberJSON = members
            .map { #"{"name":"\#($0)","agentType":"general-purpose","cwd":"/tmp/project"}"# }
            .joined(separator: ",")
        let json = #"{"name":"\#(name)","createdAt":1763000000000,"members":[\#(memberJSON)]}"#
        let config = dir.appending(path: "config.json")
        try Data(json.utf8).write(to: config)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: config.path)
    }

    @Test func parsesMembersLeadCwdAndEpochMillis() throws {
        let root = try makeTeamsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTeam("alpha", members: ["lead", "worker"], in: root, modified: Date(timeIntervalSince1970: 1_000))

        let team = try #require(AgentTeamsReader(teamsDirectory: root).loadTeams().first)
        #expect(team.name == "alpha")
        #expect(team.members.map(\.name) == ["lead", "worker"])
        #expect(team.leadCwd == "/tmp/project")
        #expect(team.createdAt == Date(timeIntervalSince1970: 1_763_000_000))
    }

    @Test func cachedTeamsFollowEditsAdditionsAndRemovals() throws {
        let root = try makeTeamsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = AgentTeamsReader(teamsDirectory: root)

        try writeTeam("alpha", members: ["lead"], in: root, modified: Date(timeIntervalSince1970: 1_000))
        #expect(reader.loadTeams().first?.members.count == 1)

        // Edited config (new mtime) must be re-parsed, not served from cache.
        try writeTeam("alpha", members: ["lead", "worker"], in: root, modified: Date(timeIntervalSince1970: 2_000))
        #expect(reader.loadTeams().first?.members.count == 2)

        try writeTeam("beta", members: ["lead"], in: root, modified: Date(timeIntervalSince1970: 3_000))
        #expect(Set(reader.loadTeams().map(\.name)) == ["alpha", "beta"])

        try FileManager.default.removeItem(at: root.appending(path: "alpha"))
        #expect(reader.loadTeams().map(\.name) == ["beta"])
    }

    @Test func malformedConfigIsSkipped() throws {
        let root = try makeTeamsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appending(path: "broken", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: dir.appending(path: "config.json"))

        let reader = AgentTeamsReader(teamsDirectory: root)
        #expect(reader.loadTeams().isEmpty)
        #expect(reader.loadTeams().isEmpty)   // cached miss stays a miss
    }
}
