//
//  ProjectDrawerModel.swift
//  Xylem
//
//  State of the drawer that lies over the terminal, opened from the panel rail:
//  Files (the active tab's project tree + a read-only preview) and Changes
//  (git's changed files + the diff of the selected one). Disk and git work
//  runs off main; while the drawer is open it refreshes every 3 s (only
//  folders that are expanded, one `git status`), and stops when closed.
//

import Foundation
import Observation

@MainActor
@Observable
final class ProjectDrawerModel {
    enum Mode: String, Sendable { case files, changes }

    /// Open drawer, nil = closed.
    private(set) var mode: Mode?
    /// The project folder the drawer shows (the active tab's).
    private(set) var directory: String?

    // Files
    private(set) var listings: [String: ProjectDirectoryReader.Listing] = [:]
    private(set) var expanded: Set<String> = []
    private(set) var selectedFile: String?
    private(set) var preview: FilePreview?
    /// Syntax colours for `preview`'s lines (nil until ready, or never for
    /// an unknown language): the plain text shows first.
    private(set) var previewColours: [[SyntaxRun]]?

    // Changes
    /// nil: not a git repository (or not loaded yet - see `changesLoaded`).
    private(set) var changes: GitChangesLoader.Snapshot?
    private(set) var changesLoaded = false
    private(set) var selectedChange: GitFileChange?
    private(set) var diff: DiffDocument?
    /// Syntax colours for `diff`'s lines by `DiffLine.id`.
    private(set) var diffColours: [Int: [SyntaxRun]]?
    /// Folders folded in the Changes tree (all start open).
    private(set) var collapsedChangeFolders: Set<String> = []

    /// Whether a window shows the drawer; the refresh pauses otherwise.
    /// Injected (AppModel passes its occlusion check; tests: always).
    @ObservationIgnored private let isWindowVisible: () -> Bool

    init(isWindowVisible: @escaping () -> Bool = { true }) {
        self.isWindowVisible = isWindowVisible
    }

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var diffTask: Task<Void, Never>?
    @ObservationIgnored private var previewColourTask: Task<Void, Never>?
    /// The previewed / diffed file's stat when it was last read: the 3 s
    /// refresh re-reads a file (up to 1 MB) or re-runs `git diff` only when
    /// this changed - re-reading a big file every pass cost ~3% CPU.
    @ObservationIgnored private var previewStamp: FileStamp?
    @ObservationIgnored private var diffStamp: FileStamp?
    @ObservationIgnored private var diffLoadingPath: String?
    /// Folders' stats when last listed: unchanged ones aren't re-listed.
    @ObservationIgnored private var listingStamps: [String: FileStamp] = [:]
    @ObservationIgnored private var diffColourTask: Task<Void, Never>?

    /// Rows the tree shows, in order: the expanded folders' children,
    /// depth for the indent.
    var visibleRows: [(entry: ProjectFileEntry, depth: Int)] {
        guard let directory else { return [] }
        var rows: [(ProjectFileEntry, Int)] = []
        func add(_ folder: String, depth: Int) {
            for entry in listings[folder]?.entries ?? [] {
                rows.append((entry, depth))
                if entry.isDirectory, expanded.contains(entry.path) { add(entry.path, depth: depth + 1) }
            }
        }
        add(directory, depth: 0)
        return rows
    }

    /// Changed files by the tree's own paths, to colour it. git reports the
    /// repository's resolved root (`/private/tmp/…`) while the tree lists
    /// the tab's folder as spelled (`/tmp/…`): both are resolved, and the
    /// keys rebuilt under the tree's spelling.
    var changeKinds: [String: GitFileChange.Kind] {
        guard let changes, let directory, let resolvedDirectory else { return [:] }
        let root = (changes.root as NSString).resolvingSymlinksInPath
        var kinds: [String: GitFileChange.Kind] = [:]
        for change in changes.changes {
            let resolved = (root as NSString).appendingPathComponent(change.path)
            guard resolved == resolvedDirectory || resolved.hasPrefix(resolvedDirectory + "/") else { continue }
            kinds[directory + resolved.dropFirst(resolvedDirectory.count)] = change.kind
        }
        return kinds
    }

    /// `directory` with symlinks resolved, set with it.
    @ObservationIgnored private var resolvedDirectory: String?

    // MARK: - Opening and closing

    /// The rail button: opens `mode`, or closes the drawer when it is
    /// already showing it.
    func toggle(_ mode: Mode, directory: String?) {
        // A second click while the drawer is still loading closes it too.
        if self.mode == mode || (self.mode == nil && openingMode == mode) { close() } else { open(mode, directory: directory) }
    }

