//
//  AppModel.swift
//  Xylem
//
//  Composition root. Builds every view model exactly once (in XylemApp) and
//  owns the work that stays out of ContentView:
//
//    · the polling loop (tab activity every 2 s, active-session stats every
//      4 s, status.claude.com every 60 s), skipped while no Xylem window is
//      visible;
//    · the Claude state loop (hook events, 1 s), which keeps running while
//      the window is hidden: that is when "Claude is waiting" matters;
//    · reacting to the active tab / directory changing;
//    · actions on the active session (screenshot, attachments, model).
//
//  View models are not `@State` initial values inside ContentView: SwiftUI
//  evaluates those expressions on every ContentView init, and each extra
//  TabsViewModel would restore the saved tabs and spawn shells that are
//  then thrown away.
//

import AppKit
import Observation

@Observable
final class AppModel {
    let tabs: TabsViewModel
    let sessionList: SessionListViewModel
    let environment: ClaudeEnvironmentViewModel
    let gitStatus: GitStatusViewModel
    let sessionStats: SessionStatsViewModel
    let tabActivity: TabActivityViewModel
    let agentTeams: AgentTeamsStore
    let modelSwitcher: ModelSwitchController
    let claudeStatus: ClaudeStatusViewModel
    let attentionNotifier: AttentionNotifier
    let claudeStates: ClaudeTabStateTracker
    /// Past prompts for ⌘K; reads nothing until the palette first opens.
    let promptHistory: PromptHistoryViewModel
    /// The Files / Changes drawer over the terminal; works only while open.
    let drawer = ProjectDrawerModel(isWindowVisible: { AppModel.isAnyWindowVisible })

    /// Where the configured `claude` is (ClaudeBinaryLocator). Looked up at
    /// launch, when Settings → Binary path changes and when the Doctor opens
    /// while it is missing - never per render.
    private(set) var doctorStatus: DoctorStatus = .checking
    @ObservationIgnored private var doctorTask: Task<Void, Never>?
    @ObservationIgnored private var lookedUpBinary: String?
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    /// A hook event lands in `tab-events/`: re-evaluate at once instead of
    /// on the next tick (App Nap stretches timers while Xylem is hidden).
    @ObservationIgnored private let tabEventsWatcher = FileSystemWatcher(debounceInterval: 0.15)

    /// View models are built here, on the main actor (default arguments
    /// would be evaluated outside it).
    init() {
        self.tabs = TabsViewModel()
        self.sessionList = SessionListViewModel()
        self.environment = ClaudeEnvironmentViewModel()
        self.gitStatus = GitStatusViewModel()
        self.sessionStats = SessionStatsViewModel()
        self.tabActivity = TabActivityViewModel()
        self.agentTeams = AgentTeamsStore()
        self.modelSwitcher = ModelSwitchController()
        self.claudeStatus = ClaudeStatusViewModel()
        let notifier = AttentionNotifier()
        self.attentionNotifier = notifier
        self.claudeStates = ClaudeTabStateTracker(notifier: notifier)
        self.promptHistory = PromptHistoryViewModel()
        claudeStates.onBindingChange = { [weak tabs] in tabs?.sessionBindingChanged() }
        notifier.onOpenTab = { [weak self] id in self?.selectTab(id) }
    }

    // MARK: - Active context

    var activeSession: TerminalSession? { tabs.activeSession }
    var activeDirectory: String? { tabs.activeSession?.configuration.workingDirectory }
    /// The active tab's own transcript when it is bound to a session.
    var activeTranscript: URL? { tabs.activeTab?.transcriptURL }

    /// Call when the active tab or its directory changes. Independent
    /// loads run concurrently instead of queueing behind `git status`.
    func activeContextChanged() async {
        let directory = activeDirectory
        environment.reload(projectDirectory: directory)
        sessionList.setProjectDirectory(directory)
        drawer.setDirectory(directory)
        reloadAgentTeams()
        async let git: Void = gitStatus.refresh(for: directory, force: true)
        async let stats: Void = sessionStats.refresh(for: directory, transcript: activeTranscript)
        _ = await (git, stats)
    }

    /// Agent teams follow the panel scope: the project's teams, or all.
    func reloadAgentTeams() {
        agentTeams.reload(projectDirectory: environment.scope == .project ? activeDirectory : nil)
    }

