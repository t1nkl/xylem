//
//  TabsViewModelTests.swift
//  XylemTests
//
//  Tab-list mutations that don't need the file-system or SwiftTerm: open /
//  close / reorder / rename / focus / pane-direction focus. Uses a stub
//  store so @State persistence doesn't touch disk.
//

import Testing
import Foundation

@MainActor
struct TabsViewModelTests {

    // MARK: - Test double

    final class StubStore: TabsStateStoring {
        var savedStates: [PersistedTabsState] = []
        var seed: PersistedTabsState?
        func load() -> PersistedTabsState? { seed }
        func save(_ state: PersistedTabsState) { savedStates.append(state) }
    }

    // MARK: - Lifecycle

    @Test func seedsSingleHomeTabWhenNoPersistedState() {
        let store = StubStore()
        let vm = TabsViewModel(store: store)
        #expect(vm.tabs.count == 1)
        #expect(vm.activeTabID == vm.tabs.first?.id)
    }

    /// A tab that already runs a session, without spawning anything: a
    /// deferred session is never started here.
    private func makeSessionTab(_ vm: TabsViewModel, at index: Int) {
        let session = TerminalSession(title: "s", configuration: .loginShell(workingDirectory: "/srv"),
                                      startsImmediately: false)
        vm.tabs[index].state = .session(session)
    }

    @Test func newTabAddsAPickerWhenNoTabIsWaiting() {
        let vm = TabsViewModel(store: StubStore())
        for index in vm.tabs.indices { makeSessionTab(vm, at: index) }
        #expect(!vm.tabs.contains { $0.isPicker })
        let before = vm.tabs.count
        let tab = vm.openEmptyTab()
        #expect(vm.tabs.count == before + 1)
        #expect(vm.activeTabID == tab.id)
        #expect(tab.isPicker)
        #expect(!tab.hasAnyRunningSession)
    }

