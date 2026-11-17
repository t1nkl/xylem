//
//  SessionStatsViewModel.swift
//  Xylem
//
//  Observes the active tab's own session jsonl (or, for an unbound tab, the
//  most recent jsonl of its project directory) and exposes
//  the resulting StatsSnapshot. Polls on a timer because FSEvents within a
//  SwiftUI preview context is overkill for the 1-2 Hz refresh we need.
//
//  File work runs in a `@concurrent` function (off the main actor); the
//  reader is incremental, so an unchanged file costs one directory listing
//  and one stat.
//

import Foundation
import Observation

@Observable
final class SessionStatsViewModel {
    private(set) var stats: StatsSnapshot = .init()
    private(set) var currentDirectory: String?

    private let reader: SessionStatsReading
    @ObservationIgnored private let projectsOverride: URL?
    private var projectsDirectory: URL { projectsOverride ?? SessionFileLocator.defaultProjectsDirectory }
    /// Load in flight; a tick that lands while the previous one is still
    /// reading the same session is skipped.
    @ObservationIgnored private var loadingTarget: Target?
    @ObservationIgnored private var currentTarget: Target?

    init(
        reader: SessionStatsReading = SessionStatsReader(),
        projectsDirectory: URL? = nil
    ) {
        self.reader = reader
        self.projectsOverride = projectsDirectory
    }

    /// `transcript` is the tab's own session file when the tab is bound;
    /// nil falls back to the folder's newest session (unbound tabs).
    func refresh(for directory: String?, transcript: URL? = nil) async {
        // @Observable fires observers on every write regardless of value
        // equality. Without these guards, the 4 s stats clock would tick
        // invalidation through the toolbar items (and anything else that reads
        // `stats`) even when nothing actually changed.
        if currentDirectory != directory {
            currentDirectory = directory
        }
        let target = directory.map { Target(directory: $0, transcript: transcript) }
        currentTarget = target
        guard let target else {
            let empty = StatsSnapshot()
            if stats != empty { stats = empty }
            return
        }
        guard loadingTarget != target else { return }
        loadingTarget = target
        let snapshot = await Self.load(
            target: target,
            projectsDirectory: projectsDirectory,
            reader: UncheckedSendable(reader)
        )
        if loadingTarget == target { loadingTarget = nil }
        // The active tab may have moved on while we were reading.
        guard currentTarget == target else { return }

        var result = snapshot ?? StatsSnapshot()
        result.projectPath = target.directory
        if stats != result { stats = result }
    }

    nonisolated struct Target: Equatable, Sendable {
        let directory: String
        let transcript: URL?
    }

    @concurrent nonisolated
    private static func load(
        target: Target,
        projectsDirectory: URL,
        reader: UncheckedSendable<SessionStatsReading>
    ) async -> StatsSnapshot? {
        if let transcript = target.transcript {
            // A bound tab shows its own session only - empty until the
            // first prompt creates the file, never a neighbour's.
            guard FileManager.default.fileExists(atPath: transcript.path) else { return nil }
            return reader.value.readStats(from: transcript)
        }
        guard let latest = SessionFileLocator.latestSessionFile(
            for: target.directory,
            projectsDirectory: projectsDirectory
        ) else { return nil }
        return reader.value.readStats(from: latest)
    }
}
