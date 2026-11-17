//
//  GitChanges.swift
//  Xylem
//
//  The changed files of a repository and the diff of one of them, for the
//  Changes drawer. Pure parsers (tested) plus the git calls that feed them.
//  Everything runs off main through `GitRepository.runGit`.
//

import Foundation
import Synchronization

nonisolated struct GitFileChange: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case modified, added, deleted, renamed, untracked, conflicted

        /// One letter, as `git status --short` shows it.
        var letter: String {
            switch self {
            case .modified: "M"
            case .added: "A"
            case .deleted: "D"
            case .renamed: "R"
            case .untracked: "U"
            case .conflicted: "!"
            }
        }
    }

    /// Relative to the repository root.
    let path: String
    /// Renames only: the path before.
    let oldPath: String?
    let kind: Kind
    var additions: Int?
    var deletions: Int?
    /// numstat said "-" (binary); nil counts otherwise just mean unknown.
    var isBinary = false

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
}

nonisolated enum GitChangesParser {
    /// `git status --porcelain=v1 -z`: `XY path\0`, renames and copies
    /// followed by the old path as its own `\0` entry.
    static func parseStatus(_ output: String) -> [GitFileChange] {
        var entries = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        var changes: [GitFileChange] = []
        while let entry = entries.popFirst() {
            guard entry.count > 3 else { continue }
            let x = entry[entry.startIndex]
            let y = entry[entry.index(after: entry.startIndex)]
            let path = String(entry.dropFirst(3))
            var oldPath: String?
            // Either column can be a rename/copy (Y with intent-to-add), and
            // then the old path follows as its own entry.
            if x == "R" || x == "C" || y == "R" || y == "C" { oldPath = entries.popFirst() }
            // An untracked folder listed whole is a nested repository: it has
            // no diff of its own.
            if path.hasSuffix("/") { continue }
            let kind: GitFileChange.Kind
            switch (x, y) {
            case ("?", "?"): kind = .untracked
            case ("U", _), (_, "U"), ("A", "A"), ("D", "D"): kind = .conflicted
            case ("R", _), ("C", _), (_, "R"), (_, "C"): kind = .renamed
            case ("A", _): kind = .added
            case ("D", _), (_, "D"): kind = .deleted
            default: kind = .modified
            }
            changes.append(GitFileChange(path: path, oldPath: oldPath, kind: kind))
        }
        return changes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// `git diff --numstat -z`: `added\tdeleted\tpath\0`, or for a rename
    /// `added\tdeleted\t\0old\0new\0`. Binary files show `-`.
    static func parseNumstat(_ output: String) -> [String: (Int?, Int?)] {
        var counts: [String: (Int?, Int?)] = [:]
        var entries = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)[...]
        while let entry = entries.popFirst() {
            let fields = entry.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            let added = Int(fields[0]), deleted = Int(fields[1])
            var path = String(fields[2])
            if path.isEmpty {   // rename: old and new follow
                _ = entries.popFirst()
                path = entries.popFirst() ?? ""
            }
            if !path.isEmpty { counts[path] = (added, deleted) }
        }
        return counts
    }
}

// MARK: - Lines

nonisolated enum TextLines {
    /// Lines split on "\n" only (form feeds, U+2028 and the like stay inside
    /// their line, as editors and git count them), a trailing "\r" dropped.
    /// `components(separatedBy:)` works on UTF-16, so "\r\n" - one Swift
    /// Character - still splits.
    static func split(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }
}

// MARK: - Diff

nonisolated struct DiffLine: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case hunk, context, added, removed, note }
    let id: Int
    let kind: Kind
    let oldNumber: Int?
    let newNumber: Int?
    let text: String
}

nonisolated struct DiffDocument: Equatable, Sendable {
    var lines: [DiffLine]
    var isBinary = false
    /// More lines than `UnifiedDiffParser.maxLines`: the rest is cut.
    var isTruncated = false
}

