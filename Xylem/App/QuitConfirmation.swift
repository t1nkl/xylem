//
//  QuitConfirmation.swift
//  Xylem
//
//  Quitting Xylem ends the claude in every tab. A tab at its prompt loses
//  nothing - it resumes its session on the next launch - but a running turn
//  is cut off mid-work and an open permission prompt goes unanswered. So ⌘Q
//  (and a logout, an update) asks first while any tab is in one of those
//  two states, and says which tabs; otherwise it quits at once, like any
//  Mac app. Background tasks a tab's claude still runs (a dev server, a
//  long build) end with it too, so they count as well. "Don't ask again"
//  turns it off (Settings → General brings it back).
//

import AppKit

/// Which tabs would lose work on quit, and how to say it. Pure.
struct QuitConfirmation: Equatable {
    let working: [String]
    let waiting: [String]
    /// Tabs (not already working or waiting) with background tasks running.
    var background: [String] = []

    /// nil when nothing would be lost.
    init?(tabs: [TerminalTab]) {
        var working: [String] = []
        var waiting: [String] = []
        var background: [String] = []
        for tab in tabs {
            switch Self.risk(of: tab) {
            case .working: working.append(tab.displayTitle)
            case .waiting: waiting.append(tab.displayTitle)
            case .background: background.append(tab.displayTitle)
            case nil: break
            }
        }
        guard !working.isEmpty || !waiting.isEmpty || !background.isEmpty else { return nil }
        self.working = working
        self.waiting = waiting
        self.background = background
    }

    enum Risk { case working, waiting, background }

    /// Hook state when there is one; without hooks, the transcript still
    /// advancing (`isBusy`) is the only sign of a running turn. A tab at its
    /// prompt still loses the background tasks it runs.
    static func risk(of tab: TerminalTab) -> Risk? {
        switch tab.claudeState {
        case .working: return .working
        case .needsInput: return .waiting
        case nil where tab.isBusy: return .working
        default: return tab.runningBackgroundTasks > 0 ? .background : nil
        }
    }

    var title: String {
        if working.isEmpty && waiting.isEmpty {
            return "Background tasks are running in \(Self.tabs(background.count))"
        }
        let count = working.count + waiting.count + background.count
        if waiting.isEmpty && background.isEmpty { return "Claude is still working in \(Self.tabs(count))" }
        if working.isEmpty && background.isEmpty { return "Claude is waiting for your answer in \(Self.tabs(count))" }
        return "Claude is busy in \(Self.tabs(count))"
    }

    var message: String {
        var lines: [String] = []
        if !working.isEmpty { lines.append("Working: " + working.joined(separator: ", ")) }
        if !waiting.isEmpty { lines.append("Waiting for you: " + waiting.joined(separator: ", ")) }
        if !background.isEmpty { lines.append("Background tasks: " + background.joined(separator: ", ")) }
        lines.append(working.isEmpty && waiting.isEmpty
            ? "Quitting ends those tasks now. The sessions resume on the next launch."
            : "Quitting stops them now. The sessions resume on the next launch, but an unfinished turn is cut off.")
        return lines.joined(separator: "\n")
    }

    static func tabs(_ count: Int) -> String {
        count == 1 ? "1 tab" : "\(count) tabs"
    }
}

/// Closing a tab ends its claude and with it the background tasks it runs
/// (a dev server, a long build): asked first only then. Pure; AppModel
/// shows the alert.
struct CloseTabConfirmation: Equatable {
    struct Entry: Equatable {
        let title: String
        let tasks: Int
    }

    /// Each closing tab with tasks and how many.
    let tabs: [Entry]

    /// nil when no closing tab has a task running.
    init?(closing: [TerminalTab]) {
        let found = closing.filter { $0.runningBackgroundTasks > 0 }
            .map { Entry(title: $0.displayTitle, tasks: $0.runningBackgroundTasks) }
        guard !found.isEmpty else { return nil }
        tabs = found
    }

    var title: String {
        let total = tabs.reduce(0) { $0 + $1.tasks }
        let tasks = total == 1 ? "1 background task" : "\(total) background tasks"
        if tabs.count == 1 { return "\(tabs[0].title) has \(tasks) running" }
        return "\(QuitConfirmation.tabs(tabs.count)) have \(tasks) running"
    }

    var message: String {
        let list = tabs.count == 1 ? "" : tabs.map { "\($0.title): \($0.tasks)" }.joined(separator: "\n") + "\n"
        return list + "Counted when Claude last replied. Closing ends them now; the session itself can be resumed later."
    }

    @MainActor
    func ask() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: tabs.count == 1 ? "Close Tab" : "Close Tabs")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Only here for `applicationShouldTerminate`; SwiftUI keeps the rest.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by XylemApp once the window is up. Nil = nothing to guard yet.
    weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppSettings.confirmQuitWhileClaudeWorks,
              let model, let confirmation = QuitConfirmation(tabs: model.tabs.tabs)
        else { return .terminateNow }
        return Self.ask(confirmation) ? .terminateNow : .terminateCancel
    }

    private static func ask(_ confirmation: QuitConfirmation) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.message
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let quit = alert.runModal() == .alertFirstButtonReturn
        // "Don't ask again" + Cancel would be a no-op promise: only a
        // confirmed quit turns the question off.
        if quit, alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(false, forKey: AppSettings.Keys.confirmQuitWhileClaudeWorks)
        }
        return quit
    }
}
