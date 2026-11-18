//
//  SettingsView.swift
//  Xylem
//
//  Simple preferences window backed by @AppStorage. Two tabs: General (Claude
//  launch behaviour) and Terminal (font family + size). Changes broadcast a
//  notification so live sessions re-apply appearance without a restart.
//  The font-size slider broadcasts once when the drag ends, not per step -
//  every broadcast reflows every terminal and SIGWINCHes every pty.
//

import SwiftUI
import AppKit

struct SettingsView: View {
    let updater: AppUpdater

    var body: some View {
        // One topic per tab (2026-11-16: General had grown to four crowded
        // sections).
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ClaudeCodeSettingsView()
                .tabItem { Label("Claude Code", systemImage: "sparkles") }
            TerminalSettingsView()
                .tabItem { Label("Terminal", systemImage: "terminal") }
            FilesSettingsView()
                .tabItem { Label("Files", systemImage: "folder") }
            HotkeysSettingsView()
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
            UpdatesPrivacySettingsView(updater: updater)
                .tabItem { Label("Updates & Privacy", systemImage: "lock.shield") }
        }
        .frame(width: 560, height: 480)
        .tint(AppTheme.Colors.accent)
        // Design choice: the window opens centred on the screen (it used to
        // keep the system's spot and run low once it grew taller).
        .background(CenterWindowOnOpen())
    }
}

/// Centres the Settings window every time it opens. SwiftUI keeps the
/// window (and this view) alive after it closes, so "opens" = the first
/// time it becomes key after appearing or after a close; refocusing an open
/// window leaves it where the user put it.
private struct CenterWindowOnOpen: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        private var needsCentre = true
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsCentre = true }
            })
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, self.needsCentre, let window = note.object as? NSWindow else { return }
                    self.needsCentre = false
                    Self.centre(window)
                }
            })
            // Already key by the time SwiftUI hosts us (first opening).
            DispatchQueue.main.async { [weak self] in
                guard let self, self.needsCentre, window.isVisible else { return }
                self.needsCentre = false
                Self.centre(window)
            }
        }

        static func centre(_ window: NSWindow) {
            guard let screen = window.screen ?? NSScreen.main else { return }
            let area = screen.visibleFrame
            window.setFrameOrigin(NSPoint(
                x: (area.midX - window.frame.width / 2).rounded(),
                y: (area.midY - window.frame.height / 2).rounded()
            ))
        }
    }
}