nonisolated enum UnifiedDiffParser {
    /// A diff past this many lines shows its start and a note; a list this
    /// long is unreadable anyway and would cost a lot of views.
    static let maxLines = 5_000
    /// Minified files are one huge line; cut it for display.
    static let maxLineLength = 2_000

    static func parse(_ text: String) -> DiffDocument {
        var lines: [DiffLine] = []
        var oldLine = 0, newLine = 0
        var inHunk = false
        var binary = false
        var truncated = false
        let rawLines = TextLines.split(text)
        for (index, line) in rawLines.enumerated() {
            if lines.count >= maxLines { truncated = true; break }
            if line.hasPrefix("@@") {
                // @@ -a,b +c,d @@ heading
                let numbers = line.split(separator: " ")
                if numbers.count >= 3 {
                    oldLine = Int(numbers[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    newLine = Int(numbers[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                inHunk = true
                lines.append(DiffLine(id: lines.count, kind: .hunk, oldNumber: nil, newNumber: nil, text: clip(line[...])))
                continue
            }
            if !inHunk {
                if line.hasPrefix("Binary files") || line.hasPrefix("GIT binary patch") { binary = true }
                continue   // diff --git / index / --- / +++ headers
            }
            if line.hasPrefix("diff --git") { inHunk = false; continue }
            switch line.first {
            case "+":
                lines.append(DiffLine(id: lines.count, kind: .added, oldNumber: nil, newNumber: newLine, text: clip(line.dropFirst())))
                newLine += 1
            case "-":
                lines.append(DiffLine(id: lines.count, kind: .removed, oldNumber: oldLine, newNumber: nil, text: clip(line.dropFirst())))
                oldLine += 1
            case "\\":
                lines.append(DiffLine(id: lines.count, kind: .note, oldNumber: nil, newNumber: nil, text: String(line.dropFirst(2))))
            case " ":
                lines.append(DiffLine(id: lines.count, kind: .context, oldNumber: oldLine, newNumber: newLine, text: clip(line.dropFirst())))
                oldLine += 1; newLine += 1
            default:
                // An empty line inside a hunk is a blank context line when
                // git runs with diff.suppressBlankEmpty; the very last one is
                // just the end of the output.
                guard line.isEmpty, index < rawLines.count - 1 else { continue }
                lines.append(DiffLine(id: lines.count, kind: .context, oldNumber: oldLine, newNumber: newLine, text: ""))
                oldLine += 1; newLine += 1
            }
        }
        return DiffDocument(lines: lines, isBinary: binary && lines.isEmpty, isTruncated: truncated)
    }

    /// A minified file is one huge line: show its start.
    static func clip(_ text: Substring) -> String {
        text.count > maxLineLength ? String(text.prefix(maxLineLength)) + "…" : String(text)
    }
}

// MARK: - Loading

nonisolated enum GitChangesLoader {
    struct Snapshot: Equatable, Sendable {
        let root: String
        var changes: [GitFileChange]
    }

    /// nil: not inside a git repository (or git failed).
    static func load(in directory: String) async -> Snapshot? {
        guard let root = await repositoryRoot(of: directory) else { return nil }
        async let status = GitRepository.runGit(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: root)
        // Against HEAD: staged and unstaged together, like the diff we show.
        // --no-ext-diff: a diff.external tool (difftastic) prints no numstat.
        async let numstat = GitRepository.runGit(["diff", "HEAD", "--no-ext-diff", "--numstat", "-z", "-M"], in: root)
        guard let statusOutput = await status else { return nil }
        var numstatOutput = await numstat
        if numstatOutput == nil {
            // No commit yet: HEAD doesn't exist; count what is staged.
            numstatOutput = await GitRepository.runGit(["diff", "--cached", "--no-ext-diff", "--numstat", "-z"], in: root)
        }
        let counts = GitChangesParser.parseNumstat(numstatOutput ?? "")
        var changes = GitChangesParser.parseStatus(statusOutput)
        // Untracked files that are gone or committed leave the count cache.
        lineCounts.retain(changes.filter { $0.kind == .untracked }.map { (root as NSString).appendingPathComponent($0.path) })
        for index in changes.indices {
            if let count = counts[changes[index].path] {
                changes[index].additions = count.0
                changes[index].deletions = count.1
                changes[index].isBinary = count.0 == nil && count.1 == nil
            } else if changes[index].kind == .untracked {
                changes[index].additions = lineCounts.count(of: (root as NSString).appendingPathComponent(changes[index].path))
                changes[index].deletions = 0
            }
        }
        return Snapshot(root: root, changes: changes)
    }

    /// `git rev-parse --show-toplevel`, remembered per folder (the 3 s
    /// refresh asked every pass; a folder's repository doesn't move).
    private static func repositoryRoot(of directory: String) async -> String? {
        if let known = roots.value(for: directory) { return known }
        guard let root = await GitRepository.runGit(["rev-parse", "--show-toplevel"], in: directory)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty
        else { return nil }
        roots.set(root, for: directory)
        return root
    }

    private static let roots = LockedCache<String, String>()
    private static let lineCounts = LineCountCache()

    /// The diff of one file against HEAD (staged + unstaged). New files
    /// (untracked, or a repository without commits) diff against nothing.
    static func diff(of change: GitFileChange, root: String) async -> DiffDocument {
        let output: String?
        if change.kind == .untracked {
            output = await GitRepository.runGit(["diff", "--no-index", "--no-color", "--no-ext-diff", "--", "/dev/null", change.path],
                                                in: root, acceptedStatuses: [0, 1])
        } else {
            var paths = [change.path]
            if let old = change.oldPath { paths.insert(old, at: 0) }
            let againstHead = await GitRepository.runGit(["diff", "HEAD", "-M", "--no-color", "--no-ext-diff", "--"] + paths, in: root)
            if let againstHead {
                output = againstHead
            } else {
                // No commit yet: what is staged.
                output = await GitRepository.runGit(["diff", "--cached", "--no-color", "--no-ext-diff", "--"] + paths, in: root)
            }
        }
        return UnifiedDiffParser.parse(output ?? "")
    }

    /// Lines of a new text file for its "+N" (files over 2 MB, or binary:
    /// nil), re-read only when the file's stat changes.
    fileprivate static func lineCount(of path: String) -> Int? {
        // Regular files only: reading a FIFO would block (see FilePreview).
        guard SafeFileRead.isRegularFile(path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int, size <= 2_000_000,
              let data = FileManager.default.contents(atPath: path),
              !data.prefix(8_000).contains(0)
        else { return nil }
        let newlines = data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        return data.last == 0x0A || data.isEmpty ? newlines : newlines + 1
    }
}

// MARK: - Changes as a folder tree

/// The changed files grouped by folder for the Changes drawer, like the
/// project's folder structure. A folder with a single sub-folder and no files
/// of its own folds into it, so `src/webhooks` is one row - as compact
/// folders in VS Code. Folders first, then files, each in Finder order.
nonisolated enum ChangeTree {
    enum Row: Identifiable, Hashable {
        /// `path`: the folder's full relative path (the collapse key);
        /// `label`: what the row shows (possibly several folders joined).
        case folder(path: String, label: String, depth: Int, fileCount: Int)
        case file(GitFileChange, depth: Int)

        var id: String {
            switch self {
            case .folder(let path, _, _, _): "d:" + path
            case .file(let change, _): "f:" + change.path
            }
        }
    }

    private final class Node {
        var folders: [String: Node] = [:]
        var files: [GitFileChange] = []
        var count: Int { files.count + folders.values.reduce(0) { $0 + $1.count } }
    }

    static func rows(_ changes: [GitFileChange], collapsed: Set<String>) -> [Row] {
        let root = Node()
        for change in changes {
            var node = root
            for component in change.folder.split(separator: "/").map(String.init) where !component.isEmpty {
                if let next = node.folders[component] { node = next } else {
                    let next = Node(); node.folders[component] = next; node = next
                }
            }
            node.files.append(change)
        }
        var rows: [Row] = []
        func emit(_ node: Node, prefix: String, depth: Int) {
            for name in node.folders.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                var child = node.folders[name]!
                var label = name
                var path = prefix.isEmpty ? name : prefix + "/" + name
                // Fold single-folder chains: a/b/c with nothing else in a, b.
                while child.files.isEmpty, child.folders.count == 1, let (next, grand) = child.folders.first {
                    label += "/" + next
                    path += "/" + next
                    child = grand
                }
                rows.append(.folder(path: path, label: label, depth: depth, fileCount: child.count))
                if !collapsed.contains(path) { emit(child, prefix: path, depth: depth + 1) }
            }
            for file in node.files.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                rows.append(.file(file, depth: depth))
            }
        }
        emit(root, prefix: "", depth: 0)
        return rows
    }
}

// MARK: - Small caches

/// A dictionary behind a Mutex, for the static caches the off-main loaders
/// share (the project's other shared state uses `Mutex` too).
nonisolated final class LockedCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private let storage = Mutex<[Key: Value]>([:])
    func value(for key: Key) -> Value? { storage.withLock { $0[key] } }
    func set(_ value: Value, for key: Key) { storage.withLock { $0[key] = value } }
    /// Drops every key not in `keys`.
    func retain(_ keys: Set<Key>) { storage.withLock { $0 = $0.filter { keys.contains($0.key) } } }
}

/// Untracked files' line counts by path, kept while their stat is the same
/// (the refresh re-read every new file, up to 2 MB each, every 3 s) and only
/// for files still untracked, so it can't grow without bound.
nonisolated final class LineCountCache: Sendable {
    private let cache = LockedCache<String, CachedCount>()

    struct CachedCount: Sendable { let stamp: FileStamp; let count: Int? }

    func count(of path: String) -> Int? {
        let stamp = FileStamp(url: URL(fileURLWithPath: path))
        if let stamp, let known = cache.value(for: path), known.stamp == stamp { return known.count }
        let count = GitChangesLoader.lineCount(of: path)
        if let stamp { cache.set(CachedCount(stamp: stamp, count: count), for: path) }
        return count
    }

    func retain(_ paths: [String]) { cache.retain(Set(paths)) }
}
