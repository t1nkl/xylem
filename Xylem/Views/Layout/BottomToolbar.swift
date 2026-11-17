//
//  BottomToolbar.swift
//  Xylem
//
//  Compact action strip under the terminal, on the system bar material:
//  icon + label buttons (Compact / Clear / Memory / Goal | Copy / File /
//  Image / Screenshot | Worktree) and the Doctor status on the right.
//  Goal types `/goal ` without Enter, so the user writes the condition
//  next. Worktree opens the New Worktree Tab sheet (same as the
//  palette's "Git · New Worktree Tab…") and is disabled outside a repo.
//
//  Doctor checks two things: the `claude` binary (resolved at launch) and
//  whether the tab-event hooks report (HookBridgeHealth, live from the
//  state tracker). A dead bridge turns it amber - tab states and "waiting
//  for you" marks would otherwise degrade without a word.
//

import SwiftUI
import AppKit

struct BottomToolbarActions {
    var onCompact: () -> Void = {}
    var onClear: () -> Void = {}
    var onMemory: () -> Void = {}
    var onGoal: () -> Void = {}
    var onCopy: () -> Void = {}
    var onAttachFile: () -> Void = {}
    var onAttachImage: () -> Void = {}
    var onScreenshot: () -> Void = {}
    var onNewWorktree: () -> Void = {}
}

/// Doctor's view of the world. Healthy carries the resolved binary path so
/// the popover can show "found at <path>" + Reveal in Finder; missing
/// carries what Settings asks for and lets the popover render install
/// instructions instead. Not on PATH: installed, but the tabs' shell won't
/// find it. Checking: the first lookup hasn't finished.
enum DoctorStatus: Equatable {
    case checking
    case healthy(path: String)
    case notOnPath(path: String)
    case missing(configured: String)

    /// What is wrong, without the paths: the Doctor opens its popover by
    /// itself once per kind of problem.
    enum Problem: Equatable { case missing, notOnPath }
    var problem: Problem? {
        switch self {
        case .missing: .missing
        case .notOnPath: .notOnPath
        case .checking, .healthy: nil
        }
    }

    /// Tabs can't start claude.
    var isBroken: Bool {
        switch self {
        case .missing, .notOnPath: return true
        case .checking, .healthy: return false
        }
    }
}

struct BottomToolbar: View {
    let actions: BottomToolbarActions
    /// Read here, not in ContentView, so a lookup finishing re-renders only
    /// the strip.
    let doctorStatus: () -> DoctorStatus
    /// The popover opened: look for claude again when it was missing (it
    /// may have been installed since).
    var onDoctorOpen: () -> Void = {}
    /// "Check Again" in the not-on-PATH popover; returns when the lookup is done.
    var onDoctorCheckAgain: () async -> Void = {}
    /// Tabs whose claude couldn't start; offered a restart once fixed.
    var tabsWithoutClaude: () -> Int = { 0 }
    var onRestartTabsWithoutClaude: () -> Void = {}
    /// Source of the hook health; nil in previews.
    var hooks: ClaudeTabStateTracker?
    /// The active tab's folder, to name the settings that block hooks.
    var projectDirectory: () -> String? = { nil }
    /// The active tab is in a git repository (a worktree can branch from it).
    /// Read here so a branch change re-renders only the strip.
    var canAddWorktree: () -> Bool = { false }

