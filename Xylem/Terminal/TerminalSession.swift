//
//  TerminalSession.swift
//  Xylem
//
//  A live pty session bound to a running shell. Owns the SwiftTerm NSView,
//  which is reused across tab switches so state (scrollback, running
//  processes) persists. All input/output actions go through this type -
//  views never poke the NSView directly. `close()` is the one teardown
//  path: removing a tab must kill its shell explicitly, ARC alone doesn't
//  guarantee the pty child goes away.
//

import Foundation
import AppKit
import SwiftTerm
import Observation

@Observable
final class TerminalSession: Identifiable {
    let id: UUID
    var title: String
    /// Fixed once the shell starts; before that `replaceLaunch` may swap
    /// the first command (a restored session that is open elsewhere).
    private(set) var configuration: ShellConfiguration
    let createdAt: Date
    /// When the shell (and the tab's claude) actually started; nil while
    /// the session waits to be opened (`startsImmediately: false`). Hook
    /// events older than this belong to an earlier claude.
    private(set) var startedAt: Date?
    var isStarted: Bool { startedAt != nil }
    /// The Claude session the shell's first `claude` writes to
    /// (`--session-id` / `--resume`); nil for a bare shell.
    private(set) var claudeSessionID: String?

    // Stable reference - kept alive for the whole lifetime of the session.
    let terminalView: LocalProcessTerminalView
    private let processDelegate = TerminalProcessCoordinator()
    /// Output/input timing for the tab's Claude state (ClaudeTabState).
    let activity = TerminalActivityMonitor()
    private var appearanceObserver: NSObjectProtocol?

    /// Latest cwd reported by the shell via OSC 7. Starts at the configured
    /// working directory, then follows `cd` as the user types. Observable so
    /// the tab title can track it without polling. The zdotdir hook emits
    /// OSC 7 on *every* prompt, so writes are equality-guarded - an
    /// unconditional assignment re-rendered the tab card on each Enter.
    private(set) var reportedDirectory: String?

    /// Scrollback kept per terminal. SwiftTerm defaults to 500 lines, which
    /// a single long Claude answer overflows; 10k keeps a working session's
    /// history at a few MB per tab.
    static let scrollbackLines = 10_000

    /// zsh reports its cwd itself (OSC 7 from our `.zshenv`); other shells
    /// (bash, fish) get no hook from us, so `pollWorkingDirectory` follows
    /// them. Decided once - the shell never changes.
    @ObservationIgnored private let reportsDirectoryItself: Bool

    /// Set by `close()`; makes teardown idempotent.
    @ObservationIgnored private(set) var isClosed = false

    init(
        id: UUID = UUID(),
        title: String,
        configuration: ShellConfiguration,
        claudeSessionID: String? = nil,
        startsImmediately: Bool = true
    ) {
        self.id = id
        self.title = title
        self.configuration = configuration
        self.claudeSessionID = claudeSessionID
        self.reportsDirectoryItself = configuration.executablePath.hasSuffix("/zsh")
        self.createdAt = Date()
        let view = XylemTerminalView(frame: .zero)
        view.activityMonitor = activity
        self.terminalView = view
        self.terminalView.processDelegate = processDelegate
        processDelegate.activityMonitor = activity
        // Runs on SwiftTerm's I/O thread for every output batch.
        let monitor = activity
        let lastOutput = self.lastOutput
        self.terminalView.setProcessOutputHandler {
            monitor.noteOutput()
            lastOutput.mark()
        }
        self.reportedDirectory = configuration.workingDirectory
        processDelegate.onDirectoryChange = { [weak self] dir in
            Task { @MainActor in
                // OSC 7 payload is a file:// URL; strip the scheme so the
                // value matches `configuration.workingDirectory` shape.
                guard let self, let dir else { return }
                let path = Self.pathFromOSC7(dir)
                if self.reportedDirectory != path {
                    self.reportedDirectory = path
                }
            }
        }
        configureTerminal()
        applyCurrentAppearance()
        observeAppearanceChanges()
        if startsImmediately { start() }
    }

