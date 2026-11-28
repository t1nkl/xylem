//
//  TabActivityViewModel.swift
//  Xylem
//
//  Scans every tab's latest session jsonl file on a slow poll and flips
//  `tab.isBusy` when the mtime advances. The busy flag lives on the tab
//  itself (per-instance @Observable property) so only the card whose flag
//  changed has to re-render - a central busy-by-id dict would invalidate
//  the whole sidebar every tick.
//
//  Tabs bound to a Claude session read their own transcript; unbound tabs
//  (bare shell, claude started by hand) fall back to the folder's newest.
//  For tabs whose claude reports hook events, `refreshClaudeStates` (a
//  separate 1 s loop that also runs while the window is hidden - that is
//  when "Claude is waiting for you" matters) sets `claudeState`, `isBusy`,
//  the attention mark and the session binding; the transcript mtime is
//  then only used for the prompt preview.
//
//  The same tick keeps `tab.gitBranch` current, not a view (a `.task` in the
//  card would re-run whenever SwiftUI recreates it). It stats the repo's HEAD
//  file each tick and spawns `git` only when the live cwd or HEAD's mtime
//  changed (checkout, branch switch), all off main.
//

import Foundation
import Observation

@Observable
@MainActor
final class TabActivityViewModel {
    private struct Snapshot {
        var mtime: Date
        var lastChange: Date
    }

    private nonisolated struct Query: Sendable {
        let id: UUID
        /// The tab's own transcript when bound (may not exist yet).
        let transcript: URL?
        /// Unbound tabs: the folder whose newest session is used.
        let directory: String?
        /// The session the tab is bound to, also after claude exited: the
        /// only source of its name.
        let own: URL?
        let previousMtime: Date?
    }

    private nonisolated struct Scan: Sendable {
        let id: UUID
        let mtime: Date
        /// Read only when the file changed (`advanced`).
        let prompt: String?
        /// The name of the tab's own session, read with the prompt.
        let title: String?
        let advanced: Bool
    }

    /// What the last branch lookup for a tab was based on. A lookup is
    /// repeated only when this changes.
    private nonisolated struct BranchKey: Equatable, Sendable {
        let cwd: String
        let headPath: String?
        let headMtime: Date?
    }

    private nonisolated struct BranchQuery: Sendable {
        let id: UUID
        let cwd: String
        let previous: BranchKey?
    }

    private nonisolated struct BranchScan: Sendable {
        let id: UUID
        let key: BranchKey
        let branch: String?
    }

    private var snapshots: [UUID: Snapshot] = [:]
    @ObservationIgnored private var branchKeys: [UUID: BranchKey] = [:]
    /// A 2 s tick that lands while the previous scan is still running is
    /// skipped instead of stacking a second scan behind it.
    @ObservationIgnored private var isScanning = false

    /// Tabs are considered busy for this long after their jsonl file last
    /// advanced. Larger than the usual Claude think time so the indicator
    /// doesn't flicker between lines of output.
    private let busyWindow: TimeInterval = 3.0

    /// Walks every tab's latest jsonl file on disk, then flips the busy
    /// flag on the tab directly. The filesystem scan runs in a `@concurrent`
    /// function off the main actor; only the per-tab assignments touch it.
    func refresh(for tabs: [TerminalTab]) async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let queries = tabs.compactMap { tab -> Query? in
            guard let dir = tab.workingDirectory else { return nil }
            let transcript = tab.transcriptURL
            return Query(
                id: tab.id,
                transcript: transcript,
                directory: transcript == nil ? dir : nil,
                own: tab.ownTranscriptURL,
                previousMtime: snapshots[tab.id]?.mtime
            )
        }

        let branchQueries = tabs.compactMap { tab -> BranchQuery? in
            guard let cwd = tab.liveCwd, !cwd.isEmpty else { return nil }
            return BranchQuery(id: tab.id, cwd: cwd, previous: branchKeys[tab.id])
        }

        async let branchScans = Self.scanBranches(branchQueries)
        let scans = await Self.scan(queries)
        let branches = await branchScans

        let now = Date()
        let activeIDs = Set(tabs.map(\.id))
        var updates: [UUID: (busy: Bool, advanced: Bool, prompt: String?, title: String?)] = [:]

        for scan in scans {
            var snap = snapshots[scan.id] ?? Snapshot(mtime: .distantPast, lastChange: .distantPast)
            if scan.mtime > snap.mtime {
                snap.mtime = scan.mtime
                snap.lastChange = now
            }
            snapshots[scan.id] = snap
            let busy = now.timeIntervalSince(snap.lastChange) < busyWindow
            updates[scan.id] = (busy, scan.advanced, scan.prompt, scan.title)
        }