    /// Repeated New Tab doesn't stack empty tabs: an existing picker is
    /// reused - the active one first, else the first in the list. Tabs turn
    /// into sessions only after they are active (selecting a session tab
    /// would start a real shell).
    @Test func newTabReusesAnEmptyTabInsteadOfAddingAnother() throws {
        let vm = TabsViewModel(store: StubStore())
        let first = try #require(vm.tabs.first)
        #expect(first.isPicker)                    // hostless tests seed a picker

        let picker = vm.appendPickerTab()
        let count = vm.tabs.count
        #expect(vm.openEmptyTab().id == picker.id)
        #expect(vm.openEmptyTab().id == picker.id)
        #expect(vm.tabs.count == count)

        // The first tab becomes a session while active: New Tab goes to
        // the picker that is waiting.
        vm.select(first.id)
        makeSessionTab(vm, at: 0)
        #expect(vm.openEmptyTab().id == picker.id)
        #expect(vm.activeTabID == picker.id)
        #expect(vm.tabs.count == count)

        // Two pickers: the active one wins; when the active tab isn't a
        // picker, the first picker in the list.
        let second = vm.appendPickerTab()
        #expect(vm.openEmptyTab().id == second.id)
        makeSessionTab(vm, at: try #require(vm.tabs.firstIndex { $0.id == second.id }))
        #expect(vm.openEmptyTab().id == picker.id)
        #expect(vm.tabs.count == count + 1)
    }

    @Test func closeTabAdvancesActiveSelectionToPreviousNeighbour() {
        let store = StubStore()
        let vm = TabsViewModel(store: store)
        let first = vm.tabs[0]
        let second = vm.appendPickerTab()
        let third = vm.appendPickerTab()
        #expect(vm.activeTabID == third.id)

        vm.closeTab(third.id)
        #expect(vm.tabs.count == 2)
        // `closeTab` picks max(0, index-1) - here index was 2, so we land on 1.
        #expect(vm.activeTabID == second.id)

        vm.closeTab(first.id)
        #expect(vm.tabs.count == 1)
        #expect(vm.activeTabID == second.id)
    }

    /// SwiftUI keeps closed rows of the tab list cached, and they hold the
    /// tab: a closed tab must let go of its session (terminal and buffers),
    /// or every closed tab stayed in memory (measured: 8 opened, 7 closed,
    /// 249 MB of 276 MB kept; 136 MB now, ~1 MB left per closed tab).
    @Test func closingATabReleasesItsSession() throws {
        let vm = TabsViewModel(store: StubStore())
        _ = vm.appendPickerTab()
        makeSessionTab(vm, at: 0)
        makeSessionTab(vm, at: 1)
        let closed = vm.tabs[1]
        let session = try #require(closed.session)
        let kept = try #require(vm.tabs[0].session)
        vm.closeTab(closed.id)
        #expect(closed.session == nil)
        #expect(session.isClosed)
        // The other tab keeps its session.
        #expect(vm.tabs.count == 1)
        #expect(vm.tabs[0].session === kept)
        #expect(!kept.isClosed)
    }

    @Test func closeTabRefusesToRemoveLastTab() {
        let store = StubStore()
        let vm = TabsViewModel(store: store)
        let lone = vm.tabs[0].id
        vm.closeTab(lone)
        #expect(vm.tabs.count == 1)
    }

    @Test func closeOtherTabsKeepsOnlyTheActiveOne() {
        let store = StubStore()
        let vm = TabsViewModel(store: store)
        _ = vm.appendPickerTab()
        let keeper = vm.appendPickerTab()
        _ = vm.appendPickerTab()
        vm.select(keeper.id)
        vm.closeOtherTabs()
        #expect(vm.tabs.count == 1)
        #expect(vm.tabs[0].id == keeper.id)
        #expect(vm.activeTabID == keeper.id)
    }

    @Test func renameTabTrimsInputAndSetsCustomFlag() {
        let store = StubStore()
        let vm = TabsViewModel(store: store)
        let id = vm.tabs[0].id
        vm.renameTab(id: id, to: "  Hello  ")
        #expect(vm.tabs[0].title == "Hello")
        #expect(vm.tabs[0].hasCustomTitle)
    }

    @Test func renameTabIgnoresEmptyOrWhitespaceOnlyInput() {
        let store = StubStore()
        let vm = TabsViewModel(store: store)
        let id = vm.tabs[0].id
        let before = vm.tabs[0].title
        vm.renameTab(id: id, to: "   ")
        #expect(vm.tabs[0].title == before)
        #expect(!vm.tabs[0].hasCustomTitle)
    }

    /// Enter in the rename field without a change: the row shows
    /// `displayTitle` (it follows the cwd), so confirming exactly that must
    /// not pin the tab.
    @Test func confirmingTheShownTitleKeepsCwdTracking() {
        let store = StubStore()
        let vm = TabsViewModel(store: store)
        let tab = vm.tabs[0]
        let shown = tab.displayTitle
        vm.renameTab(id: tab.id, to: " \(shown) ")
        #expect(tab.displayTitle == shown)
        #expect(!tab.hasCustomTitle)
    }

    /// When the stored title differs from what is shown (the shell moved on),
    /// renaming to the stored title is a real choice and pins it.
    @Test func renamingToAnOlderTitlePinsIt() {
        let store = StubStore()
        let vm = TabsViewModel(store: store)
        let tab = vm.tabs[0]
        let stored = tab.title
        guard stored != tab.displayTitle else { return }   // picker tab: nothing to tell apart
        vm.renameTab(id: tab.id, to: stored)
        #expect(tab.hasCustomTitle)
        #expect(tab.displayTitle == stored)
    }

    // MARK: - Reorder

    @Test func moveTabsFollowsListOnMoveOffsets() {
        let store = StubStore()
        let vm = TabsViewModel(store: store)
        let a = vm.tabs[0]
        let b = vm.appendPickerTab()
        let c = vm.appendPickerTab()
        #expect(vm.tabs.map(\.id) == [a.id, b.id, c.id])

        // Drag 'a' below 'c': List reports destination 3 (the gap after c).
        vm.moveTabs(fromOffsets: [0], toOffset: 3)
        #expect(vm.tabs.map(\.id) == [b.id, c.id, a.id])

        // Drag 'a' (now last) to the top.
        vm.moveTabs(fromOffsets: [2], toOffset: 0)
        #expect(vm.tabs.map(\.id) == [a.id, b.id, c.id])

        // Drag 'a' into the gap between b and c.
        vm.moveTabs(fromOffsets: [0], toOffset: 2)
        #expect(vm.tabs.map(\.id) == [b.id, a.id, c.id])
    }

    /// The top tab bar's drag: one step per neighbour crossed, by id, on
    /// the live order; nothing past either end.
    @Test func moveTabStepsOneNeighbourAtATime() {
        let store = StubStore()
        let vm = TabsViewModel(store: store)
        let a = vm.tabs[0]
        let b = vm.appendPickerTab()
        let c = vm.appendPickerTab()

        #expect(vm.moveTab(a.id, by: 1))
        #expect(vm.tabs.map(\.id) == [b.id, a.id, c.id])
        #expect(vm.moveTab(a.id, by: 1))
        #expect(vm.tabs.map(\.id) == [b.id, c.id, a.id])
        #expect(!vm.moveTab(a.id, by: 1))   // already last
        #expect(vm.moveTab(c.id, by: -1))
        #expect(vm.tabs.map(\.id) == [c.id, b.id, a.id])
        #expect(!vm.moveTab(c.id, by: -1))  // already first
        #expect(!vm.moveTab(b.id, by: 2))   // one step at a time only
        #expect(!vm.moveTab(UUID(), by: 1)) // a closed tab
        #expect(vm.tabs.map(\.id) == [c.id, b.id, a.id])
    }

    @Test func moveTabsIgnoresNoopsAndBadOffsets() {
        let store = StubStore()
        let vm = TabsViewModel(store: store)
        _ = vm.appendPickerTab()
        let before = vm.tabs.map(\.id)
        vm.moveTabs(fromOffsets: [0], toOffset: 0)   // dropped where it was
        vm.moveTabs(fromOffsets: [0], toOffset: 1)   // the gap right after itself
        vm.moveTabs(fromOffsets: [7], toOffset: 0)   // stale index
        vm.moveTabs(fromOffsets: [0], toOffset: 9)   // out of range
        #expect(vm.tabs.map(\.id) == before)
    }

    // MARK: - Session teardown

    /// Plain shells (no claude) so these tests never launch Claude Code.
    private static let shellOnly = TerminalSessionFactory(autoStartClaude: { false })

    private static func seededStore(cwds: [String?]) -> StubStore {
        let store = StubStore()
        store.seed = PersistedTabsState(
            tabs: cwds.map { PersistedTab(id: UUID(), title: "t", workingDirectory: $0) },
            activeTabID: nil
        )
        return store
    }

    @Test func closeTabClosesTheRemovedSession() {
        let vm = TabsViewModel(store: Self.seededStore(cwds: ["/tmp", "/tmp"]), sessionFactory: Self.shellOnly)
        let victim = vm.tabs[1]
        let survivor = vm.tabs[0]
        let victimSession = victim.session
        vm.closeTab(victim.id)
        #expect(victimSession?.isClosed == true)
        #expect(victim.session == nil)   // released, see closingATabReleasesItsSession
        #expect(survivor.session?.isClosed == false)
        survivor.session?.close()
    }

    @Test func closeOtherTabsClosesEveryRemovedSession() {
        let vm = TabsViewModel(store: Self.seededStore(cwds: ["/tmp", "/tmp", "/tmp"]), sessionFactory: Self.shellOnly)
        let keeper = vm.tabs[1]
        let removed = [vm.tabs[0], vm.tabs[2]]
        let removedSessions = removed.compactMap(\.session)
        vm.closeOtherTabs(keeping: keeper.id)
        #expect(removedSessions.count == 2)
        #expect(removedSessions.allSatisfy { $0.isClosed })
        #expect(removed.allSatisfy { $0.session == nil })
        #expect(keeper.session?.isClosed == false)
        keeper.session?.close()
    }

    // MARK: - Lazy restore

    @Test func restoredTabsStartOnlyWhenOpened() {
        let vm = TabsViewModel(store: Self.seededStore(cwds: ["/tmp", "/tmp", "/tmp"]), sessionFactory: Self.shellOnly)
        defer { vm.tabs.forEach { $0.session?.close() } }
        #expect(vm.activeTabID == vm.tabs[0].id)
        #expect(vm.tabs[0].session?.isStarted == true)
        #expect(vm.tabs[1].session?.isStarted == false)
        #expect(vm.tabs[2].session?.isStarted == false)
        vm.select(vm.tabs[2].id)
        #expect(vm.tabs[2].session?.isStarted == true)
        #expect(vm.tabs[1].session?.isStarted == false)
    }

    /// Resumes a restored tab's session with a harmless binary: `true`
    /// ignores the claude arguments, then the shell takes over.
    private static func resumingFactory(openElsewhere: Bool) -> TerminalSessionFactory {
        var factory = TerminalSessionFactory(
            autoStartClaude: { true },
            claudeBinaryPath: { "/usr/bin/true" },
            continueLastSession: { true }
        )
        factory.hookSettingsPath = { nil }
        factory.sessionExists = { _, _ in true }
        factory.makeSessionID = { "forked-id" }
        factory.isSessionOpenElsewhere = { _ in openElsewhere }
        return factory
    }

    private static func storeWithSession(_ id: String) -> StubStore {
        let store = StubStore()
        store.seed = PersistedTabsState(
            tabs: [PersistedTab(id: UUID(), title: "t", workingDirectory: "/tmp", claudeSessionID: id)],
            activeTabID: nil
        )
        return store
    }

    @Test func restoredSessionOpenElsewhereIsForked() async throws {
        let store = Self.storeWithSession("old-id")
        var factory = Self.resumingFactory(openElsewhere: true)
        factory.sessionExists = { _, id in id == "old-id" }   // a fork has no transcript yet
        let vm = TabsViewModel(store: store, sessionFactory: factory)
        defer { vm.tabs.forEach { $0.session?.close() } }
        let tab = vm.tabs[0]
        let session = try #require(tab.session)
        #expect(!session.isStarted)          // waits for the check
        await vm.pendingStarts[tab.id]?.value
        #expect(session.isStarted)
        #expect(session.configuration.initialCommand
                == ["/usr/bin/true", "--resume", "old-id", "--fork-session", "--session-id", "forked-id"])
        #expect(session.claudeSessionID == "forked-id")
        #expect(tab.claudeSessionID == "forked-id")
        vm.flushPersistence()       // a relaunch continues the fork...
        #expect(store.savedStates.last?.tabs.first?.claudeSessionID == "forked-id")
        // ...and, while the fork has no transcript, knows where it came from.
        #expect(store.savedStates.last?.tabs.first?.forkedFromSessionID == "old-id")
    }