    func open(_ mode: Mode, directory: String?) {
        setDirectory(directory)
        guard self.mode == nil else {
            // Already open: just switch what it shows.
            self.mode = mode
            startRefreshing()
            return
        }
        // Load first, then show: a drawer that appears empty and fills up a
        // moment later looked jerky. A slow repository doesn't hold
        // it back for more than 150 ms; the rest arrives a moment later.
        opening?.cancel()
        openingMode = mode
        opening = Task { [weak self] in
            guard let self else { return }
            var loaded = false
            await withTaskGroup(of: Bool.self) { group in
                group.addTask { await self.refreshOnce(for: mode); return true }
                group.addTask { try? await Task.sleep(for: .milliseconds(150)); return false }
                loaded = await group.next() ?? false
                group.cancelAll()
            }
            guard !Task.isCancelled else { return }
            self.openingMode = nil
            self.mode = mode
            // The first pass just ran (or is still finishing): don't start a
            // second one straight away.
            self.startRefreshing(firstPassAfter: loaded ? .seconds(3) : .seconds(1))
        }
    }

    @ObservationIgnored private var opening: Task<Void, Never>?
    @ObservationIgnored private var openingMode: Mode?

    func close() {
        // Called on every panel show: nothing to do when already closed
        // (assigning nil again would re-render the rail for nothing).
        guard mode != nil || opening != nil else { return }
        opening?.cancel()
        opening = nil
        openingMode = nil
        mode = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// The active tab changed: show its project. A tab without one (a new
    /// tab still waiting for a folder) closes the drawer - it has nothing to
    /// show and would lie over the New Tab screen.
    func setDirectory(_ directory: String?) {
        guard directory != self.directory else { return }
        self.directory = directory
        resolvedDirectory = directory.map { ($0 as NSString).resolvingSymlinksInPath }
        listingStamps = [:]
        listings = [:]
        expanded = []
        selectedFile = nil
        setPreview(nil, for: nil)
        changes = nil
        changesLoaded = false
        selectedChange = nil
        setDiff(nil, for: nil)
        collapsedChangeFolders = []
        if directory == nil { close(); return }
        if mode != nil { startRefreshing() }
    }

    // MARK: - Files

    func toggleFolder(_ path: String) {
        if expanded.contains(path) {
            expanded.remove(path)
        } else {
            expanded.insert(path)
            if listings[path] == nil { Task { await reloadListings([path]) } }
        }
    }

    func selectFile(_ path: String) {
        selectedFile = path
        setPreview(nil, for: nil)
        previewTask?.cancel()
        previewTask = Task {
            let stamp = await Self.stamp(path)
            let loaded = await Self.loadPreview(path)
            guard !Task.isCancelled, selectedFile == path else { return }
            previewStamp = stamp
            setPreview(loaded, for: path)
        }
    }

    /// New preview text: colour it in the background. Unchanged text keeps
    /// its colours (the 3 s refresh re-reads the file).
    private func setPreview(_ loaded: FilePreview?, for path: String?) {
        guard loaded != preview || loaded == nil else { return }
        preview = loaded
        previewColours = nil
        previewColourTask?.cancel()
        guard case .text(let lines, _)? = loaded, let path, let language = SyntaxHighlighter.language(forFile: path) else { return }
        previewColourTask = Task {
            let colours = await Self.colour(lines.joined(separator: "\n"), language: language)
            guard !Task.isCancelled, selectedFile == path, preview == loaded, colours?.count == lines.count else { return }
            previewColours = colours
        }
    }

    // MARK: - Changes

    /// The Changes list as a folder tree.
    var changeRows: [ChangeTree.Row] {
        ChangeTree.rows(changes?.changes ?? [], collapsed: collapsedChangeFolders)
    }

    func toggleChangeFolder(_ path: String) {
        if collapsedChangeFolders.contains(path) { collapsedChangeFolders.remove(path) } else { collapsedChangeFolders.insert(path) }
    }

    func selectChange(_ change: GitFileChange) {
        selectedChange = change
        setDiff(nil, for: nil)
        diffLoadingPath = nil   // a new pick always loads
        loadDiff(for: change)
    }

    private func loadDiff(for change: GitFileChange) {
        guard let root = changes?.root else { return }
        // Already loading this file: let it finish (restarting it every
        // pass meant a diff slower than 3 s never arrived).
        if diffLoadingPath == change.path, diffTask != nil { return }
        diffTask?.cancel()
        diffLoadingPath = change.path
        diffTask = Task {
            defer { if diffLoadingPath == change.path { diffLoadingPath = nil; diffTask = nil } }
            let stamp = await Self.stamp((root as NSString).appendingPathComponent(change.path))
            let document = await Self.loadDiff(change, root: root)
            guard !Task.isCancelled, selectedChange?.path == change.path else { return }
            diffStamp = stamp
            setDiff(document, for: change.path)
        }
    }

    /// New diff: colour it in the background; an unchanged one keeps its colours.
    private func setDiff(_ document: DiffDocument?, for path: String?) {
        guard document != diff || document == nil else { return }
        diff = document
        diffColours = nil
        diffColourTask?.cancel()
        guard let document, let path, let language = SyntaxHighlighter.language(forFile: path) else { return }
        diffColourTask = Task {
            let colours = await Self.colour(document, language: language)
            guard !Task.isCancelled, selectedChange?.path == path, diff == document else { return }
            diffColours = colours
        }
    }

    // MARK: - Refresh loop

    private func startRefreshing(firstPassAfter delay: Duration = .zero) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            while !Task.isCancelled {
                // Nothing on screen: no disk or git work (like AppModel's loop).
                let started = ContinuousClock.now
                if self?.isWindowVisible() ?? false { await self?.refreshOnce() }
                // A slow pass (a home folder that is a dotfiles repository:
                // `git status` walks the whole home) waits twice as long as
                // it took, so git doesn't run back to back.
                try? await Task.sleep(for: Self.pause(after: ContinuousClock.now - started))
            }
        }
    }

    /// Between two refresh passes: 3 s, or twice the last pass when it was slow.
    nonisolated static func pause(after pass: Duration) -> Duration {
        max(.seconds(3), pass * 2)
    }

    /// One pass: the root and expanded folders, then git (the tree uses
    /// git's state for its colours in both modes).
    func refreshOnce() async {
        await refreshOnce(for: mode)
    }

    /// `forMode`: the mode being opened (before `mode` is set).
    func refreshOnce(for forMode: Mode?) async {
        guard let directory, forMode != nil else { return }
        await reloadListings([directory] + expanded.sorted())
        guard self.directory == directory else { return }
        let snapshot = await Self.loadChanges(directory)
        guard self.directory == directory else { return }
        if snapshot != changes { changes = snapshot }
        changesLoaded = true
        // The selected file: re-read its diff (one file, cheap; it can
        // change without its line counts changing). Gone from the list
        // (committed, reverted): clear it.
        if forMode == .changes, let selected = selectedChange {
            if let updated = snapshot?.changes.first(where: { $0.path == selected.path }) {
                // Re-diff only when git's view of it or the file itself changed.
                let stamp = await Self.stamp((snapshot!.root as NSString).appendingPathComponent(updated.path))
                if updated != selected || stamp != diffStamp {
                    selectedChange = updated
                    loadDiff(for: updated)
                }
            } else {
                selectedChange = nil
                setDiff(nil, for: nil)
            }
        }
        // A previewed file that changed on disk: show the new text.
        if forMode == .files, let file = selectedFile {
            let stamp = await Self.stamp(file)
            if stamp != previewStamp {
                let loaded = await Self.loadPreview(file)
                if selectedFile == file {
                    previewStamp = stamp
                    if loaded != preview { setPreview(loaded, for: file) }
                }
            }
        }
    }

    private func reloadListings(_ folders: [String]) async {
        let known = listingStamps.filter { listings[$0.key] != nil }
        let loaded = await Self.list(folders, known: known)
        for (folder, result) in loaded {
            listingStamps[folder] = result.stamp
            if let listing = result.listing, listings[folder] != listing { listings[folder] = listing }
        }
        // An expanded folder that is gone: collapse it.
        for folder in folders where loaded[folder] == nil {
            expanded.remove(folder)
            listingStamps[folder] = nil
        }
    }

    // MARK: - Off-main work

    /// Each folder's stat, and its listing when the stat differs from
    /// `known` (a folder's mtime changes when entries are added, removed or
    /// renamed). Missing folders are left out.
    @concurrent nonisolated private static func list(
        _ folders: [String], known: [String: FileStamp]
    ) async -> [String: (stamp: FileStamp, listing: ProjectDirectoryReader.Listing?)] {
        var result: [String: (stamp: FileStamp, listing: ProjectDirectoryReader.Listing?)] = [:]
        for folder in folders {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue,
                  let stamp = FileStamp(url: URL(fileURLWithPath: folder)) else { continue }
            result[folder] = (stamp, known[folder] == stamp ? nil : ProjectDirectoryReader.list(folder))
        }
        return result
    }

    @concurrent nonisolated private static func loadPreview(_ path: String) async -> FilePreview {
        FilePreview.Loader.load(path)
    }

    @concurrent nonisolated private static func colour(_ text: String, language: String) async -> [[SyntaxRun]]? {
        await SyntaxHighlighter.highlight(text, language: language)
    }

    @concurrent nonisolated private static func colour(_ document: DiffDocument, language: String) async -> [Int: [SyntaxRun]] {
        await DiffSyntax.highlight(document, language: language)
    }

    /// size + mtime + inode of a file, nil when it is gone.
    @concurrent nonisolated private static func stamp(_ path: String) async -> FileStamp? {
        FileStamp(url: URL(fileURLWithPath: path))
    }

    @concurrent nonisolated private static func loadChanges(_ directory: String) async -> GitChangesLoader.Snapshot? {
        await GitChangesLoader.load(in: directory)
    }

    @concurrent nonisolated private static func loadDiff(_ change: GitFileChange, root: String) async -> DiffDocument {
        await GitChangesLoader.diff(of: change, root: root)
    }
}
