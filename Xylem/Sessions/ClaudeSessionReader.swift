//
//  ClaudeSessionReader.swift
//  Xylem
//
//  Reads Claude Code's jsonl session files and produces ClaudeSession
//  records, newest first, either across every project or for one project
//  directory (and its subdirectories).
//
//  The project listing touches only the folders that can belong to that
//  directory, and filters before applying the limit, so an old project
//  still shows its own sessions. Titles (the first human prompt) never
//  change once written, so they are cached per file: a reload re-stats
//  files but does not re-stream them.
//

import Foundation

nonisolated protocol ClaudeSessionReading {
    /// Newest sessions across all projects.
    func loadSessions(limit: Int) -> [ClaudeSession]
    /// Newest sessions whose cwd is `projectDirectory` or below it.
    func loadSessions(projectDirectory: String, limit: Int) -> [ClaudeSession]
}

nonisolated struct ClaudeSessionReader: ClaudeSessionReading {
    /// Injected in tests; otherwise the Claude config folder's, read per
    /// use so a changed CLAUDE_CONFIG_DIR applies without a relaunch.
    private let projectsOverride: URL?
    var projectsDirectory: URL { projectsOverride ?? SessionFileLocator.defaultProjectsDirectory }

    init(projectsDirectory: URL? = nil) {
        self.projectsOverride = projectsDirectory
    }

    /// Newest sessions across projects, without throwaway temp-folder runs
    /// (`TemporaryProjectFilter`). A tab opened in such a folder still sees
    /// its own sessions through `loadSessions(projectDirectory:)`.
    func loadSessions(limit: Int = 50) -> [ClaudeSession] {
        let folders = projectFolders().filter {
            !TemporaryProjectFilter.isTemporary(folderName: $0.lastPathComponent)
                && !TemporaryProjectFilter.isTemporary(path: ClaudeProjectPathResolver.resolve(folder: $0))
        }
        return sessions(from: folders, limit: limit)
    }

    func loadSessions(projectDirectory: String, limit: Int = 50) -> [ClaudeSession] {
        // Encoding is lossy (every non-alphanumeric → "-"), so a name prefix
        // only nominates folders; the resolved real path decides.
        let encoded = SessionFileLocator.encodedFolderName(for: projectDirectory)
        let folders = projectFolders().filter {
            let name = $0.lastPathComponent
            guard name == encoded || name.hasPrefix(encoded + "-") else { return false }
            let path = ClaudeProjectPathResolver.resolve(folder: $0)
            return path == projectDirectory || path.hasPrefix(projectDirectory + "/")
        }
        return sessions(from: folders, limit: limit)
    }

    // MARK: - Private

    private struct Candidate {
        let fileURL: URL
        let folder: URL
        let modified: Date
    }

    private func projectFolders() -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private func sessions(from folders: [URL], limit: Int) -> [ClaudeSession] {
        var candidates: [Candidate] = []
        for folder in folders {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                candidates.append(Candidate(fileURL: file, folder: folder, modified: modified))
            }
        }
        candidates.sort { $0.modified > $1.modified }

        var sessions: [ClaudeSession] = []
        sessions.reserveCapacity(min(limit, candidates.count))
        for candidate in candidates {
            guard sessions.count < limit else { break }
            guard let prompt = Self.firstPrompt(of: candidate.fileURL) else { continue }
            sessions.append(ClaudeSession(
                id: candidate.fileURL.deletingPathExtension().lastPathComponent,
                projectID: candidate.folder.lastPathComponent,
                projectPath: ClaudeProjectPathResolver.resolve(folder: candidate.folder),
                title: Self.truncate(prompt),
                lastModified: candidate.modified,
                fileURL: candidate.fileURL,
                firstPrompt: prompt
            ))
        }
        return sessions
    }

    // MARK: - Titles

    private static let titles = TitleCache()

    /// Longest first prompt kept for the tooltip: a pasted log can be
    /// megabytes, and a tooltip that size is unreadable anyway.
    static let promptCap = 2000

    /// First human prompt, capped at `promptCap`. Cached once found; a file
    /// with no prompt yet (just created) is re-checked on the next reload.
    private static func firstPrompt(of url: URL) -> String? {
        if let cached = titles[url.path] { return cached }
        var found: String?
        JSONLReader.forEachJSONObject(in: url, maxBytes: 2 * 1024 * 1024) { object in
            guard let prompt = UserPromptExtractor.prompt(from: object) else { return true }
            found = truncate(prompt.trimmingCharacters(in: .whitespacesAndNewlines), maxLength: promptCap)
            return false
        }
        if let found { titles[url.path] = found }
        return found
    }

    private static func truncate(_ text: String, maxLength: Int = 60) -> String {
        text.count <= maxLength ? text : String(text.prefix(maxLength)) + "…"
    }

    private final class TitleCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: String] = [:]

        subscript(path: String) -> String? {
            get { lock.lock(); defer { lock.unlock() }; return storage[path] }
            set { lock.lock(); storage[path] = newValue; lock.unlock() }
        }
    }
}