    @Test func forkOriginIsDroppedOnceTheForkIsWritten() async throws {
        let store = Self.storeWithSession("old-id")
        var factory = Self.resumingFactory(openElsewhere: true)
        var forkWritten = false
        factory.sessionExists = { _, id in id == "old-id" || forkWritten }
        let vm = TabsViewModel(store: store, sessionFactory: factory)
        defer { vm.tabs.forEach { $0.session?.close() } }
        await vm.pendingStarts[vm.tabs[0].id]?.value
        vm.flushPersistence()
        #expect(store.savedStates.last?.tabs.first?.forkedFromSessionID == "old-id")
        forkWritten = true
        vm.renameTab(id: vm.tabs[0].id, to: "renamed")     // any save
        vm.flushPersistence()
        #expect(store.savedStates.last?.tabs.first?.forkedFromSessionID == nil)
        #expect(vm.tabs[0].pendingFork == nil)
    }

    @Test func anUnwrittenForkFallsBackToItsOriginalOnRelaunch() async throws {
        let store = StubStore()
        store.seed = PersistedTabsState(
            tabs: [PersistedTab(id: UUID(), title: "t", workingDirectory: "/tmp",
                                claudeSessionID: "forked-id", forkedFromSessionID: "old-id")],
            activeTabID: nil
        )
        var factory = Self.resumingFactory(openElsewhere: false)
        factory.sessionExists = { _, id in id == "old-id" }   // the fork was never written
        let vm = TabsViewModel(store: store, sessionFactory: factory)
        defer { vm.tabs.forEach { $0.session?.close() } }
        await vm.pendingStarts[vm.tabs[0].id]?.value
        #expect(vm.tabs[0].session?.configuration.initialCommand == ["/usr/bin/true", "--resume", "old-id"])
        #expect(vm.tabs[0].claudeSessionID == "old-id")
    }

