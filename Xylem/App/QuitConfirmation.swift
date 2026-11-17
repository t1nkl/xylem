//
//  QuitConfirmation.swift
//  Xylem
//
//  Quitting Xylem ends the claude in every tab. A tab at its prompt loses
//  nothing - it resumes its session on the next launch - but a running turn
//  is cut off mid-work and an open permission prompt goes unanswered. So ⌘Q
//  (and a logout, an update) asks first while any tab is in one of those
//  two states, and says which tabs; otherwise it quits at once, like any
//  Mac app. "Don't ask again" turns it off (Settings → General brings it
//  back).
//

import AppKit

/// Which tabs would lose work on quit, and how to say it. Pure.
struct QuitConfirmation: Equatable {
    let working: [String]
    let waiting: [String]

    /// nil when nothing would be lost.
    init?(tabs: [TerminalTab]) {
        var working: [String] = []
        var waiting: [String] = []
        for tab in tabs {
            switch Self.risk(of: tab) {
            case .working: working.append(tab.displayTitle)
            case .waiting: waiting.append(tab.displayTitle)
            case nil: break
            }
        }
        guard !working.isEmpty || !waiting.isEmpty else { return nil }
        self.working = working
        self.waiting = waiting
    }

    enum Risk { case working, waiting }

    /// Hook state when there is one; without hooks, the transcript still
    /// advancing (`isBusy`) is the only sign of a running turn.
    static func risk(of tab: TerminalTab) -> Risk? {
        switch tab.claudeState {
        case .working: return .working
        case .needsInput: return .waiting
        case nil: return tab.isBusy ? .working : nil
        default: return nil
        }
    }

    var title: String {
        let count = working.count + waiting.count
        if waiting.isEmpty { return "Claude is still working in \(Self.tabs(count))" }
        if working.isEmpty { return "Claude is waiting for your answer in \(Self.tabs(count))" }
        return "Claude is busy in \(Self.tabs(count))"
    }

    var message: String {
        var lines: [String] = []
        if !working.isEmpty { lines.append("Working: " + working.joined(separator: ", ")) }
        if !waiting.isEmpty { lines.append("Waiting for you: " + waiting.joined(separator: ", ")) }
        lines.append("Quitting stops them now. The sessions resume on the next launch, but an unfinished turn is cut off.")
        return lines.joined(separator: "\n")
    }

    private static func tabs(_ count: Int) -> String {
        count == 1 ? "1 tab" : "\(count) tabs"
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
