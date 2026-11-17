//
//  SessionStatsSubagents.swift
//  Xylem
//
//  What one session's subagents spent, for the All Sessions overview cards.
//  Claude Code keeps their transcripts in `<session id>/subagents/` next to
//  the session's own jsonl; the session's own stats (SessionStatsReader)
//  never see them.
//
//  Each subagent file goes through the same incremental step as the Usage
//  dashboard (`UsageAggregator.refresh`): unchanged files cost one `stat`,
//  appended ones are read from where the last read stopped, and a fork's
//  copy of its parent's messages is skipped by the same rule. Results are
//  kept in memory only (the dashboard owns the on-disk cache).
//
//  Deliberately not part of StatsSnapshot's context numbers: subagents
//  have their own context windows, so the toolbar gauge stays the main
//  conversation's.
//

import Foundation

/// Summed spend of a session's subagents.
nonisolated struct SubagentSpend: Equatable, Sendable {
    var costUSD: Double = 0
    var tokens = 0
    /// Newest mtime among the subagent transcripts; nil when there are none.
    var newestModification: Date?

    var isEmpty: Bool { tokens == 0 }
}

nonisolated struct SessionSubagentStatsReader {
    /// Shared so a view that re-creates its reader keeps the per-file
    /// progress (same pattern as SessionStatsReader's cache).
    private static let store = Store()

    /// `<session id>/subagents/` next to `transcript` (`<session id>.jsonl`).
    static func subagentsDirectory(forTranscript transcript: URL) -> URL {
        transcript.deletingPathExtension()
            .appending(path: UsageAggregator.subagentsDirectoryName, directoryHint: .isDirectory)
    }

    /// Newest mtime of the session's subagent transcripts, without reading
    /// them: one directory listing plus a `stat` per file.
    func newestModification(forTranscript transcript: URL) -> Date? {
        Self.transcripts(forTranscript: transcript)
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max()
    }

    /// Brings every subagent transcript of the session up to date and sums
    /// it. Empty when the session never spawned an agent.
    func spend(forTranscript transcript: URL) -> SubagentSpend {
        let files = Self.transcripts(forTranscript: transcript)
        guard !files.isEmpty else { return SubagentSpend() }
        let sessionID = transcript.deletingPathExtension().lastPathComponent
        var spend = SubagentSpend()
        for file in files {
            if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                spend.newestModification = max(spend.newestModification ?? modified, modified)
            }
            guard let entry = Self.store.update(file, sessionID: sessionID) else { continue }
            for bucket in entry.buckets {
                spend.costUSD += bucket.cost
                spend.tokens += bucket.totalTokens
            }
        }
        return spend
    }

    private static func transcripts(forTranscript transcript: URL) -> [URL] {
        let directory = subagentsDirectory(forTranscript: transcript)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix("agent-") && $0.hasSuffix(".jsonl") }
            .map { directory.appending(path: $0) }
    }

    /// Per-file aggregates, keyed by path. One lock for the map; reads of
    /// different files may overlap, and two readers racing on the same file
    /// both produce a correct entry (the later write wins).
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: FileUsageAggregate] = [:]

        func update(_ file: URL, sessionID: String) -> FileUsageAggregate? {
            let path = file.path
            let existing = lock.withLock { entries[path] }
            switch UsageAggregator.refresh(
                file,
                existing: existing,
                sessionID: sessionID,
                projectPath: "",
                isSubagent: true
            ) {
            case .missing:
                lock.withLock { entries[path] = nil }
                return nil
            case let .current(entry):
                return entry
            case let .read(entry):
                lock.withLock { entries[path] = entry }
                return entry
            }
        }
    }
}
