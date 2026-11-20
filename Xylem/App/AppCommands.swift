//
//  AppCommands.swift
//  Xylem
//
//  The command palette's list and the bottom toolbar's actions, built from
//  the AppModel. Kept out of ContentView so the root view only composes.
//

import SwiftUI
import UniformTypeIdentifiers

/// One sheet at a time - a single source of truth makes it impossible to
/// present two sheets over each other.
enum ActiveSheet: Identifiable {
    case usage, skills, overview, commandPalette, cheatsheet, newWorktree
    var id: Self { self }
}

@MainActor
enum AppCommands {
    static func palette(
        app: AppModel,
        present: @escaping (ActiveSheet) -> Void,
        openSettings: @escaping () -> Void
    ) -> [PaletteCommand] {
        let tabs = app.tabs
        var commands: [PaletteCommand] = [
            PaletteCommand(id: "new-tab", title: "New Tab", subtitle: "Open a picker to choose a folder",
                           keywords: ["tab", "new", "open"], icon: "plus.square", shortcut: "⌘T",
                           run: { tabs.openEmptyTab() }),
            PaletteCommand(id: "close-tab", title: "Close Tab", subtitle: nil,
                           keywords: ["close", "tab"], icon: "xmark.square", shortcut: "⌘W",
                           run: { if let id = tabs.activeTabID { tabs.closeTab(id) } }),
            PaletteCommand(id: "next-waiting-tab", title: "Next Tab Waiting for You",
                           subtitle: "A tab where Claude finished, asks for permission or stopped on an error",
                           keywords: ["next", "waiting", "attention", "permission", "finished", "unread", "tab"],
                           icon: "bell.badge", shortcut: HotkeyStore.binding(for: .nextWaitingTab).display,
                           run: { app.selectNextWaitingTab() }),
            PaletteCommand(id: "open-usage", title: "Open Usage Dashboard", subtitle: "Cost / tokens / timeline across sessions",
                           keywords: ["usage", "cost", "tokens", "dashboard", "stats"], icon: "chart.bar.fill", shortcut: "⌘U",
                           run: { present(.usage) }),
            PaletteCommand(id: "open-overview", title: "All Sessions Overview", subtitle: "Grid of cards with per-tab stats",
                           keywords: ["overview", "sessions", "grid", "cards"], icon: "square.grid.2x2", shortcut: nil,
                           run: { present(.overview) }),
            PaletteCommand(id: "show-files", title: "Files · Show Project Files", subtitle: "Browse the active tab's folder in a drawer over the terminal",
                           keywords: ["files", "tree", "browse", "folder", "explorer", "project"], icon: "folder", shortcut: nil,
                           run: { app.drawer.open(.files, directory: app.activeDirectory) }),
            PaletteCommand(id: "show-changes", title: "Git · Show Changes", subtitle: "Changed files and their diffs",
                           keywords: ["changes", "diff", "git", "modified", "status"], icon: "plusminus", shortcut: nil,
                           run: { app.drawer.open(.changes, directory: app.activeDirectory) }),
            PaletteCommand(id: "open-skills", title: "Skills Directory", subtitle: "Browse skills.sh and install",
                           keywords: ["skills", "directory", "install", "browse"], icon: "puzzlepiece.extension", shortcut: nil,
                           run: { present(.skills) }),
            PaletteCommand(id: "open-settings", title: "Settings", subtitle: "Font, binary path, auto-start",
                           keywords: ["settings", "preferences", "config"], icon: "gearshape", shortcut: "⌘,",
                           run: openSettings),
            PaletteCommand(id: "clear", title: "Clear Terminal", subtitle: "Send Ctrl+L to the active session",
                           keywords: ["clear", "redraw", "ctrl-l"], icon: "arrow.up.and.line.horizontal.and.arrow.down", shortcut: "⌘L",
                           run: { tabs.activeSession?.clearScreen() }),
            PaletteCommand(id: "interrupt", title: "Interrupt", subtitle: "Send Ctrl+C to the active session",
                           keywords: ["interrupt", "ctrl-c", "cancel", "stop"], icon: "stop.circle", shortcut: "⌃⌘C",
                           run: { tabs.activeSession?.interrupt() }),
            PaletteCommand(id: "compact", title: "Claude · Compact", subtitle: "Send /compact to active session",
                           keywords: ["compact", "claude", "summary"], icon: "rectangle.compress.vertical", shortcut: nil,
                           run: { app.runInActiveSession("/compact") }),
            PaletteCommand(id: "memory", title: "Claude · Memory", subtitle: "Send /memory to active session",
                           keywords: ["memory", "claude"], icon: "brain", shortcut: nil,
                           run: { app.runInActiveSession("/memory") }),
            PaletteCommand(id: "goal", title: "Claude · Goal", subtitle: "Type /goal into the active session, then the condition",
                           keywords: ["goal", "claude", "stop", "until"], icon: "flag.checkered", shortcut: nil,
                           run: { app.startGoal() }),
            PaletteCommand(id: "cheatsheet", title: "Keyboard Shortcuts", subtitle: "Every hotkey Xylem listens to",
                           keywords: ["shortcuts", "cheatsheet", "keyboard", "help"], icon: "keyboard", shortcut: "⌘/",
                           run: { present(.cheatsheet) }),
            PaletteCommand(id: "refresh-sidebar", title: "Refresh Sidebar", subtitle: "Reload Claude state and sessions",
                           keywords: ["refresh", "reload", "sidebar"], icon: "arrow.clockwise", shortcut: nil,
                           run: { app.refreshSidebar() })
        ]

        if app.worktreeBaseDirectory != nil {
            commands.append(PaletteCommand(
                id: "new-worktree-tab", title: "Git · New Worktree Tab…",
                subtitle: "A new branch in its own checkout, with its own Claude",
                keywords: ["worktree", "git", "branch", "parallel", "tab"], icon: "arrow.triangle.branch", shortcut: nil,
                run: { present(.newWorktree) }
            ))
        }

        // Model switches for the active session.
        if app.activeSession?.launchedClaude == true {
            for choice in ClaudeModelChoice.all {
                commands.append(PaletteCommand(
                    id: "model-\(choice.alias)", title: "Claude · Switch to \(choice.title)",
                    subtitle: "Send \(choice.command) to active session",
                    keywords: ["model", "switch", choice.alias, choice.title], icon: "cpu", shortcut: nil,
                    run: { app.switchModel(to: choice) }
                ))
            }
            for choice in ClaudeEffortChoice.levels {
                commands.append(PaletteCommand(
                    id: "effort-\(choice.level)", title: "Claude · Effort \(choice.title)",
                    subtitle: "For the active session only (/effort)",
                    keywords: ["effort", "thinking", "reasoning", choice.level, choice.title], icon: "brain", shortcut: nil,
                    run: { app.switchEffort(to: choice) }
                ))
            }
        }

        // Per-tab switchers - makes ⌘K a tab jumper too.
        for (index, tab) in tabs.tabs.enumerated() {
            let n = index + 1
            commands.append(PaletteCommand(
                id: "switch-tab-\(tab.id)", title: "Switch to: \(tab.title)", subtitle: tab.workingDirectory,
                keywords: ["switch", "tab", tab.title], icon: "arrow.right.circle", shortcut: n <= 9 ? "⌘\(n)" : nil,
                run: { tabs.select(tab.id) }
            ))
        }
        return commands
    }

    /// The palette's "Prompts" section: past prompts, resumed on pick.
    static func prompts(app: AppModel) -> PalettePromptSource {
        PalettePromptSource(history: app.promptHistory, open: { app.openPromptSession($0) })
    }

    static func toolbar(app: AppModel, present: @escaping (ActiveSheet) -> Void) -> BottomToolbarActions {
        var actions = BottomToolbarActions()
        // Clear sends `/clear` so the conversation resets; ⌘L / "Clear
        // Terminal" still send Ctrl+L for a scrollback redraw.
        actions.onClear = { app.runInActiveSession("/clear") }
        actions.onCompact = { app.runInActiveSession("/compact") }
        actions.onMemory = { app.runInActiveSession("/memory") }
        actions.onGoal = { app.startGoal() }
        actions.onCopy = { app.copySelection() }
        actions.onScreenshot = { app.captureScreenshot() }
        actions.onAttachFile = { app.attachFile() }
        actions.onAttachImage = { app.attachFile(.image) }
        actions.onNewWorktree = { if app.worktreeBaseDirectory != nil { present(.newWorktree) } }
        return actions
    }
}