    var body: some View {
        HStack(spacing: 2) {
            // A narrow window (both side panels open) can't fit every label:
            // icons only then, with the label as the tooltip, instead of
            // truncated "Scre…" labels.
            ViewThatFits(in: .horizontal) {
                buttons(showLabels: true)
                buttons(showLabels: false)
            }
            // First pick of the free width, or the Spacer's share makes the
            // labels give up long before they have to.
            .layoutPriority(1)
            Spacer(minLength: 8)
            DoctorIndicator(status: doctorStatus(), hooks: hooks, projectDirectory: projectDirectory,
                            onOpen: onDoctorOpen, onCheckAgain: onDoctorCheckAgain,
                            tabsWithoutClaude: tabsWithoutClaude,
                            onRestartTabs: onRestartTabsWithoutClaude)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: AppTheme.Metrics.bottomBarHeight)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func buttons(showLabels: Bool) -> some View {
        let canAddWorktree = canAddWorktree()
        return HStack(spacing: 2) {
            ToolbarButton(icon: "rectangle.compress.vertical", label: "Compact", showLabel: showLabels, action: actions.onCompact)
            ToolbarButton(icon: "eraser", label: "Clear", showLabel: showLabels, action: actions.onClear)
            ToolbarButton(icon: "brain", label: "Memory", showLabel: showLabels, action: actions.onMemory)
            ToolbarButton(icon: "flag.checkered", label: "Goal", showLabel: showLabels, action: actions.onGoal)
            Divider().frame(height: 14).padding(.horizontal, 6)
            ToolbarButton(icon: "doc.on.clipboard", label: "Copy", showLabel: showLabels, action: actions.onCopy)
            ToolbarButton(icon: "paperclip", label: "File", showLabel: showLabels, action: actions.onAttachFile)
            ToolbarButton(icon: "photo", label: "Image", showLabel: showLabels, action: actions.onAttachImage)
            ToolbarButton(icon: "camera.viewfinder", label: "Screenshot", showLabel: showLabels, action: actions.onScreenshot)
            Divider().frame(height: 14).padding(.horizontal, 6)
            ToolbarButton(icon: "arrow.triangle.branch", label: "Worktree", showLabel: showLabels,
                          action: actions.onNewWorktree,
                          isEnabled: canAddWorktree,
                          help: canAddWorktree
                            ? "A new branch in its own checkout, opened in a new tab"
                            : "The active tab's folder is not in a git repository")
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct DoctorIndicator: View {
    let status: DoctorStatus
    let hooks: ClaudeTabStateTracker?
    let projectDirectory: () -> String?
    let onOpen: () -> Void
    var onCheckAgain: () async -> Void = {}
    var tabsWithoutClaude: () -> Int = { 0 }
    var onRestartTabs: () -> Void = {}
    @State private var isShowingPopover = false
    /// Went from broken to healthy with this many tabs whose claude
    /// couldn't start (they keep the old PATH): the popover offers to
    /// restart them. Counted once, at the fix.
    @State private var restartOffer = 0
    /// The broken status the popover last opened by itself for (a red
    /// Doctor shows its fix at once). Once per problem: closed by the
    /// user, it stays closed until the problem changes or comes back.
    @State private var autoShownFor: DoctorStatus.Problem?

    /// Reads only `hookHealth`, which changes on a state change, not per
    /// event - the strip doesn't re-render while Claude works.
    private var hookHealth: HookBridgeHealth { hooks?.hookHealth ?? .unknown }

    var body: some View {
        // Read here, not only inside the popover's closure: a state read
        // only there didn't update the open popover (seen live).
        let offer = restartOffer
        Button {
            isShowingPopover.toggle()
            if isShowingPopover { onOpen() }
        } label: {
            Label {
                Text("Doctor").foregroundStyle(AppTheme.Colors.accent)
            } icon: {
                icon
            }
            .font(AppTheme.Fonts.toolbarButton)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .help(helpText)
        .popover(isPresented: $isShowingPopover, arrowEdge: .bottom) {
            popoverContent(restartOffer: offer)
                .frame(width: 360)
                .padding(14)
        }
        .onChange(of: isShowingPopover) { _, shown in
            if !shown { restartOffer = 0 }   // offered once, not in every later popover
        }
        .onChange(of: status, initial: true) { old, status in
            if old.isBroken, case .healthy = status {
                restartOffer = tabsWithoutClaude()
                if restartOffer > 0 { isShowingPopover = true }
            }
            guard status.isBroken else {
                if status != .checking { autoShownFor = nil }
                return
            }
            restartOffer = 0
            // Per kind of problem, not per value: typing a path in Settings
            // gives a new "missing" status every pause.
            guard autoShownFor != status.problem else { return }
            autoShownFor = status.problem
            isShowingPopover = true
        }
    }

    @ViewBuilder
    private var icon: some View {
        if status.isBroken {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(AppTheme.Colors.statusRed)
        } else if status == .checking {
            Image(systemName: "circle.dotted").foregroundStyle(AppTheme.Colors.textMuted)
        } else if hookHealth.isProblem {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AppTheme.Colors.statusAmber)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(AppTheme.Colors.statusGreen)
        }
    }

    private var helpText: String {
        switch status {
        case .healthy(let path):
            return hookHealth.isProblem
                ? "Claude Code detected at \(path), but tab events are not arriving - click for details"
                : "Claude Code detected at \(path)"
        case .missing(let configured):
            return "\(configured) not found - click for install instructions"
        case .notOnPath(let path):
            return "\(path) is installed but not on your shell's PATH - click for the fix"
        case .checking:
            return "Looking for Claude Code…"
        }
    }

    @ViewBuilder
    private func popoverContent(restartOffer: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            switch status {
            case .healthy(let path):
                if restartOffer > 0 {
                    DoctorRestartTabsNotice(count: restartOffer) {
                        onRestartTabs()
                        self.restartOffer = 0
                        isShowingPopover = false
                    }
                    Divider()
                }
                DoctorHealthyPopover(path: path)
            case .missing(let configured):   DoctorMissingPopover(configured: configured)
            case .notOnPath(let path):       DoctorNotOnPathPopover(path: path, onCheckAgain: onCheckAgain)
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Looking for Claude Code…").font(.system(size: 12))
                }
            }
            Divider()
            HookHealthSection(health: hookHealth, lastEventAt: hooks?.lastHookEventAt,
                              projectDirectory: projectDirectory())
        }
        // Let every text grow in height inside the fixed-width popover.
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Doctor's "tab events" part: are the hooks reporting, and if not, what
/// most likely switched them off.
private struct HookHealthSection: View {
    let health: HookBridgeHealth
    let lastEventAt: Date?
    let projectDirectory: String?
    @State private var blockers: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: health.isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(health.isProblem ? AppTheme.Colors.statusAmber : AppTheme.Colors.statusGreen)
                Text(headline)
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if health.isProblem, !blockers.isEmpty {
                ForEach(blockers, id: \.self) { reason in
                    // The file name is the useful end of a long path.
                    Text(reason)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(reason)
                }
            }
        }
        .task(id: health) {
            guard health.isProblem else { return }
            blockers = await Self.findBlockers(projectDirectory)
        }
    }

    @concurrent nonisolated
    private static func findBlockers(_ directory: String?) async -> [String] {
        HookBlockers.find(projectDirectory: directory)
    }

    private var headline: String {
        switch health {
        case .reporting, .unknown: return "Tab events"
        case .notInstalled:        return "Tab events are off"
        case .silent:              return "Tab events are not arriving"
        }
    }

    private var detail: String {
        switch health {
        case .reporting:
            guard let lastEventAt else { return "Hooks report what Claude does in each tab." }
            return "Hooks report what Claude does in each tab. Last event "
                + lastEventAt.formatted(.relative(presentation: .named)) + "."
        case .unknown:
            return "Waiting for a Claude session to start in a tab."
        case .notInstalled:
            return "Xylem could not write ~/.xylem/hooks. Tab states, \"waiting for you\" marks and notifications fall back to watching the transcript."
        case .silent(let tabs):
            return "Claude in \(tabs.joined(separator: ", ")) has not reported anything since it started, though you have used it. Tab states, \"waiting for you\" marks and notifications fall back to watching the transcript."
                + (blockers.isEmpty ? " Hooks may be disabled by a settings policy, or this Claude Code version changed them." : " Hooks are switched off by:")
        }
    }
}

private struct DoctorHealthyPopover: View {
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.Colors.statusGreen)
                Text("Claude Code detected")
                    .font(.system(size: 12, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("PATH")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(AppTheme.Colors.textMuted)
                HStack {
                    Text(path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .help("Reveal in Finder")
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(0.04))
                )
            }
            Text("Override this in Settings → General → Binary path if you keep claude somewhere else.")
                .font(.system(size: 10))
                .foregroundStyle(AppTheme.Colors.textMuted)
        }
    }
}

