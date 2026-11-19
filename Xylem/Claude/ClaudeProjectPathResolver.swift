//
//  ClaudeProjectPathResolver.swift
//  Xylem
//
//  Claude Code names each project folder by replacing every character of
//  the cwd outside `[A-Za-z0-9]` with `-` (so `/`, `.`, `_`, spaces and
//  non-ASCII letters all collapse to dashes). The encoding is badly lossy:
//  `demo_site`, `demo-site` and `demo.site` share a
//  folder name. Luckily the jsonl files keep the real path in a `cwd` field
//  on nearly every entry, so we recover the correct path from the first
//  session file in the folder.
//
//  Resolutions are cached by folder path; session files rarely change their
//  cwd, and reading them is the slow part.
//

import Foundation

nonisolated enum ClaudeProjectPathResolver {
    /// Thread-safe cache so readers that scan the projects directory
    /// repeatedly don't re-open the same jsonl each time.
    private static let cache = PathCache()

    /// Given a folder url inside `~/.claude/projects/`, returns the real
    /// filesystem path represented by that folder.
    static func resolve(folder url: URL) -> String {
        let key = url.standardizedFileURL.path
        if let cached = cache.read(for: key) {
            return cached
        }
        let name = url.lastPathComponent
        let resolved = cwdFromSessions(in: url) ?? decodeOnDisk(name) ?? naiveDecode(name)
        cache.write(resolved, for: key)
        return resolved
    }

    /// Resolve by raw encoded folder name, using a parent directory lookup.
    static func resolve(encoded folderName: String, projectsDirectory: URL) -> String {
        let folder = projectsDirectory.appending(path: folderName, directoryHint: .isDirectory)
        return resolve(folder: folder)
    }

    /// Clear the in-memory cache. Intended for tests and manual refresh
    /// actions where session files may have been rewritten.
    static func clearCache() { cache.clear() }

    // MARK: - Private

    private static func cwdFromSessions(in folder: URL) -> String? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        let sortedFiles = files
            .filter { $0.pathExtension == "jsonl" }
            .sorted { a, b in
                let ad = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let bd = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return ad > bd
            }

        for file in sortedFiles {
            if let cwd = firstCwd(in: file) { return cwd }
        }
        return nil
    }

    /// Streams just enough bytes to find a `cwd` entry. Most jsonls put it
    /// in the first few kilobytes, so we cap the scan rather than reading
    /// potentially hundreds of megabytes.
    private static func firstCwd(in url: URL) -> String? {
        var result: String?
        JSONLReader.forEachJSONObject(in: url, maxBytes: 256 * 1024) { object in
            if let cwd = object["cwd"] as? String, !cwd.isEmpty {
                result = cwd
                return false
            }
            return true
        }
        return result
    }

    /// The path whose encoding is `folderName`, found by walking the disk:
    /// at each directory, a child whose own encoding matches the next part
    /// of the name (followed by `-`, the encoded `/`, or the end) is the
    /// next component. Used when the folder has no transcript to read a
    /// `cwd` from - Claude Code leaves such empty project folders behind,
    /// and the dash-for-slash guess turns `~/Code/acme/billing-api`
    /// into `.../billing/api`.
    ///
    /// Any folder names work: the rule is Claude Code's own encoding, so
    /// dashes, dots, underscores, spaces and non-Latin letters all match.
    /// Matching ignores case (APFS does; a shell can `cd ~/sites`) and both
    /// Unicode normal forms (one Cyrillic "й" is one or two UTF-16 units).
    /// Longer matches are tried first and dead ends backtrack. When the
    /// folder is gone, the deepest directory that still exists plus the
    /// rest of the name with its dashes kept (dashes inside a name are far
    /// more common than in a guess of where the slashes were).
    static func decodeOnDisk(_ folderName: String, root: String = "/") -> String? {
        guard folderName.hasPrefix("-") else { return nil }
        var budget = 2_000   // directory entries looked at; a guard against huge trees
        var deepest: (directory: String, remaining: Substring)?
        let remaining = Substring(folderName.dropFirst().lowercased())
        if let found = probe(directory: root, remaining: remaining, budget: &budget, deepest: &deepest) {
            return found
        }
        guard let deepest, deepest.directory != root else { return nil }
        // The rest of the name in its original case.
        let rest = folderName.suffix(deepest.remaining.utf8.count)
        return deepest.directory + "/" + rest
    }

    private static func probe(
        directory: String,
        remaining: Substring,
        budget: inout Int,
        deepest: inout (directory: String, remaining: Substring)?
    ) -> String? {
        if remaining.isEmpty { return directory }
        if deepest == nil || remaining.utf8.count < deepest!.remaining.utf8.count {
            deepest = (directory, remaining)
        }
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
        budget -= children.count
        guard budget > 0 else { return nil }
        var matches: [(child: String, length: Int)] = []
        for child in children {
            // Not a `Set`: Swift strings compare by canonical equivalence,
            // so a Set keeps one of the two forms and drops the other.
            var lengths: [Int] = []
            for form in [child.precomposedStringWithCanonicalMapping, child.decomposedStringWithCanonicalMapping] {
                let encoded = encode(form).lowercased()
                guard !lengths.contains(encoded.utf8.count) else { continue }
                lengths.append(encoded.utf8.count)
                if remaining == encoded || remaining.hasPrefix(encoded + "-") {
                    matches.append((child, encoded.utf8.count))
                }
            }
        }
        // Longer matches first. Equal ones are names Claude Code's encoding
        // can't tell apart (two non-Latin names of the same length, "a.b"
        // next to "a_b"): the most recently modified is most likely the one
        // Claude ran in.
        let ordered = matches
            .map { (child: $0.child, length: $0.length, modified: modificationDate(directory, $0.child)) }
            .sorted { ($0.length, $0.modified) > ($1.length, $1.modified) }
        for (child, length, _) in ordered {
            let path = directory == "/" ? "/" + child : directory + "/" + child
            if remaining.utf8.count == length { return path }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if let found = probe(directory: path, remaining: remaining.dropFirst(length + 1), budget: &budget, deepest: &deepest) {
                return found
            }
        }
        return nil
    }

    private static func modificationDate(_ directory: String, _ child: String) -> Date {
        let path = directory == "/" ? "/" + child : directory + "/" + child
        return ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
    }

    /// Last resort when no session file exists and the folder isn't on
    /// disk: replace all dashes with slashes. Wrong for any directory name that contains a
    /// dash, dot, underscore, space or non-ASCII letter (all encoded as `-`), but it's the best we can do without extra data.
    static func naiveDecode(_ folderName: String) -> String {
        guard folderName.hasPrefix("-") else { return folderName }
        return "/" + folderName.dropFirst().replacingOccurrences(of: "-", with: "/")
    }

    /// Encoding used by Claude Code when it creates the project folder: the
    /// JS `path.replace(/[^a-zA-Z0-9]/g, "-")`. JS strings are UTF-16 and
    /// the regex has no `u` flag, so the replacement is per UTF-16 code
    /// unit - one dash per Cyrillic letter, two per emoji (surrogate pair).
    /// Iterating `utf16` reproduces that exactly; `Character`/`unicodeScalars`
    /// would not. Verified on disk:
    /// `/Users/x/Code/Demo/demo_site` →
    /// `-Users-x-Code-Demo-demo-site`.
    ///
    /// The single source of truth for this rule - `SessionFileLocator`
    /// delegates here.
    static func encode(_ path: String) -> String {
        let dash = UInt16(UInt8(ascii: "-"))
        let units = path.utf16.map { unit -> UInt16 in
            isASCIIAlphanumeric(unit) ? unit : dash
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func isASCIIAlphanumeric(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: true
        default: false
        }
    }

    // MARK: - Thread-safe storage

    private final class PathCache: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.xylem.path-resolver-cache", attributes: .concurrent)
        private var storage: [String: String] = [:]

        func read(for key: String) -> String? {
            queue.sync { storage[key] }
        }

        func write(_ value: String, for key: String) {
            queue.async(flags: .barrier) { self.storage[key] = value }
        }

        func clear() {
            queue.async(flags: .barrier) { self.storage.removeAll() }
        }
    }
}