    /// Manual "refresh everything" (sidebar button, command palette).
    func refreshSidebar() {
        ClaudeProjectPathResolver.clearCache()
        environment.reload(projectDirectory: environment.currentDirectory)
        sessionList.reload()
        reloadAgentTeams()
    }

    // MARK: - Polling

    /// First load of the global lists plus the shared poll. Idempotent.
    func start() {
        guard pollTask == nil else { return }
        refreshDoctor()
        observeBinarySetting()
        sessionList.reload()
        Task { [weak self] in await self?.claudeStatus.refresh() }
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                // Nothing on screen to update: skip the disk work. The next
                // tick after a window becomes visible catches up.
                guard Self.isAnyWindowVisible else { continue }
                tick += 1
                await self.tabActivity.refresh(for: self.tabs.tabs)
                // bash/fish tabs: follow `cd` (zsh reports it via OSC 7).
                for tab in self.tabs.tabs { tab.session?.pollWorkingDirectory() }
                if tick.isMultiple(of: 2) {
                    await self.sessionStats.refresh(for: self.activeDirectory, transcript: self.activeTranscript)
                    await self.sessionList.reloadIfNewestSessionMissing()
                }
                // status.claude.com once a minute (30 × 2 s).
                if tick.isMultiple(of: 30) {
                    await self.claudeStatus.refresh()
                }
            }
        }
        stateTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshClaudeStates()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        tabEventsWatcher.setHandler { [weak self] in
            Task { @MainActor in await self?.refreshClaudeStates() }
        }
        tabEventsWatcher.watch(paths: [ClaudeHookBridge.eventsDirectory.path])
    }

    func refreshClaudeStates() async {
        await claudeStates.refresh(tabs: tabs.tabs, activeTabID: tabs.activeTabID, appIsActive: NSApp.isActive)
    }

    /// Visible = on screen and not fully covered (occlusion), so a visible
    /// but non-key window keeps updating.
    private static var isAnyWindowVisible: Bool {
        guard !NSApp.isHidden else { return false }
        return NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
    }

    // MARK: - Session actions

    func switchModel(to choice: ClaudeModelChoice) {
        guard let session = activeSession, session.launchedClaude else { return }
        // Not in the account's plan: Claude Code would refuse `/model`.
        guard !claudeStates.unavailableModelFamilies.contains(choice.family) else { NSSound.beep(); return }
        modelSwitcher.switchModel(of: session, to: choice)
    }

    func switchEffort(to choice: ClaudeEffortChoice) {
        guard let session = activeSession, session.launchedClaude else { return }
        // The keys would answer Claude's question, or go nowhere.
        switch tabs.activeTab?.claudeState {
        case .needsInput, .notRunning: NSSound.beep(); return
        default: break
        }
        let version = tabs.activeTab?.liveStatus?.version ?? session.foregroundClaudeVersion
        guard EffortSupport.isAvailable(choice, version: version) else {
            Self.explainUnsupportedEffort(EffortSupport.explanation(for: choice, version: version))
            return
        }
        modelSwitcher.switchEffort(of: session, to: choice) { choice in
            Self.explainUnsupportedEffort(EffortSupport.explanation(for: choice, version: version))
        }
    }

    /// A sheet on the window (an app-modal alert without one).
    private static func explainUnsupportedEffort(_ text: (title: String, message: String)) {
        let alert = NSAlert()
        alert.messageText = text.title
        alert.informativeText = text.message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// The next tab after the active one (wrapping around) that waits for
    /// the user: its "waiting" mark is on, or Claude still asks for
    /// permission there. Selects it like a click; false (and a beep) when
    /// there is none.
    @discardableResult
    func selectNextWaitingTab() -> Bool {
        guard let id = TabsViewModel.nextWaitingTab(in: tabs.tabs, after: tabs.activeTabID) else {
            NSSound.beep()
            return false
        }
        selectTab(id)
        return true
    }

    /// A pick in the tab list. The list takes the keyboard on click, so the
    /// active terminal gets it back.
    func selectTab(_ id: TerminalTab.ID) {
        tabs.select(id)
        activeTabSeen()
        focusActiveTerminal()
    }

    /// The active tab is on screen: drop its "waiting" mark and its
    /// notification now rather than on the next state tick.
    func activeTabSeen() {
        guard let tab = tabs.activeTab else { return }
        claudeStates.markSeen(tab)
        attentionNotifier.withdraw(tabID: tab.id)
    }

    /// Gives the keyboard to the active terminal, deferred one turn so the
    /// tab list has finished handling the click - unless a text field (tab
    /// search, rename) holds it: then the user is typing there.
    func focusActiveTerminal() {
        DispatchQueue.main.async { [weak self] in
            guard let view = self?.activeSession?.terminalView,
                  let window = view.window, !view.isHidden
            else { return }
            if let editor = window.firstResponder as? NSTextView, !editor.isDescendant(of: view) {
                return
            }
            window.makeFirstResponder(view)
        }
    }

    // MARK: - Worktrees

    /// Where a new worktree tab branches from: the active tab's live cwd
    /// (it follows `cd`), when that is inside a repository.
    var worktreeBaseDirectory: String? {
        guard let tab = tabs.activeTab, tab.gitBranch != nil else { return nil }
        return tab.liveCwd
    }

    /// Creates a worktree for `branch` from the active tab's repository and
    /// opens a tab in it; throws git's message when it can't.
    func openWorktreeTab(branch: String) async throws {
        guard let base = worktreeBaseDirectory else {
            throw GitWorktreeCreator.Failure(message: "The active tab's folder is not in a git repository.")
        }
        let path = try await GitWorktreeCreator().create(branch: branch, from: base)
        selectTab(tabs.openDirectory(path).id)
    }

    /// A worktree row in the Git panel: its tab, or a new one.
    func openWorktree(at path: String) {
        selectTab(tabs.openDirectory(path).id)
    }

    func runInActiveSession(_ command: String) {
        activeSession?.runCommand(command)
    }

    /// Types `/goal ` into Claude's prompt WITHOUT Enter: the command needs
    /// the goal condition after it, which the user types next. Focus goes
    /// to the terminal so typing can continue right away.
    func startGoal() {
        guard let session = activeSession else { return }
        session.send(text: "/goal ")
        let view = session.terminalView
        view.window?.makeFirstResponder(view)
    }

    func copySelection() {
        guard let view = activeSession?.terminalView else { return }
        NSApp.sendAction(#selector(NSText.copy(_:)), to: view, from: nil)
    }

    /// Window screenshot to the clipboard. `screencapture` runs off the main
    /// actor, so `waitUntilExit` doesn't block the UI.
    func captureScreenshot() {
        Task { await Self.runScreencapture() }
    }

    @concurrent nonisolated
    private static func runScreencapture() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-c", "-o", "-x"]
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }

    /// Types a path, shell-quoted and followed by a space, into the active
    /// session (no Enter) and gives it the keyboard.
    func insertPath(_ path: String) {
        guard let session = activeSession else { return }
        guard session.insertPaths([path]) else { NSSound.beep(); return }
        focusActiveTerminal()
    }

    /// File > Open Folder… (⌘O from any tab): the folder opens in the empty
    /// tab, or the tab that already has it, or a new one (`openDirectory`).
    func openFolder() {
        guard let url = OpenPanels.pick(.projectFolder) else { return }
        tabs.openDirectory(url.path)
    }

    /// Lets the user pick a file and types its shell-quoted path into the
    /// active session.
    func attachFile(_ purpose: OpenPanels.Purpose = .file) {
        guard let url = OpenPanels.pick(purpose) else { return }
        // Same safe insertion as dropped files (a control character in a
        // file name would act as a key in the raw-mode terminal).
        // Exactly the text it always typed (no trailing space), refused when a
        // control character in the name would act as a key.
        if activeSession?.insertPaths([url.path], trailingSpace: false) == false { NSSound.beep() }
    }

    /// Runs a skill's install command in the active tab, or copies it when
    /// no session is open.
    func installSkill(_ skill: MarketplaceSkill) {
        if let session = activeSession {
            session.runCommand(skill.installCommand)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(skill.installCommand, forType: .string)
        }
    }

    /// A past prompt picked in ⌘K: resume its session (or switch to the
    /// tab that already has it). A transcript deleted since indexing is
    /// ignored rather than resumed into an empty `claude --resume` error.
    func openPromptSession(_ entry: PromptHistoryEntry) {
        guard FileManager.default.fileExists(atPath: entry.transcriptURL.path) else { return }
        // Through selectTab: marks the tab seen and gives the terminal the
        // keyboard, like a pick in the tab list.
        let tab = tabs.resumeSession(ClaudeSession(
            id: entry.sessionID,
            projectID: entry.transcriptURL.deletingLastPathComponent().lastPathComponent,
            projectPath: entry.projectPath,
            title: entry.sessionTitle,
            lastModified: entry.date ?? .now,
            fileURL: entry.transcriptURL
        ))
        selectTab(tab.id)
    }
}

