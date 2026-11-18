//
//  AppSettings.swift
//  Xylem
//
//  Single source for user-configurable preferences stored in UserDefaults.
//  SettingsView binds to these keys via @AppStorage; other code reads through
//  the static accessors so UserDefaults key strings live in one place.
//

import Foundation
import AppKit
import SwiftUI

/// Where the tab list lives: the sidebar (three-line rows) or a bar above
/// the terminal (two-line tabs, the terminal gets the sidebar's width).
nonisolated enum TabPlacement: String, CaseIterable, Identifiable {
    case sidebar
    case top

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sidebar: "In the sidebar"
        case .top: "Above the terminal"
        }
    }
}

enum AppSettings {
    enum Keys {
        static let autoStartClaude = "autoStartClaude"
        static let continueLastSession = "continueLastSession"
        static let notifyWhenClaudeWaits = "notifyWhenClaudeWaits"
        static let confirmQuitWhileClaudeWorks = "confirmQuitWhileClaudeWorks"
        static let sendCrashReports = "sendCrashReports"
        static let claudeBinaryPath = "claudeBinaryPath"
        static let terminalFontFamily = "terminalFontFamily"
        static let terminalFontSize = "terminalFontSize"
        static let leftSidebarCollapsed = "leftSidebarCollapsed"
        static let tabPlacement = "tabPlacement"   // TabPlacement: "sidebar" / "top"
        static let inspectorVisible = "inspectorVisible"
        static let panelTab = "panelTab"   // "claude" / "git": the right panel's tab
        static let drawerWidth = "drawerWidth"   // Files / Changes drawer, points
        static let rightPanelWidth = "rightPanelWidth"   // Claude / Git panel, points
        static let openFilesWith = "openFilesWith"   // app path for the drawer's Open; "" = system default
        static let openFilesWithAsked = "openFilesWithAsked"   // the first Open asked which app
        static let welcomed = "welcomed"   // first-launch onboarding marker
    }

    static let defaults: [String: Any] = [
        Keys.autoStartClaude: true,
        Keys.continueLastSession: true,
        Keys.notifyWhenClaudeWaits: true,
        Keys.confirmQuitWhileClaudeWorks: true,
        Keys.sendCrashReports: true,
        Keys.claudeBinaryPath: "claude",
        Keys.terminalFontFamily: defaultTerminalFontFamily,
        Keys.terminalFontSize: 12.0,
        Keys.leftSidebarCollapsed: false,
        Keys.tabPlacement: TabPlacement.sidebar.rawValue,
        Keys.inspectorVisible: true,
        Keys.welcomed: false
    ]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: defaults)
    }

    static var autoStartClaude: Bool {
        UserDefaults.standard.bool(forKey: Keys.autoStartClaude)
    }

    /// Opening a project resumes its newest Claude session instead of
    /// starting an empty one.
    static var continueLastSession: Bool {
        UserDefaults.standard.bool(forKey: Keys.continueLastSession)
    }

    /// macOS notification when Claude in a tab the user isn't looking at
    /// finishes or asks for input (the Dock badge is always on).
    static var notifyWhenClaudeWaits: Bool {
        UserDefaults.standard.bool(forKey: Keys.notifyWhenClaudeWaits)
    }

    /// Crash and hang reports to Sentry (Release builds). Read before
    /// `registerDefaults()` runs (Sentry starts first in `XylemApp.init`),
    /// so an unset key means the default, on. Applies at the next launch.
    static var sendCrashReports: Bool {
        // `bool(forKey:)` also reads "NO"/"YES" strings (`defaults write`,
        // launch arguments), which an `as? Bool` cast would drop.
        guard UserDefaults.standard.object(forKey: Keys.sendCrashReports) != nil else { return true }
        return UserDefaults.standard.bool(forKey: Keys.sendCrashReports)
    }

    /// ⌘Q asks first while Claude works or waits for an answer in a tab.
    static var confirmQuitWhileClaudeWorks: Bool {
        UserDefaults.standard.bool(forKey: Keys.confirmQuitWhileClaudeWorks)
    }

    /// What the tabs run and the Doctor checks. A leading `~/` is expanded
    /// here: the tabs pass the value shell-quoted, where `~` stays literal.
    static var claudeBinaryPath: String {
        let raw = UserDefaults.standard.string(forKey: Keys.claudeBinaryPath) ?? "claude"
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "claude" }
        return ClaudeBinaryLocator.expandingTilde(trimmed, home: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    /// The font chain ("JetBrains Mono", Menlo, monospace): JetBrains Mono
    /// when installed, otherwise Menlo, what a Mac without JetBrains Mono
    /// renders that chain with.
    /// Resolved once per launch.
    static let defaultTerminalFontFamily: String = {
        let installed = NSFontManager.shared.availableFontFamilies
        return installed.contains("JetBrains Mono") ? "JetBrains Mono" : "Menlo"
    }()

    static var terminalFontFamily: String {
        let raw = UserDefaults.standard.string(forKey: Keys.terminalFontFamily) ?? defaultTerminalFontFamily
        return raw.isEmpty ? defaultTerminalFontFamily : raw
    }

    static var terminalFontSize: CGFloat {
        let value = UserDefaults.standard.double(forKey: Keys.terminalFontSize)
        return value > 0 ? CGFloat(value) : 12
    }

    static var welcomed: Bool {
        UserDefaults.standard.bool(forKey: Keys.welcomed)
    }

    /// Returns an NSFont matching the current terminal font settings, falling
    /// back to a monospaced system font if the requested family is unavailable.
    /// The setting holds a family name ("JetBrains Mono"), which NSFont(name:)
    /// does not always accept, so resolve the family's regular face first.
    static var terminalFont: NSFont {
        let family = terminalFontFamily
        let size = terminalFontSize
        if let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return font
        }
        if let font = NSFont(name: family, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

extension Notification.Name {
    /// Posted by SettingsView whenever the user changes a terminal-appearance
    /// preference so live sessions can re-apply it without a restart.
    static let xylemTerminalAppearanceChanged = Notification.Name("XylemTerminalAppearanceChanged")

    /// Posted by the ⌘K menu item to open the command palette.
    static let xylemOpenCommandPalette = Notification.Name("XylemOpenCommandPalette")

    /// Posted by the Help menu item to re-show the welcome sheet on demand,
    /// bypassing the once-only `welcomed` gate.
    static let xylemShowWelcome = Notification.Name("XylemShowWelcome")

    /// Posted by menu items that need to run a tabs-model action. `object` is
    /// a `MenuTabAction` case describing what to do. Kept as a single channel
    /// so every menu item stays trivially routable without threading the
    /// model through the Settings scene or scripting focus gymnastics.
    static let xylemMenuAction = Notification.Name("XylemMenuAction")
}

/// Actions routed from menu items through NotificationCenter so they survive
/// menu-bar focus loss (AX-driven tests in particular).
enum MenuTabAction {
    case newTab
    case closeTab
    case closeOtherTabs
    case clear, interrupt
    case switchToTab(Int)   // 1-based index
    case findInTerminal
    case findNext
    case findPrevious
    case showCheatsheet
    case showUsage
    case openFolder
    case rail(PanelRailItem)   // what a click on that rail icon does
}
