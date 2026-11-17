//
//  SkillsDirectoryViewModel.swift
//  Xylem
//
//  Observable facade for the skills sheet. Handles initial cache load,
//  background refresh, search filtering, and optional grouping by repo.
//
//  Cache I/O runs in `@concurrent` helpers (the file is ~100 KB of JSON).
//  The filtered list and the repo groups are stored, not computed: they are
//  rebuilt only when the catalogue, the query or the grouping toggle
//  changes, so a sheet re-render never re-filters or re-sorts the list.
//

import Foundation
import Observation

/// One repo's skills in the "By Repo" view. `totalInstalls` is summed once
/// when the group is built so sorting groups doesn't re-sum per comparison.
nonisolated struct SkillGroup: Identifiable, Equatable {
    var id: String { repo }
    let repo: String
    let skills: [MarketplaceSkill]
    let totalInstalls: Int
}

@Observable
final class SkillsDirectoryViewModel {
    private(set) var skills: [MarketplaceSkill] = [] {
        didSet { recomputeDerived() }
    }
    private(set) var isRefreshing = false
    private(set) var lastUpdated: Date?
    private(set) var lastError: String?

    var searchQuery: String = "" {
        didSet { if searchQuery != oldValue { recomputeDerived() } }
    }
    var groupByRepo: Bool = false {
        didSet { if groupByRepo != oldValue { recomputeDerived() } }
    }

    /// `skills` narrowed by `searchQuery`, in catalogue (popularity) order.
    private(set) var filteredSkills: [MarketplaceSkill] = []
    /// `filteredSkills` grouped by repo; only built while `groupByRepo` is on.
    private(set) var groupedSkills: [SkillGroup] = []

    /// Catalogue older than this is refetched on open.
    static let cacheTTL: TimeInterval = 6 * 3600

    private let fetcher: SkillsDirectoryFetching
    private let cache: SkillsDirectoryCacheStoring

    init(
        fetcher: SkillsDirectoryFetching = SkillsDirectoryFetcher(),
        cache: SkillsDirectoryCacheStoring = SkillsDirectoryCache()
    ) {
        self.fetcher = fetcher
        self.cache = cache
    }

    /// Loads from cache if available; kicks off a refresh if the cache is
    /// missing or older than 6h.
    func loadInitial() async {
        if let entry = await Self.loadCache(UncheckedSendable(cache)) {
            apply(entry.skills, updatedAt: entry.updatedAt)
            let age = -entry.updatedAt.timeIntervalSinceNow
            if age > Self.cacheTTL {
                await refresh()
            }
        } else {
            await refresh()
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        if lastError != nil { lastError = nil }
        defer { isRefreshing = false }

        do {
            let fresh = try await fetcher.fetch()
            let now = Date()
            apply(fresh, updatedAt: now)
            await Self.saveCache(
                SkillsDirectoryCacheEntry(skills: fresh, updatedAt: now),
                to: UncheckedSendable(cache)
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func apply(_ fresh: [MarketplaceSkill], updatedAt: Date) {
        if skills != fresh { skills = fresh }
        if lastUpdated != updatedAt { lastUpdated = updatedAt }
    }

    // MARK: - Derived views

    private func recomputeDerived() {
        let filtered = Self.filter(skills, query: searchQuery)
        if filteredSkills != filtered { filteredSkills = filtered }
        let grouped = groupByRepo ? Self.group(filtered) : []
        if groupedSkills != grouped { groupedSkills = grouped }
    }

    nonisolated static func filter(_ skills: [MarketplaceSkill], query raw: String) -> [MarketplaceSkill] {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return skills }
        return skills.filter { skill in
            skill.name.range(of: query, options: .caseInsensitive) != nil ||
            skill.source.range(of: query, options: .caseInsensitive) != nil ||
            skill.skillId.range(of: query, options: .caseInsensitive) != nil
        }
    }

    /// Groups by repo, most-installed repo first (ties broken by name so the
    /// order is stable across rebuilds); skills inside a group by installs.
    nonisolated static func group(_ skills: [MarketplaceSkill]) -> [SkillGroup] {
        Dictionary(grouping: skills, by: \.source)
            .map { repo, members in
                SkillGroup(
                    repo: repo,
                    skills: members.sorted { $0.installs > $1.installs },
                    totalInstalls: members.reduce(0) { $0 + $1.installs }
                )
            }
            .sorted { lhs, rhs in
                lhs.totalInstalls != rhs.totalInstalls
                    ? lhs.totalInstalls > rhs.totalInstalls
                    : lhs.repo < rhs.repo
            }
    }

    // MARK: - Off-main cache I/O

    @concurrent nonisolated
    private static func loadCache(_ cache: UncheckedSendable<SkillsDirectoryCacheStoring>) async -> SkillsDirectoryCacheEntry? {
        cache.value.load()
    }

    @concurrent nonisolated
    private static func saveCache(
        _ entry: SkillsDirectoryCacheEntry,
        to cache: UncheckedSendable<SkillsDirectoryCacheStoring>
    ) async {
        try? cache.value.save(entry)
    }
}
