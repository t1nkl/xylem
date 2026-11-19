//
//  GitHeadLocator.swift
//  Xylem
//
//  Finds the `HEAD` file that decides a directory's current branch, so the
//  tab activity poll can stat it every tick and spawn `git` only when it
//  actually changed. `<cwd>/.git/HEAD` alone is wrong in two common cases:
//  the cwd is a subdirectory of the repo, and linked worktrees/submodules,
//  where `.git` is a file containing `gitdir: <path>`.
//

import Foundation

nonisolated enum GitHeadLocator {
    /// Path of the HEAD file governing `directory`, or nil when it isn't
    /// inside a git work tree. Walks up to the filesystem root.
    ///
    /// Walks path strings, not `URL`s: on macOS 15 `URL.deletingLastPathComponent()`
    /// of `file:///` is `/..`, then `/../..`, so a folder outside any
    /// repository (the home folder) never reaches a fixed point - an
    /// endless loop at 100% CPU with memory growing by gigabytes.
    /// `parent(of:)` stops at `/` on every
    /// system, and the depth cap makes any other surprise finite.
    static func headPath(forDirectory directory: String) -> String? {
        let fm = FileManager.default
        var path = URL(fileURLWithPath: directory).standardizedFileURL.path
        for _ in 0..<maxDepth {
            let dotGit = (path as NSString).appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    return (dotGit as NSString).appendingPathComponent("HEAD")
                }
                return gitdirHeadPath(fromDotGitFile: URL(fileURLWithPath: dotGit),
                                      base: URL(fileURLWithPath: path, isDirectory: true))
            }
            guard let parent = parent(of: path) else { return nil }
            path = parent
        }
        return nil
    }

    /// Far deeper than any real path (PATH_MAX allows ~512 components of
    /// one character each).
    static let maxDepth = 512

    /// The folder holding `path`, nil at the root (or for an empty path).
    static func parent(of path: String) -> String? {
        guard !path.isEmpty, path != "/" else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != path else { return nil }
        return parent
    }

    /// Modification date of `path`, nil when it can't be stat'ed.
    static func modificationDate(ofFile path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// `.git` as a file: `gitdir: /abs/or/relative/path`. Relative paths
    /// resolve against the directory holding the `.git` file.
    private static func gitdirHeadPath(fromDotGitFile file: URL, base: URL) -> String? {
        guard let text = SafeFileRead.string(file, limit: 64 << 10),
              let line = text.split(whereSeparator: \.isNewline).first,
              line.hasPrefix("gitdir:")
        else { return nil }
        let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        let gitdir = raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw)
            : base.appendingPathComponent(raw)
        return gitdir.standardizedFileURL.appendingPathComponent("HEAD").path
    }
}
