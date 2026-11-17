//
//  ProjectFiles.swift
//  Xylem
//
//  The Files drawer's data: one directory level at a time (a folder is
//  read only when it is expanded, so node_modules costs nothing until
//  opened) and a read-only preview of one file.
//

import Foundation

nonisolated struct ProjectFileEntry: Identifiable, Hashable, Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    var id: String { path }
}

nonisolated enum ProjectDirectoryReader {
    /// Not shown: git's own folder and Finder's litter. Other dotfiles
    /// (.github, .env.example, .claude) are part of a project.
    static let hiddenNames: Set<String> = [".git", ".DS_Store"]
    /// A folder with more entries shows the first ones and a note.
    static let maxEntries = 2_000

    struct Listing: Equatable, Sendable {
        var entries: [ProjectFileEntry]
        var isTruncated = false
    }

    /// Folders first, then files, each in Finder order ("file2" before
    /// "file10"). Symlinks to folders count as folders. Unreadable: empty.
    static func list(_ directory: String) -> Listing {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return Listing(entries: []) }
        var entries: [ProjectFileEntry] = []
        entries.reserveCapacity(min(names.count, maxEntries))
        for name in names where !hiddenNames.contains(name) {
            let path = (directory as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            // A package (.app, .xcodeproj) is a folder on disk; show it as one.
            entries.append(ProjectFileEntry(name: name, path: path, isDirectory: isDirectory.boolValue))
        }
        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        let truncated = entries.count > maxEntries
        return Listing(entries: truncated ? Array(entries.prefix(maxEntries)) : entries, isTruncated: truncated)
    }
}

nonisolated enum FilePreview: Equatable, Sendable {
    /// `truncated`: only the first `FilePreviewLoader.maxBytes` are shown.
    case text(lines: [String], truncated: Bool)
    case binary
    case unreadable

    nonisolated enum Loader {
        /// 1 MB: a 10 000-line source file fits.
        static let maxBytes = 1024 * 1024

        static func load(_ path: String) -> FilePreview {
            // Regular files only (a symlink counts as its target). Opening a
            // FIFO blocks until something writes to it - a home-folder tab
            // can show one - and a device like /dev/tty can block a read:
            // either would hold a thread of the shared pool forever.
            guard SafeFileRead.isRegularFile(path),
                  let handle = FileHandle(forReadingAtPath: path) else { return .unreadable }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: maxBytes + 1) else { return .unreadable }
            if data.isEmpty { return .text(lines: [""], truncated: false) }
            // A NUL byte in the first 8 KB: not text.
            if data.prefix(8_000).contains(0) { return .binary }
            let truncated = data.count > maxBytes
            let body = truncated ? data.prefix(maxBytes) : data
            // Cut mid-character at the end is fine: the lossy decode marks it.
            let text = String(data: body, encoding: .utf8) ?? String(decoding: body, as: UTF8.self)
            // "\n" only, like editors number lines; CRLF handled (TextLines).
            var lines = TextLines.split(text).map { UnifiedDiffParser.clip($0[...]) }
            if lines.last == "" && lines.count > 1 { lines.removeLast() }
            return .text(lines: lines, truncated: truncated)
        }
    }
}
