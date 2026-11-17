//
//  GitStatusViewModel.swift
//  Xylem
//
//  Observable facade that refreshes git status for the active directory.
//  A file-system watcher observes `.git/HEAD`, `.git/index`, and the working
//  tree so commits, checkouts, and working-copy edits show up without a
//  manual refresh.
//
//  Only works while the Git panel is visible (`setVisible`).
//
//  Watcher-driven refreshes are coalesced (at most one per
//  `watcherRefreshInterval`, never two at once) and silent - they don't
//  flip `isLoading`, and `status` is only assigned when it changed.
//

import Foundation
import Observation

@Observable
final class GitStatusViewModel {
    private(set) var status: GitStatus?
    private(set) var isLoading = false
    private(set) var currentDirectory: String?

    private let repository: GitRepositoryReading
    private let watcher = FileSystemWatcher()

    /// Minimum spacing between two watcher-triggered refreshes. Claude edits
    /// files in bursts; one `git status` round (seven processes) per burst
    /// window is plenty for a sidebar.
    private let watcherRefreshInterval: Duration = .seconds(5)
    @ObservationIgnored private var pendingWatcherRefresh: Task<Void, Never>?
    /// True while the scheduled watcher refresh is already running git; an
    /// event that lands then may postdate what git saw, so it earns one more
    /// round afterwards.
    @ObservationIgnored private var watcherLoadRunning = false
    @ObservationIgnored private var watcherEventDuringLoad = false
    @ObservationIgnored private var lastRefreshFinished: ContinuousClock.Instant?
    /// Bumped on every refresh; a result is applied only if it belongs to
    /// the newest one.
    @ObservationIgnored private var generation = 0
    /// Git runs only while the Git tab is on screen: a refresh for a hidden
    /// panel just records the directory (seven git processes per tab switch
    /// were spent on a panel nobody was looking at).
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var requestedDirectory: String?

    init(repository: GitRepositoryReading = GitRepository()) {
        self.repository = repository
        watcher.setHandler { [weak self] in
            let target = self
            Task { @MainActor in
                target?.scheduleWatcherRefresh()
            }
        }
    }

    /// Shows or hides the Git panel. Becoming visible loads the latest
    /// requested directory; hiding stops the file watcher.
    func setVisible(_ visible: Bool) async {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            await refresh(for: requestedDirectory, force: true)
        } else {
            // A load still in flight must not re-arm the watcher afterwards.
            generation += 1
            if isLoading { isLoading = false }
            pendingWatcherRefresh?.cancel()
            pendingWatcherRefresh = nil
            watcher.watch(paths: [])
        }
    }

    func refresh(for directory: String?, force: Bool = false) async {
        requestedDirectory = directory
        guard isVisible else { return }
        guard let directory else {
            generation += 1
            if status != nil { status = nil }
            if currentDirectory != nil { currentDirectory = nil }
            if isLoading { isLoading = false }
            watcher.watch(paths: [])
            return
        }
        if !force, directory == currentDirectory, status != nil, !isLoading { return }
        if !isLoading { isLoading = true }
        await load(directory, generation: nextGeneration())
    }

    // MARK: - Private

    private func nextGeneration() -> Int {
        generation += 1
        return generation
    }

    private func load(_ directory: String, generation token: Int) async {
        if currentDirectory != directory { currentDirectory = directory }
        let fresh = await repository.status(in: directory)
        guard token == generation else { return }
        lastRefreshFinished = .now
        if status != fresh { status = fresh }
        if isLoading { isLoading = false }
        watcher.watch(paths: watchPaths(for: directory))
    }

    private func scheduleWatcherRefresh() {
        guard isVisible, currentDirectory != nil else { return }
        if pendingWatcherRefresh != nil {
            // A refresh that is still sleeping will see this change anyway.
            if watcherLoadRunning { watcherEventDuringLoad = true }
            return
        }
        let delay: Duration
        if let lastRefreshFinished {
            let elapsed = ContinuousClock.now - lastRefreshFinished
            delay = elapsed >= watcherRefreshInterval ? .zero : watcherRefreshInterval - elapsed
        } else {
            delay = .zero
        }
        pendingWatcherRefresh = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self else { return }
            guard !Task.isCancelled, let directory = self.currentDirectory else {
                self.pendingWatcherRefresh = nil
                return
            }
            self.watcherLoadRunning = true
            await self.load(directory, generation: self.nextGeneration())
            self.watcherLoadRunning = false
            self.pendingWatcherRefresh = nil
            if self.watcherEventDuringLoad {
                self.watcherEventDuringLoad = false
                self.scheduleWatcherRefresh()
            }
        }
    }

    private func watchPaths(for directory: String) -> [String] {
        let gitDir = directory + "/.git"
        let candidates = [
            gitDir + "/HEAD",
            gitDir + "/index",
            gitDir + "/refs/heads",
            gitDir + "/packed-refs",
            directory
        ]
        let fm = FileManager.default
        return candidates.filter { fm.fileExists(atPath: $0) }
    }
}
