//
//  SkillsDirectoryTests.swift
//  XylemTests
//
//  skills.sh payload parsing plus the view model's derived lists. The
//  filtered / grouped lists are stored and rebuilt on change (not computed
//  per render), so these check they track the catalogue, the query and the
//  grouping toggle. Fakes only - no network, no ~/.xylem.
//

import Testing
import Foundation

@MainActor
struct SkillsDirectoryTests {

    // MARK: - Test doubles

    nonisolated final class FakeFetcher: SkillsDirectoryFetching {
        var result: [MarketplaceSkill] = []
        var callCount = 0
        func fetch() async throws -> [MarketplaceSkill] {
            callCount += 1
            return result
        }
    }

    final class FakeCache: SkillsDirectoryCacheStoring {
        var stored: SkillsDirectoryCacheEntry?
        var saved: [SkillsDirectoryCacheEntry] = []
        func load() -> SkillsDirectoryCacheEntry? { stored }
        func save(_ entry: SkillsDirectoryCacheEntry) throws { saved.append(entry) }
    }

    private func skill(_ source: String, _ id: String, installs: Int, name: String? = nil) -> MarketplaceSkill {
        MarketplaceSkill(source: source, skillId: id, name: name ?? id, installs: installs)
    }

    private var catalogue: [MarketplaceSkill] {
        [
            skill("anthropics/skills", "frontend-design", installs: 900, name: "Frontend Design"),
            skill("someone/tools", "pdf", installs: 800),
            skill("anthropics/skills", "docx", installs: 100),
            skill("someone/tools", "xlsx", installs: 300)
        ]
    }

    // MARK: - Parsing

    @Test func parsesInitialSkillsFromNextPushPayload() async throws {
        let html = #"""
        <script>self.__next_f.push([1,"0:{\"initialSkills\":[{\"source\":\"a/b\",\"skillId\":\"x\",\"name\":\"X [beta]\",\"installs\":5}],\"other\":1}"])</script>
        """#
        let skills = try await SkillsDirectoryFetcher.parse(Data(html.utf8))
        #expect(skills == [MarketplaceSkill(source: "a/b", skillId: "x", name: "X [beta]", installs: 5)])
    }

    @Test func missingPayloadThrows() async {
        await #expect(throws: SkillsDirectoryFetcher.FetchError.self) {
            _ = try await SkillsDirectoryFetcher.parse(Data("<html></html>".utf8))
        }
    }

    // MARK: - Pure helpers

    @Test func filterIsCaseInsensitiveAcrossNameSourceAndID() {
        let all = catalogue
        #expect(SkillsDirectoryViewModel.filter(all, query: "FRONTEND").map(\.skillId) == ["frontend-design"])
        #expect(SkillsDirectoryViewModel.filter(all, query: "someone").map(\.skillId) == ["pdf", "xlsx"])
        #expect(SkillsDirectoryViewModel.filter(all, query: "  ").count == all.count)
    }

    @Test func groupsSortByPrecomputedInstallTotals() {
        let groups = SkillsDirectoryViewModel.group(catalogue)
        #expect(groups.map(\.repo) == ["someone/tools", "anthropics/skills"])
        #expect(groups.map(\.totalInstalls) == [1100, 1000])
        #expect(groups[0].skills.map(\.skillId) == ["pdf", "xlsx"])
    }

    // MARK: - View model

    @Test func freshCacheIsShownWithoutFetching() async {
        let fetcher = FakeFetcher()
        let cache = FakeCache()
        cache.stored = SkillsDirectoryCacheEntry(skills: catalogue, updatedAt: Date())
        let vm = SkillsDirectoryViewModel(fetcher: fetcher, cache: cache)

        await vm.loadInitial()

        #expect(vm.skills == catalogue)
        #expect(vm.filteredSkills == catalogue)
        #expect(fetcher.callCount == 0)
    }

    @Test func staleCacheRefetchesAndSaves() async {
        let fetcher = FakeFetcher()
        fetcher.result = Array(catalogue.prefix(1))
        let cache = FakeCache()
        cache.stored = SkillsDirectoryCacheEntry(
            skills: catalogue,
            updatedAt: Date().addingTimeInterval(-SkillsDirectoryViewModel.cacheTTL - 60)
        )
        let vm = SkillsDirectoryViewModel(fetcher: fetcher, cache: cache)

        await vm.loadInitial()

        #expect(fetcher.callCount == 1)
        #expect(vm.skills == fetcher.result)
        #expect(cache.saved.map(\.skills) == [fetcher.result])
        #expect(!vm.isRefreshing)
    }

    @Test func derivedListsFollowQueryAndGrouping() async {
        let cache = FakeCache()
        cache.stored = SkillsDirectoryCacheEntry(skills: catalogue, updatedAt: Date())
        let vm = SkillsDirectoryViewModel(fetcher: FakeFetcher(), cache: cache)
        await vm.loadInitial()

        #expect(vm.groupedSkills.isEmpty)   // not built while grouping is off

        vm.groupByRepo = true
        #expect(vm.groupedSkills.map(\.repo) == ["someone/tools", "anthropics/skills"])

        vm.searchQuery = "docx"
        #expect(vm.filteredSkills.map(\.skillId) == ["docx"])
        #expect(vm.groupedSkills.map(\.repo) == ["anthropics/skills"])

        vm.groupByRepo = false
        #expect(vm.groupedSkills.isEmpty)
    }
}
