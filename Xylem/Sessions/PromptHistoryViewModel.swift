//
//  PromptHistoryViewModel.swift
//  Xylem
//
//  Owns the prompt index for the ⌘K palette. Built lazily: nothing is read
//  until the palette first opens, so a user who never searches prompts pays
//  nothing, and app launch (restored tabs, resumed claude sessions) never
//  competes with a 3 GB cold scan. Each palette open runs one incremental
//  update - a `stat` per transcript plus the bytes appended since the last
//  one - while the palette already searches the previous snapshot.
//
//  The first open after a relaunch publishes the saved index as soon as it
//  is decoded, before the update finishes. All reading, decoding and
//  folding happens in `@concurrent` functions; this type only assigns.
//

import Foundation
import Observation

@Observable
final class PromptHistoryViewModel {
    /// nil until the saved index (or the first build) is ready.
    private(set) var snapshot: PromptHistorySnapshot?

    @ObservationIgnored private let indexer: PromptHistoryIndexer
    /// The per-file index the snapshot was built from; kept so the next
    /// update does not decode the saved file again.
    @ObservationIgnored private var records: [String: PromptHistoryFileRecord]?
    @ObservationIgnored private var updateTask: Task<Void, Never>?

    init(indexer: PromptHistoryIndexer) {
        self.indexer = indexer
    }

    convenience init() {
        self.init(indexer: PromptHistoryIndexer())
    }

    /// Loads (first time) and incrementally updates the index; a no-op
    /// while an update is already running.
    func refresh() {
        guard updateTask == nil else { return }
        let indexer = indexer
        updateTask = Task { [weak self] in
            var current = self?.records
            if current == nil {
                let stored = await Self.loadStored(indexer)
                guard let self else { return }
                current = stored.records
                if let snapshot = stored.snapshot { self.snapshot = snapshot }
            }
            let fresh = await Self.update(indexer, records: current ?? [:])
            guard let self else { return }
            self.records = fresh.records
            if let snapshot = fresh.snapshot { self.snapshot = snapshot }
            self.updateTask = nil
        }
    }

    /// Search off the main actor; the caller drops results for a query the
    /// user has already changed.
    @concurrent nonisolated
    static func search(_ query: String, in snapshot: PromptHistorySnapshot, limit: Int = 20) async -> [PromptHistoryEntry] {
        snapshot.search(query, limit: limit)
    }

    // MARK: - Off-main work

    /// The saved index and, when it holds anything, its snapshot.
    @concurrent nonisolated
    private static func loadStored(_ indexer: PromptHistoryIndexer) async -> (records: [String: PromptHistoryFileRecord], snapshot: PromptHistorySnapshot?) {
        let records = indexer.loadStored()
        return (records, records.isEmpty ? nil : PromptHistorySnapshot(records: records.values))
    }

    /// The updated index and a new snapshot - only when the prompts changed
    /// or nothing was published yet (an empty index is still "ready"). A
    /// live session's reply moves its stamp but adds no prompt: no new
    /// snapshot, no re-run of the palette search.
    @concurrent nonisolated
    private static func update(
        _ indexer: PromptHistoryIndexer,
        records: [String: PromptHistoryFileRecord]
    ) async -> (records: [String: PromptHistoryFileRecord], snapshot: PromptHistorySnapshot?) {
        let result = indexer.update(records)
        let needsSnapshot = result.promptsChanged || records.isEmpty
        return (result.records, needsSnapshot ? PromptHistorySnapshot(records: result.records.values) : nil)
    }
}
