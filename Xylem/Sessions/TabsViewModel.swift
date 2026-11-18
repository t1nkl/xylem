//
//  TabsViewModel.swift
//  Xylem
//
//  Owns the list of tabs and the active selection. One tab = one terminal
//  session (no panes) - this view model mediates every mutation
//  (new tab, configure, resume session, close) so invariants and
//  persistence stay in one place. Every tab it drops gets its session
//  `close()`d here - the shell is killed explicitly, not left to ARC.
//

import AppKit
import Foundation
import Observation

@Observable
final class TabsViewModel {
    /// Mutations to the tabs array and the active selection auto-persist via
    /// didSet. Mutations that reach INTO a tab (title) fire `schedulePersist()`
    /// explicitly because didSet on the array doesn't catch reference mutations.
    private(set) var tabs: [TerminalTab] = [] {
        didSet { schedulePersist() }
    }
    private(set) var activeTabID: TerminalTab.ID? {
        didSet {
            // Restored tabs wait for this: their shell and claude start the
            // first time the tab is shown.
            if let activeTab { startIfNeeded(activeTab) }
            schedulePersist()
        }
    }
    /// Restored tabs whose start waits for the open-elsewhere check, by tab.
    /// Internal for tests (they await the task).
    @ObservationIgnored private(set) var pendingStarts: [TerminalTab.ID: Task<Void, Never>] = [:]

    private let store: TabsStateStoring
    private let sessionFactory: TerminalSessionFactory
    @ObservationIgnored private var pendingPersist: DispatchWorkItem?
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?
    /// Set while restoring from disk so we don't write back the state we just
    /// read - harmless but wasteful.
    private var suspendsPersist = false
    /// Set by restore when a tab's session id differs from the saved one.
    private var restoredBindingsChanged = false

    init(
        store: TabsStateStoring = TabsStateStore.shared,
        sessionFactory: TerminalSessionFactory = TerminalSessionFactory()
    ) {
        self.store = store
        self.sessionFactory = sessionFactory
        suspendsPersist = true
        let seeded = restoreOrSeed()
        suspendsPersist = false
        // Restore binds tabs to sessions (fresh ids, the migration's picks):
        // write them now, a quit before any other change would lose them.
        if seeded || restoredBindingsChanged { persistNow() }
        observeTermination()
    }

    deinit {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
    }

    // MARK: - Queries

    var activeTab: TerminalTab? {
        tabs.first { $0.id == activeTabID }
    }

    var activeSession: TerminalSession? {
        activeTab?.session
    }

    // MARK: - Tab lifecycle

    func select(_ id: TerminalTab.ID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        guard activeTabID != id else { return }
        activeTabID = id
    }

    /// New Tab (Cmd-T, "+", palette). A tab still waiting for a folder is
    /// reused instead of stacking another empty one (design choice: repeated
    /// Cmd-T used to pile up "New Tab" rows): the active one if it is a
    /// picker, else the first picker in the list.
    @discardableResult
    func openEmptyTab() -> TerminalTab {
        if let picker = activeTab.flatMap({ $0.isPicker ? $0 : nil }) ?? tabs.first(where: \.isPicker) {
            activeTabID = picker.id
            return picker
        }
        return appendPickerTab()
    }

    /// Always a new picker tab, activated. `openEmptyTab` is the user-facing
    /// entry; tests use this to build several tabs.
    @discardableResult
    func appendPickerTab() -> TerminalTab {
        let tab = TerminalTab(title: "New Tab", state: .picker)
        tabs.append(tab)
        activeTabID = tab.id
        return tab
    }

