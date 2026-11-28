//
//  XylemApp.swift
//  Xylem
//
//  App entry point. Declares the main window, Settings scene, and menu
//  commands. All action buttons post NotificationCenter events instead of
//  touching view models directly so they survive loss of key-window focus
//  (important for AX-driven tests and for macOS menu-bar consistency).
//

import SwiftUI

@main
struct XylemApp: App {
    /// The composition root, built once for the app's lifetime. (As `@State`
    /// in ContentView it would be rebuilt on every ContentView init.)
    @State private var app: AppModel
    /// Sparkle (Release builds only).
    @State private var updater: AppUpdater
    /// The About window's section (Help > Open-Source Licenses opens it on Libraries).
    @State private var aboutModel = AboutWindowModel()
    /// Asks before ⌘Q cuts off a running turn (QuitConfirmation).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Order matters. AppModel restores the saved tabs and starts their
        // shells in its init, reading AppSettings (e.g. autoStartClaude), so
        // defaults must be registered first. A property initialiser would
        // run before this body, and an unregistered Bool reads as false:
        // every restored tab would come up without `claude`. The onboarding
        // check must also see tabs-state.json before AppModel writes it.
        // First: a crash anywhere below should be reported.
        CrashReporting.start()
        AppSettings.registerDefaults()
        Self.suppressOnboardingForExistingUsers()
        // Before restore: tabs look their transcripts up in the Claude
        // config folder (CLAUDE_CONFIG_DIR). Asks the shell only once ever.
        ClaudeConfigDirectory.bootstrap()
        // Before restore too: which hook settings restored tabs start with.
        ClaudeCLIVersion.bootstrap(configured: AppSettings.claudeBinaryPath)
        ClaudeExecutable.seed(configured: AppSettings.claudeBinaryPath)
        let model = AppModel()
        let updater = AppUpdater()
        updater.notifier = model.attentionNotifier
        _app = State(initialValue: model)
        _updater = State(initialValue: updater)
    }

    /// v0.3 added first-launch onboarding gated by `welcomed` @AppStorage.
    /// Existing installs predate that flag - detect them via the presence
    /// of ~/.xylem/tabs-state.json and mark welcomed so they don't see a
    /// "welcome" sheet on their tenth launch.
    private static func suppressOnboardingForExistingUsers() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: AppSettings.Keys.welcomed) else { return }
        let stateFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".xylem/tabs-state.json")
        if FileManager.default.fileExists(atPath: stateFile.path) {
            defaults.set(true, forKey: AppSettings.Keys.welcomed)
        }
    }

    var body: some Scene {
        Window("Xylem", id: "main") {
            ContentView(app: app, updater: updater)
                .onAppear { appDelegate.model = app }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1400, height: 860)
        // Compact density everywhere but the tab list.
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            // Our own items, not SidebarCommands / InspectorCommands: the
            // system sidebar item always reads "Show Sidebar", and the
            // inspector one does nothing with the custom right panel.
            CommandGroup(replacing: .sidebar) {
                TabListMenuItem()
                RightPanelMenuItem()
                Divider()
                Button("Claude Panel") { post(.rail(.claude)) }
                    .keyboardShortcut(HotkeyStore.shortcut(for: .showClaude))
                Button("Git Panel") { post(.rail(.git)) }
                    .keyboardShortcut(HotkeyStore.shortcut(for: .showGit))
                Button("Files") { post(.rail(.files)) }
                    .keyboardShortcut(HotkeyStore.shortcut(for: .showFiles))
                Button("Changes") { post(.rail(.changes)) }
                    .keyboardShortcut(HotkeyStore.shortcut(for: .showChanges))
            }

            // Replaces "Xylem Help" (there is no help book).
            CommandGroup(replacing: .help) {
                OpenSourceLicensesMenuItem(aboutModel: aboutModel)
            }

            // About Xylem (our own window) and the update items.
            CommandGroup(replacing: .appInfo) {
                UpdateMenuItems(updater: updater, aboutModel: aboutModel)
            }

            // No File > Close / Close All: they own ⌘W, so "Close Tab" got no
            // shortcut and ⌘W closed the only window - quitting Xylem with
            // every session in it. A terminal's ⌘W closes the tab.
            CommandGroup(replacing: .saveItem) {}

            CommandGroup(replacing: .newItem) {
                Button("New Tab") { post(.newTab) }
                    .keyboardShortcut(HotkeyStore.shortcut(for: .newTab))
                // From any tab, not only the New Tab screen's button.
                Button("Open Folder…") { post(.openFolder) }
                    .keyboardShortcut(HotkeyStore.shortcut(for: .openFolder))
            }

            // Extensions of View menu - search, palette, pane layout, tab
            // switchers. Groups them under the native "View" heading so the
            // menu bar reads like standard macOS apps.
            CommandGroup(after: .toolbar) {
                Button("Command Palette…") {
                    NotificationCenter.default.post(name: .xylemOpenCommandPalette, object: nil)
                }
                .keyboardShortcut(HotkeyStore.shortcut(for: .commandPalette))

                Button("Usage Dashboard") { post(.showUsage) }
                    .keyboardShortcut("u", modifiers: .command)

                Button("Keyboard Shortcuts") { post(.showCheatsheet) }
                    .keyboardShortcut("/", modifiers: .command)

                Button("Show Welcome Screen") {
                    NotificationCenter.default.post(name: .xylemShowWelcome, object: nil)
                }

                Divider()

                Menu("Tabs") {
                    Button("Close Tab") { post(.closeTab) }
                        .keyboardShortcut(HotkeyStore.shortcut(for: .closeTab))
                    Button("Close Other Tabs") { post(.closeOtherTabs) }
                        .keyboardShortcut(HotkeyStore.shortcut(for: .closeOtherTabs))
                    Divider()
                    Button("Next Tab Waiting for You") { post(.nextWaitingTab) }
                        .keyboardShortcut(HotkeyStore.shortcut(for: .nextWaitingTab))
                    Divider()
                    ForEach(1...9, id: \.self) { n in
                        Button("Switch to Tab \(n)") { post(.switchToTab(n)) }
                            .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                    }
                }

                Menu("Terminal") {
                    Button("Find…") { post(.findInTerminal) }
                        .keyboardShortcut(HotkeyStore.shortcut(for: .findInTerminal))
                    Button("Find Next") { post(.findNext) }
                        .keyboardShortcut(HotkeyStore.shortcut(for: .findNextMatch))
                    Button("Find Previous") { post(.findPrevious) }
                        .keyboardShortcut(HotkeyStore.shortcut(for: .findPreviousMatch))
                    Divider()
                    Button("Clear") { post(.clear) }
                        .keyboardShortcut(HotkeyStore.shortcut(for: .clear))
                    Button("Interrupt") { post(.interrupt) }
                        .keyboardShortcut(HotkeyStore.shortcut(for: .interrupt))
                }
            }
        }

        Settings {
            SettingsView(updater: updater)
        }

        // Xylem > About Xylem; Help > Open-Source Licenses opens it on Libraries.
        Window("About Xylem", id: AboutWindowView.windowID) {
            AboutWindowView(updater: updater, model: aboutModel)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
    }


    private func post(_ action: MenuTabAction) {
        NotificationCenter.default.post(name: .xylemMenuAction, object: action)
    }
}