// MARK: - Doctor

extension AppModel {
    /// Asks the login shell (off main) for its PATH and CLAUDE_CONFIG_DIR,
    /// then looks for the configured claude; a changed config folder
    /// reloads what was read from the old one. `onlyIfChanged` skips it
    /// when the setting is the value already looked up - UserDefaults
    /// reports a change of any key. `delay` lets typing in the Binary path
    /// field settle first.
    @discardableResult
    func refreshDoctor(onlyIfChanged: Bool = false, delay: Duration = .zero) -> Task<Void, Never>? {
        let configured = AppSettings.claudeBinaryPath
        if onlyIfChanged, configured == lookedUpBinary { return nil }
        lookedUpBinary = configured
        doctorTask?.cancel()
        let task = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            let shell = await LoginShellEnvironment.read()
            guard !Task.isCancelled, let self else { return }
            // Only a real answer moves the folder; a failed shell keeps it.
            if let shell, ClaudeConfigDirectory.apply(shellValue: shell.claudeConfigDirectory) {
                self.claudeConfigDirectoryChanged()
            }
            let location = ClaudeBinaryLocator.locate(configured: configured, shellPath: shell?.path)
            let status: DoctorStatus = switch location {
            case .found(let path):   .healthy(path: path)
            case .offPath(let path): .notOnPath(path: path)
            case nil:                .missing(configured: configured)
            }
            // The shell couldn't be asked (timeout): the install folders
            // alone would turn "not on PATH" into a false "fixed" and offer
            // to restart tabs that still can't run claude. Keep the known
            // answer until the shell replies.
            if shell == nil, case .notOnPath = self.doctorStatus, case .healthy = status { return }
            if self.doctorStatus != status { self.doctorStatus = status }
            // Which hook settings the next tabs get (StopFailure from 2.1.78).
            if case .found(let path) = location {
                let searchPath = shell?.path ?? ClaudeBinaryLocator.knownDirectories(
                    home: FileManager.default.homeDirectoryForCurrentUser.path)
                let version = await Task.detached {
                    ClaudeCLIVersion.read(executable: path, searchPath: searchPath)
                }.value
                guard !Task.isCancelled else { return }
                ClaudeCLIVersion.remember(version)
            }
        }
        doctorTask = task
        return task
    }

    /// Doctor's "Check Again": looks again and returns when it knows.
    func recheckDoctor() async {
        await refreshDoctor()?.value
    }

    /// CLAUDE_CONFIG_DIR changed since the last launch (rare): everything
    /// read from the old folder is read again; tabs look their transcripts
    /// up per read.
    private func claudeConfigDirectoryChanged() {
        refreshSidebar()
        Task { await activeContextChanged() }
    }

    /// The Doctor popover opened: claude may have been installed (or PATH
    /// fixed) since.
    func doctorOpened() {
        if doctorStatus.isBroken { refreshDoctor() }
    }

    /// Settings → Binary path edits re-check the Doctor.
    func observeBinarySetting() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.refreshDoctor(onlyIfChanged: true, delay: .milliseconds(600))
            }
        }
        // Back from Terminal after pasting the Doctor's PATH fix: a red
        // Doctor looks again by itself. One login shell per activation,
        // only while broken.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.doctorStatus.isBroken else { return }
                self.refreshDoctor()
            }
        }
    }

    /// Tabs whose claude couldn't start (or has exited): after a Doctor
    /// fix they need a new shell to see the new PATH.
    var tabsWithoutClaudeCount: Int { tabs.tabsWithoutClaude().count }

    func restartTabsWithoutClaude() {
        for tab in tabs.tabsWithoutClaude() { tabs.restartClaude(in: tab.id) }
        focusActiveTerminal()
    }
}