    func closeTab(_ id: TerminalTab.ID) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let removed = tabs.remove(at: index)
        discard(removed)
        if activeTabID == id {
            activeTabID = tabs[max(0, index - 1)].id
        }
    }

    /// Closes every tab except the one with `keepID`. If `keepID` is nil,
    /// keeps the currently active tab.
    func closeOtherTabs(keeping keepID: TerminalTab.ID? = nil) {
        let keeper = keepID ?? activeTabID
        guard let keeper, tabs.contains(where: { $0.id == keeper }) else { return }
        let removed = tabs.filter { $0.id != keeper }
        tabs = tabs.filter { $0.id == keeper }
        activeTabID = keeper
        for tab in removed { discard(tab) }
    }

    /// Tabs whose claude never started: launched with claude, at a shell
    /// prompt, and not a single hook event ("command not found" before the
    /// Doctor's PATH fix). A tab where claude ran and was quit on purpose
    /// has had events (`claudeState` set), so restarting never throws away
    /// a shell the user kept. Without hooks no tab qualifies either way.
    func tabsWithoutClaude() -> [TerminalTab] {
        tabs.filter { tab in
            guard tab.claudeState == nil, let session = tab.session, session.launchedClaude,
                  session.launchedWithHooks, session.isStarted, !session.isClosed
            else { return false }
            return session.shellIsInForeground
        }
    }

    /// Starts such a tab over in its folder: a new login shell (which now
    /// reads the fixed PATH) running claude - the tab's own session when its
    /// transcript exists, else a fresh one. Does nothing while something
    /// runs in the tab's foreground.
    func restartClaude(in tabID: TerminalTab.ID) {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let session = tab.session, session.shellIsInForeground,
              let directory = tab.workingDirectory
        else { return }
        let fresh = sessionFactory.makeRestoredSession(
            tabID: tab.id,
            title: tab.title,
            directory: directory,
            sessionID: tab.claudeSessionID
        )
        let keepsCustomTitle = tab.hasCustomTitle
        tab.attach(session: fresh, title: tab.title)
        tab.hasCustomTitle = keepsCustomTitle
        ClaudeHookBridge.removeEvents(forTab: tab.id)
        schedulePersist()
    }

    /// A dropped tab: its shell dies, its hook-event file goes.
    private func discard(_ tab: TerminalTab) {
        tab.session?.close()
        tab.releaseSession()
        ClaudeHookBridge.removeEvents(forTab: tab.id)
    }

    nonisolated private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Claude sessions bound to tabs other than `tabID`; continuing one of
    /// them in a second tab would put two claude processes on one file.
    func boundSessionIDs(except tabID: TerminalTab.ID? = nil) -> Set<String> {
        Set(tabs.filter { $0.id != tabID }.compactMap(\.claudeSessionID))
    }

    /// The hooks moved a tab to another session (`/clear`, `/resume`):
    /// persist it so a relaunch resumes the right one.
    func sessionBindingChanged() {
        schedulePersist()
    }

    func renameTab(id: TerminalTab.ID, to newTitle: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty, or confirmed without a change to what the tab shows (Enter
        // in the rename field): nothing to do - marking it custom would stop
        // cwd tracking. Compared with `displayTitle`, which follows the cwd.
        guard !trimmed.isEmpty, trimmed != tab.displayTitle else { return }
        tab.title = trimmed
        // Opt out of cwd-tracking once the user gives the tab a real name -
        // otherwise their chosen title would be stomped on next `cd`.
        tab.hasCustomTitle = true
        schedulePersist()
    }

    /// Moves tabs the way `List.onMove` reports it: `offsets` are the
    /// dragged rows, `destination` is the gap they were dropped into,
    /// counted in the list before the move.
    func moveTabs(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let valid = offsets.filter { tabs.indices.contains($0) }
        guard !valid.isEmpty, (0...tabs.count).contains(destination) else { return }
        let moved = valid.map { tabs[$0] }
        let insertAt = destination - valid.filter { $0 < destination }.count
        var remaining = tabs
        for index in valid.sorted(by: >) { remaining.remove(at: index) }
        remaining.insert(contentsOf: moved, at: insertAt)
        guard remaining.map(\.id) != tabs.map(\.id) else { return }
        tabs = remaining
    }

    /// Moves one tab a step left (`-1`) or right (`+1`), as a drag in the
    /// top tab bar does each time it crosses a neighbour. Reads the live
    /// order, so steps arriving before the view re-renders stay correct.
    /// False at either end (nothing moved).
    @discardableResult
    func moveTab(_ id: TerminalTab.ID, by step: Int) -> Bool {
        guard step == 1 || step == -1,
              let index = tabs.firstIndex(where: { $0.id == id }),
              tabs.indices.contains(index + step)
        else { return false }
        tabs.swapAt(index, index + step)
        return true
    }

    // MARK: - Tab configuration

    /// Configure a picker tab with a working directory and kick off a Claude
    /// Code session in it.
    func configure(
        _ tabID: TerminalTab.ID,
        withDirectory directory: String,
        autoStartClaude: Bool = true
    ) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        guard case .picker = tab.state else { return }
        let name = (directory as NSString).lastPathComponent
        let openElsewhere = tabs.contains { $0.id != tabID && $0.workingDirectory == directory }
        let session = sessionFactory.makeProjectSession(
            tabID: tabID,
            title: name,
            directory: directory,
            launchClaude: autoStartClaude,
            allowContinue: !openElsewhere,
            excluding: boundSessionIDs(except: tabID)
        )
        tab.attach(session: session, title: name.isEmpty ? directory : name)
        schedulePersist()
    }

    @discardableResult
    func openProject(_ project: ClaudeProject, autoStartClaude: Bool = true) -> TerminalTab {
        openDirectory(project.path, title: project.displayName, autoStartClaude: autoStartClaude)
    }

    /// Opens a folder the way a project from the list opens: the tab that
    /// already has it, else the active picker, else a new tab - continuing
    /// the folder's newest session when there is one (a fresh worktree has
    /// none, so its claude starts clean).
    @discardableResult
    func openDirectory(_ directory: String, title: String? = nil, autoStartClaude: Bool = true) -> TerminalTab {
        let name = title ?? (directory as NSString).lastPathComponent
        // Same folder, however it is spelled: the Git panel lists worktrees
        // as `/tmp/…` while git reported `/private/tmp/…` when the tab was
        // made (seen live - a second tab opened).
        let target = Self.canonical(directory)
        if let existing = tabs.first(where: { $0.workingDirectory.map(Self.canonical) == target }) {
            activeTabID = existing.id
            return existing
        }
        if let picker = activeTab, case .picker = picker.state {
            configure(picker.id, withDirectory: directory, autoStartClaude: autoStartClaude)
            return picker
        }
        // No tab has this directory (checked above), so continuing its last
        // session can't collide with another claude on the same file.
        let tabID = UUID()
        let session = sessionFactory.makeProjectSession(
            tabID: tabID,
            title: name,
            directory: directory,
            launchClaude: autoStartClaude,
            excluding: boundSessionIDs()
        )
        let tab = TerminalTab(id: tabID, title: name, state: .session(session))
        tabs.append(tab)
        activeTabID = tab.id
        return tab
    }

    @discardableResult
    func resumeSession(_ session: ClaudeSession, claudeBinary: String? = nil) -> TerminalTab {
        // Already open in a tab: go there instead of a second claude on
        // the same session file.
        if let open = tabs.first(where: { $0.claudeSessionID == session.id }) {
            activeTabID = open.id
            return open
        }
        let title = session.title.isEmpty ? session.id : session.title
        let picker = activeTab.flatMap { tab -> TerminalTab? in
            if case .picker = tab.state { return tab }
            return nil
        }
        let tabID = picker?.id ?? UUID()
        let terminal = sessionFactory.makeResumeSession(
            tabID: tabID,
            title: title,
            directory: session.projectPath,
            sessionID: session.id,
            claudeBinary: claudeBinary
        )
        let tab: TerminalTab
        if let picker {
            picker.attach(session: terminal, title: title)
            tab = picker
            schedulePersist()  // attach() mutates tab reference, not array
        } else {
            let newTab = TerminalTab(id: tabID, title: title, state: .session(terminal))
            tabs.append(newTab)
            activeTabID = newTab.id
            tab = newTab
        }
        return tab
    }

    // MARK: - Persistence

    /// Returns true if the app had to seed a fresh default (no prior state).
    @discardableResult
    private func restoreOrSeed() -> Bool {
        guard let state = store.load(), !state.tabs.isEmpty else {
            seedDefault()
            return true
        }
        // A session id resumes in one tab only (two claude processes must
        // never share a session file); a duplicate starts fresh.
        var claimed: Set<String> = []
        // Tabs saved before they remembered their session (one-time): the
        // folder's newest session nobody else claimed - what that tab was
        // most likely running.
        let legacy = state.tabs.allSatisfy { $0.claudeSessionID == nil }
        tabs = state.tabs.map { persisted in
            var sessionID = persisted.claudeSessionID
            if sessionID == nil, legacy, let dir = persisted.workingDirectory {
                sessionID = sessionFactory.newestSessionID(dir, claimed)
            }
            // Forked last time but never written to: back to the original
            // (its start checks again whether it is open elsewhere).
            if let id = sessionID, let original = persisted.forkedFromSessionID,
               let dir = persisted.workingDirectory,
               !sessionFactory.sessionExists(dir, id), sessionFactory.sessionExists(dir, original) {
                sessionID = original
            }
            if let id = sessionID {
                if claimed.contains(id) { sessionID = nil } else { claimed.insert(id) }
            }
            let tab = restoreTab(persisted, sessionID: sessionID)
            if tab.claudeSessionID != persisted.claudeSessionID { restoredBindingsChanged = true }
            return tab
        }
        if let savedActive = state.activeTabID, tabs.contains(where: { $0.id == savedActive }) {
            activeTabID = savedActive
        } else {
            activeTabID = tabs.first?.id
        }
        return false
    }

    /// Starts a tab's shell the first time it is shown. A restored tab that
    /// resumes its session checks first whether that session is still open
    /// in another process (another app or terminal, ~40 ms off main): two
    /// claude processes appending to one transcript interleave it, so the
    /// tab forks the conversation under a new id instead.
    private func startIfNeeded(_ tab: TerminalTab) {
        guard let session = tab.session, !session.isStarted, pendingStarts[tab.id] == nil else { return }
        guard let resumed = TerminalSessionFactory.resumedSessionID(in: session.configuration.initialCommand) else {
            session.start()
            return
        }
        let factory = sessionFactory
        pendingStarts[tab.id] = Task { [weak self, weak tab] in
            if await factory.isSessionOpenElsewhere(resumed), let tab, tab.session === session {
                let launch = factory.forkLaunch(sessionID: resumed)
                session.replaceLaunch(command: launch.command, sessionID: launch.sessionID)
                tab.claudeSessionID = launch.sessionID
                tab.pendingFork = SessionFork(original: resumed, fork: launch.sessionID)
                self?.schedulePersist()
            }
            session.start()
            self?.pendingStarts[session.id] = nil  // the session id is its tab id
        }
    }

    private func restoreTab(_ persisted: PersistedTab, sessionID: String?) -> TerminalTab {
        let state: TerminalTabState
        if let cwd = persisted.workingDirectory {
            // Started when first shown (see `activeTabID`): with ten saved
            // tabs a relaunch used to load ten sessions - and run ten
            // claude processes - before the user looked at any of them.
            state = .session(sessionFactory.makeRestoredSession(
                tabID: persisted.id,
                title: persisted.title,
                directory: cwd,
                sessionID: sessionID,
                startsImmediately: false
            ))
        } else {
            state = .picker
        }
        let tab = TerminalTab(id: persisted.id, title: persisted.title, state: state)
        tab.hasCustomTitle = persisted.hasCustomTitle
        return tab
    }

    private func seedDefault() {
        // First-ever launch: seed a picker instead of an auto-home-session so
        // the welcome sheet's "Open Folder" flow produces one clean tab
        // (otherwise the user ends up with [home, picked-folder] side by side).
        // Returning users without state (cleared tabs-state.json) still get a
        // home session for usability.
        if !AppSettings.welcomed {
            let tab = TerminalTab(title: "New Tab", state: .picker)
            tabs = [tab]
            activeTabID = tab.id
            return
        }
        let tabID = UUID()
        let session = sessionFactory.makeSession(tabID: tabID, title: "home", directory: nil)
        let tab = TerminalTab(id: tabID, title: "home", state: .session(session))
        tabs = [tab]        // triggers didSet → schedulePersist
        activeTabID = tab.id
    }

    /// Coalesces rapid-fire mutations (drag, stream of menu taps) into a
    /// single save ~120ms later. Only the snapshot is built on main; the
    /// store encodes and writes on its own serial queue.
    private func schedulePersist() {
        guard !suspendsPersist else { return }
        pendingPersist?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingPersist = nil
            self?.persistNow()
        }
        pendingPersist = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func persistNow() {
        let persistedTabs = tabs.map { tab in
            PersistedTab(
                id: tab.id,
                title: tab.title,
                workingDirectory: tab.primaryCwd,
                hasCustomTitle: tab.hasCustomTitle,
                claudeSessionID: tab.claudeSessionID,
                forkedFromSessionID: unwrittenForkOrigin(of: tab)
            )
        }
        store.save(PersistedTabsState(tabs: persistedTabs, activeTabID: activeTabID))
    }

    /// The session a tab forked from, while the fork is still its session
    /// and has no transcript. Dropped (for good) once either changes: the
    /// fork was written to, or `/clear`/`/resume` moved the tab on.
    private func unwrittenForkOrigin(of tab: TerminalTab) -> String? {
        guard let fork = tab.pendingFork else { return nil }
        guard tab.claudeSessionID == fork.fork, let directory = tab.workingDirectory,
              !sessionFactory.sessionExists(directory, fork.fork)
        else {
            tab.pendingFork = nil
            return nil
        }
        return fork.original
    }

    /// Writes any change still sitting in the debounce window and waits for
    /// the store's background write to land.
    func flushPersistence() {
        if let pending = pendingPersist {
            pending.cancel()
            pendingPersist = nil
            persistNow()
        }
        store.flush()
    }

    /// The process can exit right after `willTerminate`, so the flush must
    /// finish inside the notification callback: `queue: nil` runs the block
    /// synchronously on the posting thread (main, for this notification).
    /// A `Task { @MainActor in … }` hop here would never get to run.
    private func observeTermination() {
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushPersistence()
            }
        }
    }
}