    @Test func restoredSessionNotOpenElsewhereResumesInPlace() async throws {
        let vm = TabsViewModel(store: Self.storeWithSession("old-id"),
                               sessionFactory: Self.resumingFactory(openElsewhere: false))
        defer { vm.tabs.forEach { $0.session?.close() } }
        let tab = vm.tabs[0]
        await vm.pendingStarts[tab.id]?.value
        let session = try #require(tab.session)
        #expect(session.isStarted)
        #expect(session.configuration.initialCommand == ["/usr/bin/true", "--resume", "old-id"])
        #expect(tab.claudeSessionID == "old-id")
        #expect(vm.pendingStarts.isEmpty)
    }

    @Test func aTabClosedDuringTheCheckNeverStarts() async throws {
        let vm = TabsViewModel(store: Self.storeWithSession("old-id"),
                               sessionFactory: Self.resumingFactory(openElsewhere: true))
        let tab = vm.tabs[0]
        let session = try #require(tab.session)
        session.close()
        await vm.pendingStarts[tab.id]?.value
        #expect(!session.isStarted)
    }

    @Test func anUnopenedTabKeepsItsPlaceAndClosesCleanly() throws {
        let store = Self.seededStore(cwds: ["/tmp", "/private/tmp"])
        let vm = TabsViewModel(store: store, sessionFactory: Self.shellOnly)
        defer { vm.tabs.forEach { $0.session?.close() } }
        let unopened = vm.tabs[1]
        // Still saved with its folder, so the next launch restores it too.
        vm.flushPersistence()
        _ = vm.tabs[0].session  // keep the active one alive
        vm.renameTab(id: vm.tabs[0].id, to: "renamed")
        vm.flushPersistence()
        #expect(store.savedStates.last?.tabs.map(\.workingDirectory) == ["/tmp", "/private/tmp"])
        let session = try #require(unopened.session)
        vm.closeTab(unopened.id)
        #expect(session.isClosed)
        session.start()                     // closed: never starts afterwards
        #expect(!session.isStarted)
    }