        // Drop tabs that no longer exist so the snapshot map doesn't grow.
        snapshots = snapshots.filter { activeIDs.contains($0.key) }
        branchKeys = branchKeys.filter { activeIDs.contains($0.key) }

        // Only touch tabs whose state actually changed - leaves SwiftUI
        // change tracking untouched for everyone else and avoids wholesale
        // sidebar rebuilds every tick.
        for tab in tabs {
            let update = updates[tab.id]
            // Hook state, when there is one, owns the busy flag.
            if tab.claudeState == nil || tab.claudeState == .notRunning {
                let shouldBeBusy = update?.busy ?? false
                if tab.isBusy != shouldBeBusy { tab.isBusy = shouldBeBusy }
            }
            if let update, update.advanced {
                if tab.lastPrompt != update.prompt { tab.lastPrompt = update.prompt }
                if tab.sessionTitle != update.title { tab.sessionTitle = update.title }
            } else if update == nil, tab.sessionTitle != nil {
                // No transcript at all (a new session before its first
                // message): a name from before isn't this one's.
                tab.sessionTitle = nil
            }
        }

        applyBranches(branches, to: tabs)
    }

    private func applyBranches(_ scans: [BranchScan], to tabs: [TerminalTab]) {
        let byID = Dictionary(uniqueKeysWithValues: scans.map { ($0.id, $0) })
        for tab in tabs {
            guard let cwd = tab.liveCwd, !cwd.isEmpty else {
                branchKeys[tab.id] = nil
                if tab.gitBranch != nil { tab.gitBranch = nil }
                continue
            }
            // No scan = key unchanged since the last lookup; nothing to do.
            guard let scan = byID[tab.id] else { continue }
            // The shell may have `cd`'d while git ran; drop the stale answer
            // and leave the key unset so the next tick looks again.
            guard scan.key.cwd == cwd else { continue }
            branchKeys[tab.id] = scan.key
            if tab.gitBranch != scan.branch { tab.gitBranch = scan.branch }
        }
    }

    /// Stats each tab's HEAD (a handful of `stat`s while walking up to the
    /// repo root) and runs `git rev-parse` only for tabs whose key changed.
    /// Unchanged tabs produce no scan at all.
    @concurrent nonisolated
    private static func scanBranches(_ queries: [BranchQuery]) async -> [BranchScan] {
        var results: [BranchScan] = []
        for query in queries {
            let key = branchKey(for: query)
            guard key != query.previous else { continue }
            let branch: String?
            if key.headPath != nil {
                branch = await GitRepository().currentBranch(in: query.cwd)
            } else {
                branch = nil
            }
            results.append(BranchScan(id: query.id, key: key, branch: branch))
        }
        return results
    }

    /// Reuses the HEAD path found last tick while the cwd is unchanged and
    /// the file still exists; otherwise walks up from the cwd again.
    private nonisolated static func branchKey(for query: BranchQuery) -> BranchKey {
        if let previous = query.previous, previous.cwd == query.cwd,
           let headPath = previous.headPath,
           let mtime = GitHeadLocator.modificationDate(ofFile: headPath) {
            return BranchKey(cwd: query.cwd, headPath: headPath, headMtime: mtime)
        }
        let headPath = GitHeadLocator.headPath(forDirectory: query.cwd)
        let mtime = headPath.flatMap(GitHeadLocator.modificationDate(ofFile:))
        return BranchKey(cwd: query.cwd, headPath: headPath, headMtime: mtime)
    }

    /// Re-reads the latest user prompt and the session's name only for tabs
    /// whose mtime advanced -
    /// untouched jsonl files cost one directory listing and one stat, and
    /// LastPromptReader itself parses only appended lines.
    @concurrent nonisolated
    private static func scan(_ queries: [Query]) async -> [Scan] {
        queries.compactMap { query in
            guard let url = query.transcript ?? query.directory.flatMap({ SessionFileLocator.latestSessionFile(for: $0) })
                    ?? query.own,
                  let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
            else { return nil }
            let advanced = query.previousMtime.map { $0 != mtime } ?? true
            guard advanced else { return Scan(id: query.id, mtime: mtime, prompt: nil, title: nil, advanced: false) }
            let preview = LastPromptReader.preview(from: url)
            // The name only from the tab's own session: the folder's newest
            // (claude exited, a shell without one) may be another tab's.
            let title = if let own = query.own {
                own == url ? preview?.title : LastPromptReader.preview(from: own)?.title
            } else {
                nil as String?
            }
            return Scan(id: query.id, mtime: mtime, prompt: preview?.prompt, title: title, advanced: true)
        }
    }
}
