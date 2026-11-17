//
//  TemporaryProjectFilter.swift
//  Xylem
//
//  Tools that run `claude -p` in a fresh temporary folder (summarizers,
//  scripts, test harnesses) leave one project folder per run in
//  ~/.claude/projects. Seen on a real machine: hundreds of
//  `/private/var/folders/…/T/…/cwd/<random>` "projects" that buried the
//  real ones in Directories, Recent Projects and Sessions. Those lists skip
//  them; Usage still counts them (the spend is real).
//

import Foundation

nonisolated enum TemporaryProjectFilter {
    /// macOS per-user temp (`NSTemporaryDirectory()` lives here) and /tmp.
    static let temporaryRoots = ["/private/var/folders/", "/var/folders/", "/private/tmp/", "/tmp/"]

    /// Cheap check on the encoded folder name, before the path is resolved
    /// (resolving reads a transcript). Only the per-user temp roots: their
    /// encoded prefix can't plausibly be a real project; `-tmp-` could be
    /// `/tmp-foo`, so /tmp is left to `isTemporary(path:)`.
    static func isTemporary(folderName: String) -> Bool {
        folderName.hasPrefix("-private-var-folders-") || folderName.hasPrefix("-var-folders-")
    }

    static func isTemporary(path: String) -> Bool {
        temporaryRoots.contains { path.hasPrefix($0) }
    }
}