    @Test func openDirectoryReusesItsTabOrOpensOne() {
        let vm = TabsViewModel(store: Self.seededStore(cwds: ["/tmp"]), sessionFactory: Self.shellOnly)
        defer { vm.tabs.forEach { $0.session?.close() } }
        let first = vm.tabs[0]
        #expect(vm.openDirectory("/tmp").id == first.id)
        // The same folder spelled through a symlink (/tmp → /private/tmp)
        // or with a trailing slash is the same tab.
        #expect(vm.openDirectory("/private/tmp").id == first.id)
        #expect(vm.openDirectory("/tmp/").id == first.id)
        let opened = vm.openDirectory("/usr")
        #expect(vm.tabs.count == 2)
        #expect(vm.activeTabID == opened.id)
        #expect(opened.title == "usr")
        #expect(opened.session?.isStarted == true)
    }

    // MARK: - Persistence

    @Test func restoreAppliesPersistedCustomTitle() {
        let store = StubStore()
        store.seed = PersistedTabsState(
            tabs: [
                PersistedTab(id: UUID(), title: "Renamed", workingDirectory: nil, hasCustomTitle: true),
                PersistedTab(id: UUID(), title: "Plain", workingDirectory: nil)
            ],
            activeTabID: nil
        )
        let vm = TabsViewModel(store: store)
        #expect(vm.tabs[0].hasCustomTitle)
        #expect(!vm.tabs[1].hasCustomTitle)
    }

