//
//  ContentView.swift
//  Xylem
//
//  Root view. Only composes the native window shell: the tab list as the
//  NavigationSplitView sidebar, the terminals (plus the bottom bar) as the
//  detail, then the Claude / Git panel and the panel rail (RightPanel.swift),
//  the window toolbar, and the sheets. State and work live in AppModel; menu actions arrive via
//  NotificationCenter so they survive loss of key-window focus.
//
//  Performance rule for this file: `body` must not read anything that
//  changes on a timer (session stats, git status, the project list). Those
//  reads live in small containers (the toolbar items, TerminalsStack-
//  Container, the panel sections), so a poll tick re-renders the view that
//  shows the value instead of the whole window.
//
//  The detail column is always the same TerminalsStackContainer: switching
//  it on selection would tear down terminal views (and their shells).
//

import SwiftUI
import AppKit

struct ContentView: View {
    let app: AppModel
    /// Only for the toolbar's "update ready" capsule.
    let updater: AppUpdater

    @State private var activeSheet: ActiveSheet?
    /// The release notes of the version just installed, shown once.
    @State private var whatsNew: WhatsNewStore.Pending?
    @AppStorage(AppSettings.Keys.welcomed) private var hasWelcomed: Bool = false
    @AppStorage(AppSettings.Keys.leftSidebarCollapsed) private var tabSidebarCollapsed: Bool = false
    @AppStorage(AppSettings.Keys.inspectorVisible) private var showsInspector: Bool = true
    /// Claude or Git in the right panel, picked on the rail.
    @AppStorage(AppSettings.Keys.panelTab) private var panelTab: RightSidebarView.SidebarTab = .claude
    @Environment(\.openSettings) private var openSettings

    private var tabs: TabsViewModel { app.tabs }

    /// Claude / Git / Files / Changes, always at the window's right edge.
    private var rail: some View {
        PanelRailContainer(drawer: app.drawer, showsInspector: $showsInspector, panelTab: $panelTab,
                           directory: { [app] in app.activeDirectory },
                           onDrawerClosed: { [app] in app.focusActiveTerminal() })
    }