private struct HotkeysSettingsView: View {
    @State private var bindings: [HotkeyAction: HotkeyBinding] = HotkeyStore.all()
    @State private var editingAction: HotkeyAction?
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Edit a shortcut by typing it like `cmd+shift+d` or `cmd+leftArrow`. Changes apply right away.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 8)

            List {
                ForEach(HotkeyAction.allCases) { action in
                    row(for: action)
                }
            }
            .listStyle(.inset)
        }
        .onAppear {
            // HotkeyStore caches the file in memory; re-read on open so
            // hand edits to keybindings.json show up here.
            HotkeyStore.reload()
            let fresh = HotkeyStore.all()
            if bindings != fresh { bindings = fresh }
        }
    }

    private func row(for action: HotkeyAction) -> some View {
        HStack {
            Text(action.displayName)
                .frame(maxWidth: .infinity, alignment: .leading)
            if editingAction == action {
                TextField("cmd+shift+d", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .onSubmit { commit(action) }
                Button("Cancel") { editingAction = nil }
                    .buttonStyle(.plain)
            } else {
                Text(bindings[action]?.display ?? "-")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 80, alignment: .trailing)
                Button("Edit") { startEdit(action) }
                    .buttonStyle(.plain)
                Button("Reset") {
                    HotkeyStore.reset(action)
                    bindings = HotkeyStore.all()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func startEdit(_ action: HotkeyAction) {
        editingAction = action
        draft = bindings[action]?.display ?? ""
    }

    private func commit(_ action: HotkeyAction) {
        guard let parsed = HotkeyBinding.parse(draft) else {
            editingAction = nil
            return
        }
        HotkeyStore.set(parsed, for: action)
        bindings = HotkeyStore.all()
        editingAction = nil
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(AppSettings.Keys.notifyWhenClaudeWaits) private var notifyWhenClaudeWaits: Bool = true
    @AppStorage(AppSettings.Keys.confirmQuitWhileClaudeWorks) private var confirmQuit: Bool = true
    @AppStorage(AppSettings.Keys.tabPlacement) private var tabPlacement: TabPlacement = .sidebar

    var body: some View {
        Form {
            Section {
                Toggle("Notify when Claude finishes or needs input in another tab", isOn: $notifyWhenClaudeWaits)
                Toggle("Ask before quitting while Claude is working", isOn: $confirmQuit)
            }
            Section {
                Picker("Show tabs", selection: $tabPlacement) {
                    ForEach(TabPlacement.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text("Above the terminal, the terminal gets the sidebar's width; hover a tab to see its whole prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct FilesSettingsView: View {
    @AppStorage(AppSettings.Keys.openFilesWith) private var openFilesWith: String = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Open files in") {
                    // The installed editors, the system default, any other app.
                    Menu(openFilesWith.isEmpty ? "Default app for each file" : FileOpener.appName(URL(fileURLWithPath: openFilesWith))) {
                        Button("Default app for each file") { FileOpener.choose(nil) }
                        Divider()
                        ForEach(FileOpener.installedEditors(), id: \.self) { editor in
                            Button(FileOpener.appName(editor)) { FileOpener.choose(editor) }
                        }
                        Divider()
                        Button("Other App…") { if let app = FileOpener.pickApp() { FileOpener.choose(app) } }
                    }
                    .fixedSize()
                }
                Text("Used by Open in the Files and Changes drawer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct UpdatesPrivacySettingsView: View {
    @Bindable var updater: AppUpdater
    @AppStorage(AppSettings.Keys.sendCrashReports) private var sendCrashReports: Bool = true

    var body: some View {
        Form {
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
                    .disabled(!updater.isRunning)
                Text("New versions download in the background and install when you quit Xylem.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Toggle("Send crash reports", isOn: $sendCrashReports)
                Text("Sends what crashed or froze, with the app and macOS versions and the Mac model. Never your prompts or project names. Takes effect after you restart Xylem.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct ClaudeCodeSettingsView: View {
    @AppStorage(AppSettings.Keys.autoStartClaude) private var autoStartClaude: Bool = true
    @AppStorage(AppSettings.Keys.continueLastSession) private var continueLastSession: Bool = true
    @AppStorage(AppSettings.Keys.claudeBinaryPath) private var claudeBinaryPath: String = "claude"

    var body: some View {
        Form {
            Section {
                Toggle("Auto-start Claude in new tabs", isOn: $autoStartClaude)
                Toggle("Continue Claude sessions (opening a project, relaunching Xylem)", isOn: $continueLastSession)
                    .disabled(!autoStartClaude)
            }
            Section {
                LabeledContent("Binary path") {
                    HStack {
                        // The title is for accessibility only: a grouped
                        // Form shows a TextField's title as a second label
                        // ("claude claude" next to the value).
                        TextField("Binary path", text: $claudeBinaryPath, prompt: Text("claude"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") { chooseBinary() }
                    }
                }
                Text("Name (on $PATH) or absolute path. Default: `claude`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func chooseBinary() {
        if let url = OpenPanels.pick(.claudeBinary) {
            claudeBinaryPath = url.path
        }
    }
}

private struct TerminalSettingsView: View {
    @AppStorage(AppSettings.Keys.terminalFontFamily) private var fontFamily: String = AppSettings.defaultTerminalFontFamily
    @AppStorage(AppSettings.Keys.terminalFontSize) private var fontSize: Double = 12

    private static let suggestedFamilies: [String] = [
        "Menlo", "Monaco", "SF Mono", "JetBrains Mono", "Fira Code",
        "Hack", "Source Code Pro", "IBM Plex Mono"
    ]

    /// Suggested families that are actually installed. Enumerating every
    /// font family is slow, so it happens once per process, not per body.
    private static let installedSuggestedFamilies: [String] = {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return suggestedFamilies.filter { installed.contains($0) }
    }()

    /// True while the size slider is being dragged. Each terminal reflows
    /// and its pty gets SIGWINCH on an appearance change, so intermediate
    /// drag steps only update the stored value; the broadcast happens once
    /// on release.
    @State private var isDraggingSize = false

    var body: some View {
        Form {
            Section("Font") {
                Picker("Family", selection: $fontFamily) {
                    ForEach(availableFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                HStack {
                    Slider(value: $fontSize, in: 9...24, step: 1) { editing in
                        isDraggingSize = editing
                        if !editing { broadcastAppearanceChange() }
                    }
                    Text("\(Int(fontSize)) pt").monospacedDigit().frame(width: 42, alignment: .trailing)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: fontFamily) { _, _ in broadcastAppearanceChange() }
        // Keyboard / accessibility adjustments don't report editing state,
        // so non-drag changes still broadcast immediately.
        .onChange(of: fontSize) { _, _ in
            if !isDraggingSize { broadcastAppearanceChange() }
        }
    }

    private var availableFamilies: [String] {
        var all = Self.installedSuggestedFamilies
        if !all.contains(fontFamily) { all.append(fontFamily) }
        return all
    }

    private func broadcastAppearanceChange() {
        NotificationCenter.default.post(name: .xylemTerminalAppearanceChanged, object: nil)
    }
}