    @Test func renamePersistsCustomTitleFlag() {
        let store = Self.seededStore(cwds: [nil])
        let vm = TabsViewModel(store: store)
        vm.renameTab(id: vm.tabs[0].id, to: "Mine")
        vm.flushPersistence()
        let saved = store.savedStates.last?.tabs.first
        #expect(saved?.title == "Mine")
        #expect(saved?.hasCustomTitle == true)
    }
}

/// What counts as "this session is open in another process".
struct OpenSessionDetectorTests {
    private let id = "bdc6ae86-47a9-46ad-b02b-b09f8d4ec9c7"

    @Test func sessionFlagsCount() {
        #expect(OpenSessionDetector.mentions(sessionID: id, in: "12 claude --resume \(id)\n"))
        #expect(OpenSessionDetector.mentions(sessionID: id, in: "12 claude -r \(id) --settings x\n"))
        #expect(OpenSessionDetector.mentions(sessionID: id, in: "12 claude --session-id \(id)\n"))
        #expect(OpenSessionDetector.mentions(sessionID: id, in: "12 claude --resume=\(id)\n"))
    }

    @Test func shellWrappersCount() {
        // How another Claude Code GUI starts it: the id ends
        // with `;`.
        let otherApp = "5512 /bin/zsh -l -i -c claude --resume \(id); exec $SHELL -l -i"
        #expect(OpenSessionDetector.mentions(sessionID: id, in: otherApp))
        let quoted = "77 -zsh -l -i -c '/usr/bin/claude' '--resume' '\(id)' '--settings' 'x'"
        #expect(OpenSessionDetector.mentions(sessionID: id, in: quoted))
    }

    @Test func aMereMentionDoesNotCount() {
        #expect(!OpenSessionDetector.mentions(sessionID: id, in: "40 grep -c \(id) file\n"))
        #expect(!OpenSessionDetector.mentions(sessionID: id, in: "40 grep -r \(id) .\n"))
        #expect(!OpenSessionDetector.mentions(sessionID: id, in: "41 claude --resume other-id\n"))
        #expect(!OpenSessionDetector.mentions(sessionID: id, in: "42 claude --resume\n"))
        #expect(!OpenSessionDetector.mentions(sessionID: "", in: "43 claude --resume \n"))
    }

    @Test func xylemsOwnLeftoversDoNotCount() {
        // The previous launch's claude, still exiting after a quick relaunch.
        let own = "12 claude --resume \(id) --settings /Users/x/.xylem/hooks/settings.json\n"
        #expect(!OpenSessionDetector.mentions(sessionID: id, in: own, ignoringLinesContaining: ClaudeHookBridge.settingsFileMarker))
        #expect(OpenSessionDetector.mentions(sessionID: id, in: own))
    }

    @Test func forkedLaunchIsNotAnInPlaceResume() {
        #expect(TerminalSessionFactory.resumedSessionID(in: ["claude", "--resume", "a"]) == "a")
        #expect(TerminalSessionFactory.resumedSessionID(in: ["claude", "--resume", "a", "--fork-session", "--session-id", "b"]) == nil)
        #expect(TerminalSessionFactory.resumedSessionID(in: ["claude", "--session-id", "b"]) == nil)
        #expect(TerminalSessionFactory.resumedSessionID(in: ["claude", "--resume"]) == nil)
        #expect(TerminalSessionFactory.resumedSessionID(in: nil) == nil)
    }
}