    private var drawerActions: ProjectDrawerActions {
        ProjectDrawerActions(
            insertPath: { [app] in app.insertPath($0) },
            openFile: FileOpener.open,
            revealInFinder: FileOpener.reveal,
            openerName: { FileOpener.chosenAppName }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            LeftTabSidebar(
                tabs: tabs.tabs,
                activeTabID: tabs.activeTabID,
                onSelect: { app.selectTab($0) },
                onReactivate: { app.focusActiveTerminal() },
                onClose: tabs.closeTab,
                onShowOverview: { activeSheet = .overview },
                onRename: { tabs.renameTab(id: $0, to: $1) },
                onMove: { tabs.moveTabs(fromOffsets: $0, toOffset: $1) },
                onCloseOthers: { tabs.closeOtherTabs(keeping: $0) }
            )
            .navigationSplitViewColumnWidth(
                min: AppTheme.Metrics.tabSidebarMinWidth,
                ideal: AppTheme.Metrics.tabSidebarIdealWidth,
                max: AppTheme.Metrics.tabSidebarMaxWidth
            )
        } detail: {
            // Bottom bar in a VStack, not a safe-area inset: the terminal's
            // frame (and so its rows) must end above the bar.
            GeometryReader { detail in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    // The drawer lies over the terminal: the terminal keeps
                    // its size (no resize, no redraw) while you browse.
                    TerminalsStackContainer(tabs: tabs, sessionList: app.sessionList)
                        .overlay(alignment: .trailing) {
                            ProjectDrawerContainer(drawer: app.drawer, actions: drawerActions)
                        }
                    BottomToolbar(actions: AppCommands.toolbar(app: app, present: { activeSheet = $0 }),
                                  doctorStatus: { [app] in app.doctorStatus },
                                  onDoctorOpen: { [app] in app.doctorOpened() },
                                  onDoctorCheckAgain: { [app] in await app.recheckDoctor() },
                                  tabsWithoutClaude: { [app] in app.tabsWithoutClaudeCount },
                                  onRestartTabsWithoutClaude: { [app] in app.restartTabsWithoutClaude() },
                                  hooks: app.claudeStates, projectDirectory: { [app] in app.activeDirectory },
                                  canAddWorktree: { [app] in app.worktreeBaseDirectory != nil })
                }
                // Our own right panel, not the system `.inspector`: the
                // inspector animates its width (the terminal re-laid out every
                // frame) and nothing can sit to its right, so the rail had to
                // jump between two places on every toggle (it felt jerky).
                // Here the panel appears at once and the rail never moves.
                RightPanelContainer(isShown: showsInspector,
                                    maxWidth: RightPanelContainer<RightSidebarView>.maxWidth(detailWidth: detail.size.width)) {
                        RightSidebarView(
                            sessionList: app.sessionList,
                            environment: app.environment,
                            gitStatus: app.gitStatus,
                            agentTeams: app.agentTeams,
                            // A tab running claude: `/mcp` and `/plugin` need it.
                            hasActiveSession: tabs.activeSession?.launchedClaude == true,
                            isPresented: showsInspector,
                            actions: sidebarActions,
                            tab: panelTab
                        )
                }
                rail
            }
            }
            // The panel and the drawer are one at a time (design choice): the
            // toolbar's panel button and ⌃⌘I close the drawer like the rail does.
            .onChange(of: showsInspector) { _, shown in
                if shown { app.drawer.close() }
            }

        }
        .toolbar {
            WindowToolbar(
                app: app,
                updater: updater,
                showsInspector: $showsInspector,
                onNewTab: { tabs.openEmptyTab() },
                onOpenUsage: { activeSheet = .usage }
            )
        }
        .preferredColorScheme(.dark)
        .tint(AppTheme.Colors.accent)
        .environment(\.xylemPalette, AppTheme.Colors)
        .frame(minWidth: 1100, minHeight: 650)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .usage: UsageDashboardView()
            case .skills:
                SkillsDirectorySheet(onInstall: { skill in
                    app.installSkill(skill)
                    activeSheet = nil
                })
            case .overview: AllSessionsOverviewSheet(tabs: tabs)
            case .commandPalette:
                CommandPaletteSheet(
                    commands: AppCommands.palette(
                        app: app,
                        present: { activeSheet = $0 },
                        openSettings: { openSettings() }
                    ),
                    prompts: AppCommands.prompts(app: app),
                    // A command may have presented another sheet (Usage,
                    // Skills, New Worktree Tab…) just before the palette
                    // closes; clearing unconditionally dismissed it at once.
                    onClose: { if activeSheet == .commandPalette { activeSheet = nil } }
                )
            case .cheatsheet:
                KeyboardCheatsheet(onClose: { activeSheet = nil })
            case .newWorktree:
                NewWorktreeSheet(
                    baseBranch: tabs.activeTab?.gitBranch,
                    repositoryName: app.worktreeBaseDirectory.map { ($0 as NSString).lastPathComponent } ?? "the repository",
                    create: { try await app.openWorktreeTab(branch: $0) },
                    onClose: { activeSheet = nil }
                )
            }
        }
        .sheet(isPresented: showOnboarding) { onboarding }
        .task {
            app.start()
            // Not over the first-launch welcome (a new user has no "before"),
            // and not from a Debug run: it shares the installed app's
            // defaults and would use up its notes.
            if hasWelcomed, updater.isRunning {
                whatsNew = WhatsNewStore.take(runningVersion: WhatsNewStore.runningVersion)
            }
        }
        .sheet(item: $whatsNew) { pending in
            WhatsNewSheet(version: pending.version, notes: ReleaseNotes(markdown: pending.notes),
                          onClose: { whatsNew = nil })
        }
        // Keyed on tab id and directory so it also fires when a picker tab
        // becomes a session (same id, new directory).
        .task(id: activeTaskKey) { await app.activeContextChanged() }
        .onReceive(NotificationCenter.default.publisher(for: .xylemOpenCommandPalette)) { _ in
            activeSheet = .commandPalette
        }
        .onReceive(NotificationCenter.default.publisher(for: .xylemShowWelcome)) { _ in
            // Flip the stored flag back; dismissing sets it to true again.
            hasWelcomed = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .xylemMenuAction)) { notification in
            guard let action = notification.object as? MenuTabAction else { return }
            handleMenuAction(action)
        }
    }

    /// The tab list's collapsed state survives relaunches.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { tabSidebarCollapsed ? .detailOnly : .all },
            set: { tabSidebarCollapsed = ($0 == .detailOnly) }
        )
    }

    private var activeTaskKey: String {
        (tabs.activeTabID?.uuidString ?? "none") + "|" + (app.activeDirectory ?? "-")
    }

    private var sidebarActions: RightSidebarActions {
        RightSidebarActions(
            selectSession: { tabs.resumeSession($0) },
            selectProject: { tabs.openProject($0) },
            runInActiveTab: { app.runInActiveSession($0) },
            openSkillsDirectory: { activeSheet = .skills },
            newWorktree: { activeSheet = .newWorktree },
            openWorktree: { app.openWorktree(at: $0) },
            scopeChanged: { app.reloadAgentTeams() }
        )
    }

    // MARK: - Onboarding

    /// Presentation reflects `!hasWelcomed`; the only meaningful write is
    /// false → mark welcomed.
    private var showOnboarding: Binding<Bool> {
        Binding(
            get: { !hasWelcomed },
            set: { if !$0 { hasWelcomed = true } }
        )
    }

    private var onboarding: some View {
        OnboardingSheet(
            mostRecentSession: app.sessionList.sessions.first,
            onOpenFolder: { path in
                // Route through the picker-to-session flow so the project
                // also shows up in the sidebar lists.
                if let tab = tabs.activeTab, case .picker = tab.state {
                    tabs.configure(tab.id, withDirectory: path)
                } else {
                    let name = (path as NSString).lastPathComponent
                    tabs.openProject(ClaudeProject(id: name, path: path, displayName: name, sessionCount: 0, lastModified: .now))
                }
                hasWelcomed = true
            },
            onResumeSession: { session in
                tabs.resumeSession(session)
                hasWelcomed = true
            },
            onDismiss: { hasWelcomed = true }
        )
    }

    // MARK: - Menu routing

    private func handleMenuAction(_ action: MenuTabAction) {
        switch action {
        case .newTab:
            tabs.openEmptyTab()
        case .closeTab:
            if let id = tabs.activeTabID { tabs.closeTab(id) }
        case .closeOtherTabs:
            tabs.closeOtherTabs()
        case .clear:
            tabs.activeSession?.clearScreen()
        case .interrupt:
            tabs.activeSession?.interrupt()
        // The drawer's code first when it has the keyboard, else the terminal.
        case .findInTerminal:
            if !CodeNSTextView.performFindIfFocused(.showFindInterface) { tabs.activeSession?.showSearchBar() }
        case .findNext:
            if !CodeNSTextView.performFindIfFocused(.nextMatch) { _ = tabs.activeSession?.findNext() }
        case .findPrevious:
            if !CodeNSTextView.performFindIfFocused(.previousMatch) { _ = tabs.activeSession?.findPrevious() }
        case .showCheatsheet:
            activeSheet = .cheatsheet
        case .showUsage:
            activeSheet = .usage
        case .openFolder:
            app.openFolder()
        case .rail(let item):
            PanelSwitch.select(item, showsInspector: $showsInspector, panelTab: $panelTab,
                               drawer: app.drawer, directory: app.activeDirectory)
        case .switchToTab(let n):
            if tabs.tabs.indices.contains(n - 1) {
                tabs.select(tabs.tabs[n - 1].id)
            }
        }
    }
}

/// Reads the project list for the new-tab picker, so a sessions reload
/// re-renders the terminals stack instead of the window root. Also names
/// the window after the active tab's project (title) and path (subtitle),
/// following `cd` in the shell.
private struct TerminalsStackContainer: View {
    let tabs: TabsViewModel
    let sessionList: SessionListViewModel

    var body: some View {
        TerminalsStack(
            tabs: tabs.tabs,
            activeTabID: tabs.activeTabID,
            recentProjects: sessionList.projects,
            onPickFolder: { tabID, path in tabs.configure(tabID, withDirectory: path) },
            onPickProject: { tabID, project in tabs.configure(tabID, withDirectory: project.path) }
        )
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
    }

    private var activeCwd: String? {
        guard let cwd = tabs.activeTab?.liveCwd, !cwd.isEmpty else { return nil }
        return cwd
    }

    private var windowTitle: String {
        if let cwd = activeCwd {
            let folder = (cwd as NSString).lastPathComponent
            if !folder.isEmpty, folder != "/" { return folder }
        }
        return tabs.activeTab?.displayTitle ?? "Xylem"
    }

    private var windowSubtitle: String {
        activeCwd.map(PathDisplay.abbreviatingHome) ?? ""
    }
}