/// The Xylem menu's first items, in their own view: every update check
/// flips `canCheckForUpdates`, and a read in the scene's `commands` would
/// rebuild the whole window (ContentView and everything under it) each time.
private struct UpdateMenuItems: View {
    let updater: AppUpdater
    let aboutModel: AboutWindowModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // While an update waits for a quit (it may wait for days).
        if let version = updater.readyVersion {
            Button("Install Update \(version)…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
            Divider()
        }
        Button("About Xylem") { AboutWindowOpener(model: aboutModel, openWindow: openWindow)(.license) }
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}

/// View > Show / Hide Claude / Git Panel (⌃⌘I by default, the system
/// inspector's shortcut; rebindable in Settings > Hotkeys).
/// Showing it closes the Files / Changes drawer (ContentView's onChange).
private struct RightPanelMenuItem: View {
    @AppStorage(AppSettings.Keys.inspectorVisible) private var showsPanel: Bool = true

    var body: some View {
        Button(showsPanel ? "Hide Claude / Git Panel" : "Show Claude / Git Panel") { showsPanel.toggle() }
            .keyboardShortcut(HotkeyStore.shortcut(for: .togglePanel))
    }
}

/// View > Show / Hide Tab List (⌃⌘S by default): names its real state,
/// which the system sidebar item never did.
private struct TabListMenuItem: View {
    @AppStorage(AppSettings.Keys.leftSidebarCollapsed) private var collapsed: Bool = false
    @AppStorage(AppSettings.Keys.tabPlacement) private var tabPlacement: TabPlacement = .sidebar

    var body: some View {
        Button(collapsed ? "Show Tab List" : "Hide Tab List") { collapsed.toggle() }
            .keyboardShortcut(HotkeyStore.shortcut(for: .toggleTabList))
            // Tabs on top: there is no sidebar to show or hide, and a
            // toggle here would only change how it comes back later.
            .disabled(tabPlacement == .top)
    }
}