    /// Starts the shell (and the claude it runs first) unless it already
    /// runs. Restored tabs wait for this until the user opens them, so a
    /// relaunch with many tabs doesn't load every session at once.
    func start() {
        guard startedAt == nil, !isClosed else { return }
        startedAt = Date()
        startProcess()
        watchStartup()
    }

    // MARK: - Starting (the loader over a fresh terminal)

    /// From start until the program has drawn its first screen
    /// (`TerminalStartup`): the tab shows a loader instead of a blank
    /// terminal (a login shell and claude take a second or two).
    private(set) var isStarting = false
    /// Time of the newest output batch, set from SwiftTerm's I/O thread.
    @ObservationIgnored private let lastOutput = LastOutput()
    @ObservationIgnored private var startupWatch: Task<Void, Never>?

    /// claude's first screen turns these on; read without copying rows.
    private var claudeTookTheTerminal: Bool {
        guard let input = terminalView.terminalInputStateSnapshot() else { return false }
        return !input.keyboardEnhancementFlags.isEmpty || input.bracketedPasteMode
    }

    private func watchStartup() {
        isStarting = true
        let began = Date()
        startupWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !self.isClosed else { return }
                let now = Date()
                let finished = TerminalStartup.isFinished(
                    launchesClaude: self.launchedClaude,
                    claudeTookTheTerminal: self.claudeTookTheTerminal,
                    quietSinceOutput: self.lastOutput.value.map { now.timeIntervalSince($0) },
                    typed: (self.activity.snapshot().lastInput ?? .distantPast) > began,
                    processRunning: self.terminalView.process?.running ?? false,
                    elapsed: now.timeIntervalSince(began)
                )
                if finished {
                    // One more frame so the first screen is drawn under it.
                    try? await Task.sleep(for: .milliseconds(120))
                    self.isStarting = false
                    return
                }
            }
        }
    }


    /// For shells without the OSC 7 hook: takes the cwd of whatever runs in
    /// the foreground of the terminal (the shell at its prompt, or claude)
    /// - a few syscalls, called from the shared 2 s poll.
    func pollWorkingDirectory() {
        guard isStarted, !isClosed, !reportsDirectoryItself, let process = terminalView.process else { return }
        let foreground = tcgetpgrp(process.childfd)
        let pid = foreground > 0 ? foreground : process.shellPid
        guard pid > 0, let path = Self.currentDirectory(of: pid), reportedDirectory != path else { return }
        reportedDirectory = path
    }

    /// The terminal's foreground program is a shell at its prompt, so the
    /// claude it started has exited (Doctor: a tab that answered "No, exit"
    /// at the trust question has no hook events to expect).
    var shellIsInForeground: Bool { Self.isShell(foregroundProcessName) }

    /// Process group in the terminal's foreground (claude, or the shell at
    /// its prompt); nil when not started or closed.
    var foregroundProcessGroup: pid_t? {
        guard isStarted, !isClosed, let process = terminalView.process else { return nil }
        let group = tcgetpgrp(process.childfd)
        return group > 0 ? group : nil
    }

    /// Name of the program in the terminal's foreground ("zsh", "claude").
    var foregroundProcessName: String? {
        guard isStarted, !isClosed, let process = terminalView.process else { return nil }
        let pid = tcgetpgrp(process.childfd)
        return pid > 0 ? Self.processName(pid) : nil
    }

    nonisolated static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// "zsh", "-zsh", "bash", "fish"… (a login shell's name may start with "-").
    nonisolated static func isShell(_ name: String?) -> Bool {
        guard var name else { return false }
        if name.hasPrefix("-") { name.removeFirst() }
        return ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "xonsh", "elvish"].contains(name)
    }

    nonisolated static func currentDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// Runs `command` (writing to `sessionID`) instead of the configured
    /// first command. Only before `start()`; ignored after.
    func replaceLaunch(command: [String], sessionID: String) {
        guard startedAt == nil, !isClosed else { return }
        configuration = configuration.replacingInitialCommand(command)
        claudeSessionID = sessionID
    }

    /// `file://<host><path>` -> `<path>`. Parsed by hand, not with
    /// `URL(string:)`: our zsh hook sends `$PWD` as is (only `%` encoded),
    /// and a URL parser read a `#` or `?` in a folder name as a fragment or
    /// query and cut the path there, decoded a literal `%41`, and differs
    /// between macOS versions on raw non-ASCII. Percent escapes from other
    /// OSC 7 senders (fully encoded) still decode.
    nonisolated static func pathFromOSC7(_ raw: String) -> String {
        guard raw.hasPrefix("file://") else { return raw }
        let afterScheme = raw.dropFirst("file://".count)
        // The host runs up to the first "/" (empty for `file:///path`).
        guard let slash = afterScheme.firstIndex(of: "/") else { return raw }
        let path = String(afterScheme[slash...])
        return path.removingPercentEncoding ?? path
    }

    deinit {
        if let observer = appearanceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Input actions

    /// Counts as input for the Claude state (it bypasses the view's
    /// `send(source:data:)`, see XylemTerminalView).
    func send(text: String) {
        activity.noteInput()
        terminalView.send(txt: text)
    }

    /// Types file paths, shell-quoted. False when a path holds a control
    /// character and nothing was typed (see `XylemTerminalView.pathInsertion`).
    @discardableResult
    func insertPaths(_ paths: [String], trailingSpace: Bool = true) -> Bool {
        guard let text = XylemTerminalView.pathInsertion(paths, trailingSpace: trailingSpace) else { return false }
        send(text: text)
        return true
    }

    /// Ctrl+L - ask the shell to redraw (clear for most interactive apps).
    func clearScreen() {
        send(text: "\u{0C}")
    }

    /// Ctrl+C - interrupt the foreground process.
    func interrupt() {
        send(text: "\u{03}")
    }

    /// Sends a command as if typed and pressed Enter. Uses CR (`\r`) rather
    /// than LF - Claude Code (and most TUIs running in raw mode) treat CR
    /// as the Enter keystroke; LF on its own gets buffered and never
    /// submits, which made the toolbar buttons feel "broken".
    func runCommand(_ command: String) {
        // A control character would act as a key in a raw-mode program
        // (Return, Esc, Ctrl-U), like in a dropped path.
        guard !XylemTerminalView.containsControlCharacter(command) else { NSSound.beep(); return }
        send(text: command + "\r")
    }

    // MARK: - Find in scrollback

    // Backed by SwiftTerm's own find bar (`TerminalFindBarView`, a subview
    // of the terminal): it owns the query, the case/regex options, match
    // highlighting and Esc-to-close, and shares the term through the system
    // find pasteboard. These wrappers only route the menu/palette commands
    // to it. SwiftTerm's `performTextFinderAction` ignores any sender that
    // isn't an NSMenuItem (it reads the action from `tag`), hence the
    // throwaway menu items.

    func showSearchBar() {
        performTextFinderAction(.showFindInterface)
    }

    /// Returns whether there was a term to search for (the bar's query or
    /// the find pasteboard). Hit/miss feedback lives in SwiftTerm's bar;
    /// its `performFind` doesn't report it back.
    @discardableResult
    func findNext() -> Bool {
        performTextFinderAction(.nextMatch)
    }

    /// See `findNext()` for what the result means.
    @discardableResult
    func findPrevious() -> Bool {
        performTextFinderAction(.previousMatch)
    }

    @discardableResult
    private func performTextFinderAction(_ action: NSTextFinder.Action) -> Bool {
        let item = NSMenuItem()
        item.tag = action.rawValue
        let hasTerm: Bool
        switch action {
        case .nextMatch, .previousMatch:
            // Same fallback SwiftTerm uses when its bar is closed.
            hasTerm = NSPasteboard(name: .find).string(forType: .string)?.isEmpty == false
        default:
            hasTerm = true
        }
        terminalView.performTextFinderAction(item)
        return hasTerm
    }

    // MARK: - Lifecycle

    /// Kills the shell and releases the view's UI resources. Called by
    /// TabsViewModel for every tab it drops (close, close others, state
    /// replaced). Idempotent.
    ///
    /// SIGHUP comes first because it is what actually ends the session:
    /// SwiftTerm's `terminate()` only sends SIGTERM, which an interactive
    /// zsh ignores (verified: `zsh -i` in a pty survives `kill -TERM`, dies
    /// on `kill -HUP` and HUPs its foreground job - claude - on the way
    /// out). That is also what a real terminal does when a window closes.
    /// SIGKILL escalation exists only in `LocalProcess.deinit`, which is
    /// why relying on ARC is not enough. `terminate()` still runs so
    /// SwiftTerm's own state machine moves to `.terminating`.
    func close() {
        guard !isClosed else { return }
        // Read before `isClosed`: the program in front (claude, or whatever
        // the user ran) and the shell's own group.
        let groups = [foregroundProcessGroup, terminalView.process.map { $0.shellPid }]
            .compactMap { $0 }
        isClosed = true
        startupWatch?.cancel()
        startupWatch = nil
        isStarting = false
        if let observer = appearanceObserver {
            NotificationCenter.default.removeObserver(observer)
            appearanceObserver = nil
        }
        // `shellPid` is 0 once the child has exited; `kill(0, …)` would
        // signal our own process group, so the guard is load-bearing.
        terminalView.setProcessOutputHandler(nil)
        let pid = terminalView.process?.shellPid ?? 0
        if pid > 0 {
            kill(pid, SIGHUP)
        }
        terminalView.terminate()
        Self.endProcessGroups(groups)
        Self.shutDownUI(of: terminalView, attemptsLeft: 10)
        // A full reset (RIS) replaces the buffers, scrollback included (up to
        // 10 000 lines). Something may still hold this closed session for a
        // while - SwiftUI keeps closed tab rows cached - and then it holds an
        // empty terminal, not the whole conversation.
        terminalView.feed(text: "\u{1b}c")
    }

    /// A closed tab's programs end even when they ignore SIGHUP and SIGTERM.
    /// Each group gets SIGHUP, as a closed terminal sends, and whatever is
    /// still alive after a grace period gets SIGKILL (5 s: claude's SessionEnd
    /// hook and its last transcript write run after the SIGHUP). Never our own
    /// group, never pid 0 or 1 (`kill(-0, …)` / `kill(-1, …)` would reach far
    /// more).
    nonisolated static func endProcessGroups(_ groups: [pid_t], grace: TimeInterval = 5) {
        let ours = getpgrp()
        let targets = Array(Set(groups.filter { $0 > 1 && $0 != ours }))
        guard !targets.isEmpty else { return }
        for group in targets { kill(-group, SIGHUP) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            for group in targets where kill(-group, 0) == 0 {
                kill(-group, SIGKILL)
            }
        }
    }

    /// `updateUiClosed()` returns false while committed GPU work is still in
    /// flight and asks the caller to retry, so poll a few times.
    private static func shutDownUI(of view: LocalProcessTerminalView, attemptsLeft: Int) {
        guard !view.updateUiClosed(), attemptsLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            shutDownUI(of: view, attemptsLeft: attemptsLeft - 1)
        }
    }

    /// The script runner for `startProcess` (see there). SIP-protected,
    /// present on every macOS.
    nonisolated static let launcherPath = "/bin/bash"
    nonisolated static let launcherArguments = ["--posix", "-c"]

    private func startProcess() {
        // `LocalProcessTerminalView.startProcess` has no working-directory
        // argument, so we launch the login shell via a small bash script
        // which changes directory first and then execs the user's shell.
        // bash's `exec -a` gives us control over argv[0] so the child
        // process looks like a real login shell (argv[0] starts with '-').
        // `/bin/bash --posix`, not `/bin/sh`: /bin/sh follows
        // /private/var/select/sh, and pointed at dash (supported since
        // 10.15) `exec -a` fails and every tab closes at once. POSIX mode
        // keeps what /bin/sh did: no BASH_ENV or other startup file.
        //
        // When an `initialCommand` is present, we run it from inside the
        // login shell (so it sees the user's `.zshrc` env) and then re-exec
        // the shell so the session stays alive after the command returns.
        // This avoids a race between zshrc and a post-hoc send.
        let shell = configuration.executablePath
        let argv0 = Self.shellQuote(configuration.execName)
        let cdSegment = configuration.workingDirectory.map {
            "cd \(Self.shellQuote($0)) 2>/dev/null; "
        } ?? ""

        let shellArgs: String
        if let tokens = configuration.initialCommand, !tokens.isEmpty {
            // Inner shell runs the command; trailing `exec` respawns a fresh
            // interactive login shell so the pty doesn't die on exit. Each
            // token is shell-quoted so binaries or arguments with spaces or
            // metacharacters don't break the script.
            let quotedCommand = tokens.map(Self.shellQuote).joined(separator: " ")
            // Our `.zshenv` handed ZDOTDIR back to the user's before the
            // command ran; the respawned shell needs ours again for the
            // cwd hook (the command itself never sees it).
            var respawnEnv = ""
            if let zdotdir = configuration.environment["ZDOTDIR"] {
                let user = configuration.environment[ShellConfiguration.userZDotDirKey] ?? ""
                respawnEnv = "export ZDOTDIR=\(Self.shellQuote(zdotdir)) "
                    + "\(ShellConfiguration.userZDotDirKey)=\(Self.shellQuote(user)); "
            }
            // This line runs in the user's shell, not /bin/sh: fish's `exec`
            // takes no `-a` (it would fail and the tab would close when
            // claude exits), so the login-style argv[0] is zsh/bash only.
            let respawn = Self.supportsExecArgv0(shell)
                ? "exec -a \(argv0) \(Self.shellQuote(shell)) -l -i"
                : "exec \(Self.shellQuote(shell)) -l -i"
            let innerScript = "\(quotedCommand); \(respawnEnv)\(respawn)"
            shellArgs = "-l -i -c \(Self.shellQuote(innerScript))"
        } else {
            let extra = configuration.arguments.map(Self.shellQuote).joined(separator: " ")
            shellArgs = extra
        }

        let command = "\(cdSegment)exec -a \(argv0) \(Self.shellQuote(shell)) \(shellArgs)"

        terminalView.startProcess(
            executable: Self.launcherPath,
            args: Self.launcherArguments + [command],
            environment: configuration.environmentList,
            execName: configuration.execName
        )
    }

    /// One-time terminal behaviour, set before the shell starts so the
    /// first bytes Claude Code writes already meet the final setup.
    private func configureTerminal() {
        TerminalAppearance.apply(to: terminalView)

        // Set before the shell starts, so nothing is ever trimmed at the old
        // limit. The `init(frame:font:options:)` route isn't available:
        // XylemTerminalView declares its own designated init and therefore
        // doesn't inherit SwiftTerm's options initialiser.
        terminalView.changeScrollback(Self.scrollbackLines)

        // Option as Meta (SwiftTerm's default, made explicit): Claude Code's
        // Option+Enter newline, Option+arrow word jumps and Meta-b/f need
        // the ESC prefix. Cost: Option-composed characters (dead keys such
        // as Option+E, layout-specific Option symbols) are not typed; Cmd+
        // Option+O toggles this at runtime (built into SwiftTerm).
        terminalView.optionAsMetaKey = true

        // OSC 7501 (Claude Code's program-status probe) and DECSET 2031
        // (theme notifications) are handled by SwiftTerm itself since 1.99.
    }

    private func applyCurrentAppearance() {
        terminalView.font = AppSettings.terminalFont
        // A font change resets SwiftTerm's colour caches and re-measures
        // cells; re-apply the theme so nothing falls back to defaults.
        TerminalAppearance.apply(to: terminalView)
    }

    private func observeAppearanceChanges() {
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .xylemTerminalAppearanceChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyCurrentAppearance()
        }
    }

    /// Shells whose `exec` takes `-a <argv0>` - only the two verified;
    /// fish's doesn't, and plain `exec` is safe everywhere.
    nonisolated static func supportsExecArgv0(_ shell: String) -> Bool {
        ["zsh", "bash"].contains((shell as NSString).lastPathComponent)
    }

    nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// One shell word for a command Xylem types into a tab: left as is when
    /// it is plain (letters, digits, `._/@:+-`), single-quoted otherwise, so
    /// text from outside (a skills.sh entry, a branch name of a cloned
    /// repository) can't add commands with `;`, `$(…)` or a backtick.
    nonisolated static func shellWord(_ value: String) -> String {
        let plain = !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._/@:+-".unicodeScalars.contains(scalar))
        }
        return plain ? value : shellQuote(value)
    }
}

extension TerminalSession: Hashable {
    static func == (lhs: TerminalSession, rhs: TerminalSession) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