/// Typical after Anthropic's installer when `~/.local/bin` never made it
/// into the shell's PATH: the binary exists, the tab says "command not
/// found". Shows one command for the user's own shell that writes the line
/// into the startup file the tabs' login shell reads (`ShellPathFix`) - the
/// bare `export` line it used to show, pasted into Terminal, changed only
/// that window. When the file already names the folder, says so instead.
private struct DoctorNotOnPathPopover: View {
    let path: String
    let onCheckAgain: () async -> Void

    @State private var isChecking = false
    @State private var checkedAndStillMissing = false
    /// The startup file already names the folder (read when shown).
    @State private var alreadyInFile = false

    private var folder: String { (path as NSString).deletingLastPathComponent }
    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    private var shellName: String {
        (ShellConfiguration.userShell() as NSString).lastPathComponent
    }
    private var fix: ShellPathFix {
        let env = ProcessInfo.processInfo.environment
        return ShellPathFix.make(folder: folder, shell: ShellConfiguration.userShell(environment: env), home: home,
                                 zdotdir: env["ZDOTDIR"],
                                 fileExists: { FileManager.default.fileExists(atPath: $0) })
    }
    private var shownFolder: String { ShellPathFix.homeRelative(folder, home: home, tilde: true) }

    var body: some View {
        let fix = fix
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppTheme.Colors.statusAmber)
                Text("Claude Code isn't on your PATH")
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(LocalizedStringKey("It's installed at `\(ShellPathFix.homeRelative(path, home: home, tilde: true))`, but your login shell (\(shellName)) doesn't look in `\(shownFolder)`, so tabs can't start it."))
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            if alreadyInFile {
                Text(LocalizedStringKey("`\(fix.startupFile)` already mentions `\(shownFolder)`, but the shell still doesn't see it. Check that line: it may be commented out, have a typo, or PATH may be set again further down the file."))
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.Colors.statusAmber)
            } else {
                Text(LocalizedStringKey("Paste this into Terminal once. It adds the folder to `\(fix.startupFile)`:"))
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                HStack(alignment: .top) {
                    Text(fix.command)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(fix.command, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .help("Copy")
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.04)))
                Text("Running only the export line in a terminal won't help: it lasts for that window alone.")
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.Colors.textMuted)
            }

            HStack(spacing: 8) {
                Button("Check Again") {
                    isChecking = true
                    checkedAndStillMissing = false
                    Task {
                        await onCheckAgain()
                        isChecking = false
                        // Still shown = still not on PATH (fixed closes this view).
                        checkedAndStillMissing = true
                        alreadyInFile = await Self.fileMentionsFolder(fix, folder: folder, home: home)
                    }
                }
                .controlSize(.small)
                .disabled(isChecking)
                if isChecking {
                    ProgressView().controlSize(.mini)
                } else if checkedAndStillMissing {
                    Text("Still not on PATH")
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.Colors.textMuted)
                }
            }
            Text("Then come back to Xylem: the Doctor checks again and offers to restart the tabs where Claude couldn't start (they still have the old PATH). Or set Settings → General → Binary path to the full path.")
                .font(.system(size: 10))
                .foregroundStyle(AppTheme.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { alreadyInFile = await Self.fileMentionsFolder(fix, folder: folder, home: home) }
    }

    /// A dotfile is a few KB; read on demand, at most 1 MB, off the main actor.
    @concurrent nonisolated private static func fileMentionsFolder(_ fix: ShellPathFix, folder: String, home: String) async -> Bool {
        guard let file = fix.startupFilePath,
              SafeFileRead.isRegularFile(file),
              let handle = FileHandle(forReadingAtPath: file) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1 << 20) else { return false }
        return ShellPathFix.mentions(folder: folder, home: home, in: String(decoding: data, as: UTF8.self))
    }
}

