//
//  ClaudeProjectRepository.swift
//  Xylem
//
//  Filesystem-level repository for Claude Code projects.
//  This is the only place that knows about ~/.claude/projects/ layout -
//  views depend on the protocol, not the concrete type.
//

import Foundation

nonisolated protocol ClaudeProjectRepositoryProtocol {
    func loadProjects() throws -> [ClaudeProject]
}

nonisolated struct ClaudeProjectRepository: ClaudeProjectRepositoryProtocol {
    /// Injected in tests; otherwise the Claude config folder's, read per
    /// use so a changed CLAUDE_CONFIG_DIR applies without a relaunch.
    private let projectsOverride: URL?
    var projectsDirectory: URL { projectsOverride ?? SessionFileLocator.defaultProjectsDirectory }

    init(projectsDirectory: URL? = nil) {
        self.projectsOverride = projectsDirectory
    }

    func loadProjects() throws -> [ClaudeProject] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: projectsDirectory.path) else { return [] }

        let entries = try fm.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        return entries.compactMap { makeProject(from: $0) }
            .sorted { $0.lastModified > $1.lastModified }
    }

    private func makeProject(from url: URL) -> ClaudeProject? {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
              values.isDirectory == true
        else { return nil }

        let folderName = url.lastPathComponent
        guard !TemporaryProjectFilter.isTemporary(folderName: folderName) else { return nil }
        let decodedPath = ClaudeProjectPathResolver.resolve(folder: url)
        guard !TemporaryProjectFilter.isTemporary(path: decodedPath) else { return nil }
        let displayName = (decodedPath as NSString).lastPathComponent
        let sessionCount = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?
            .filter { $0.hasSuffix(".jsonl") }
            .count ?? 0

        return ClaudeProject(
            id: folderName,
            path: decodedPath,
            displayName: displayName.isEmpty ? folderName : displayName,
            sessionCount: sessionCount,
            lastModified: values.contentModificationDate ?? .distantPast
        )
    }
}
