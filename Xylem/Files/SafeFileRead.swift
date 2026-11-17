//
//  SafeFileRead.swift
//  Xylem
//
//  Reads of files that a project folder controls (its `.claude/` settings,
//  `.mcp.json`, agents, a `.git` file, the user's shell startup file). A
//  cloned repository can hold a symlink to `/dev/zero` or a FIFO under such
//  a name: reading the first never ends, opening the second blocks until
//  something writes to it - a thread lost for good. macOS 26's Foundation
//  happens to refuse both; nothing promises that elsewhere (macOS 15
//  already differed on paths), so these reads take regular files only
//  (a symlink counts as its target) and cap the size.
//

import Foundation

nonisolated enum SafeFileRead {
    /// Far above any settings or config file (`~/.claude.json` is the
    /// biggest, a few MB).
    static let defaultLimit = 64 << 20

    /// `stat` follows symlinks, so a link to a regular file passes.
    static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }

    /// The whole file, or nil when it isn't a regular file, is over
    /// `limit` bytes, or can't be read.
    static func data(_ url: URL, limit: Int = defaultLimit) -> Data? {
        var info = stat()
        guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= limit
        else { return nil }
        return try? Data(contentsOf: url)
    }

    static func string(_ url: URL, limit: Int = defaultLimit) -> String? {
        data(url, limit: limit).map { String(decoding: $0, as: UTF8.self) }
    }

    /// A handle for streaming reads (transcripts, agent frontmatter):
    /// regular files only.
    static func handle(_ url: URL) -> FileHandle? {
        guard isRegularFile(url.path) else { return nil }
        return try? FileHandle(forReadingFrom: url)
    }
}