/// After a fix: tabs started while claude couldn't be found sit at a shell
/// prompt with the old PATH. One button starts them over.
private struct DoctorRestartTabsNotice: View {
    let count: Int
    let onRestart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(AppTheme.Colors.statusGreen)
                Text("Fixed").font(.system(size: 12, weight: .semibold))
            }
            Text(count == 1
                 ? "One tab was opened before the fix and still can't run Claude. Restart it to start Claude there."
                 : "\(count) tabs were opened before the fix and still can't run Claude. Restart them to start Claude there.")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // No Return shortcut: this popover may open by itself while the
            // user types in a terminal.
            Button(count == 1 ? "Restart Tab" : "Restart \(count) Tabs", action: onRestart)
                .controlSize(.small)
        }
    }
}

private struct DoctorMissingPopover: View {
    /// Settings → General → Binary path: a name or an absolute path.
    let configured: String

    /// Anthropic's native installer is the recommended path now; npm is left
    /// as a fallback for users who already have a Node toolchain set up.
    private let primaryInstall = "curl -fsSL https://claude.ai/install.sh | sh"
    private let fallbackInstall = "npm install -g @anthropic-ai/claude-code"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppTheme.Colors.statusAmber)
                Text("Claude Code not found")
                    .font(.system(size: 12, weight: .semibold))
            }
            // A key, not a String: only that renders the `code` spans.
            Text(LocalizedStringKey(explanation))
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            installBlock(label: "INSTALL", command: primaryInstall)
            installBlock(label: "OR VIA NPM", command: fallbackInstall)

            Text("Already installed somewhere unusual? Set the path in Settings → General → Binary path.")
                .font(.system(size: 10))
                .foregroundStyle(AppTheme.Colors.textMuted)
        }
    }

    private var explanation: String {
        configured.contains("/")
            ? "Settings → General → Binary path points at `\(configured)`, and there's no executable there."
            : "Xylem couldn't find `\(configured)` in the usual install folders or on your shell's PATH."
    }

    private func installBlock(label: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(AppTheme.Colors.textMuted)
            HStack {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .help("Copy install command")
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white.opacity(0.04))
            )
        }
    }
}

/// Borderless icon + label button, like the buttons of a window's bottom
/// bar. Hover gets a light rounded fill so the small targets read as
/// clickable.
private struct ToolbarButton: View {
    let icon: String
    let label: String
    var showLabel = true
    let action: () -> Void
    var isEnabled = true
    var help: String? = nil
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if showLabel {
                    Label(label, systemImage: icon)
                } else {
                    Image(systemName: icon)
                }
            }
                .font(AppTheme.Fonts.toolbarButton)
                .foregroundStyle(isEnabled ? (isHovering ? .primary : .secondary) : .tertiary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(isHovering && isEnabled ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help ?? (showLabel ? "" : label))
        .accessibilityLabel(label)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }
}

