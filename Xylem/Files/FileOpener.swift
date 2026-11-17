//
//  FileOpener.swift
//  Xylem
//
//  Where the drawer's "Open" sends a file: the app picked in Settings →
//  General → Open files in (VS Code, PhpStorm, Xcode…) or the system's
//  default app for that file. The first "Open" with nothing picked asks
//  once, offering the editors that are installed.
//

import AppKit
import UniformTypeIdentifiers

@MainActor
enum FileOpener {
    /// Common code editors, by bundle id, in the order the picker lists them.
    static let knownEditors = [
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.sublimetext.4",
        "com.jetbrains.PhpStorm", "com.jetbrains.WebStorm", "com.jetbrains.intellij", "com.jetbrains.intellij.ce",
        "com.jetbrains.pycharm", "com.jetbrains.pycharm.ce", "com.jetbrains.goland", "com.jetbrains.rubymine",
        "com.jetbrains.fleet", "com.apple.dt.Xcode", "com.panic.Nova", "com.barebones.bbedit", "com.apple.TextEdit",
    ]

    /// The known editors that are installed (Launch Services' copy of each).
    static func installedEditors() -> [URL] {
        knownEditors.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    /// The picked app, nil = the system default (or the picked one was
    /// moved or deleted).
    static var chosenApp: URL? {
        let path = UserDefaults.standard.string(forKey: AppSettings.Keys.openFilesWith) ?? ""
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// "Visual Studio Code", or nil for the system default.
    static var chosenAppName: String? { chosenApp.map(appName) }

    static func appName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Saves the choice: an app, or nil for the system default.
    static func choose(_ app: URL?) {
        UserDefaults.standard.set(app?.path ?? "", forKey: AppSettings.Keys.openFilesWith)
        UserDefaults.standard.set(true, forKey: AppSettings.Keys.openFilesWithAsked)
    }

    static func open(_ path: String) {
        let file = URL(fileURLWithPath: path)
        if chosenApp == nil, !UserDefaults.standard.bool(forKey: AppSettings.Keys.openFilesWithAsked) {
            guard askOnce() else { return }   // the user cancelled: open nothing
        }
        if let app = chosenApp {
            NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(file)
        }
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// An app picked in a file panel (any .app), nil when cancelled.
    static func pickApp() -> URL? {
        return OpenPanels.pick(.application)
    }

    /// First "Open" with nothing picked: which app? The installed editors,
    /// the system default, or any other app. False when cancelled.
    private static func askOnce() -> Bool {
        let editors = installedEditors()
        let alert = NSAlert()
        alert.messageText = "Open files in which app?"
        alert.informativeText = "Xylem will use it for every file it opens. You can change it in Settings → General → Open files in."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        popup.addItem(withTitle: "Default app for each file")
        for editor in editors {
            popup.addItem(withTitle: appName(editor))
            popup.lastItem?.image = NSWorkspace.shared.icon(forFile: editor.path)
            popup.lastItem?.image?.size = NSSize(width: 16, height: 16)
        }
        popup.addItem(withTitle: "Other App…")
        // An editor is the likelier wish than Preview/TextEdit defaults.
        if !editors.isEmpty { popup.selectItem(at: 1) }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let index = popup.indexOfSelectedItem
        if index == 0 {
            choose(nil)
        } else if index <= editors.count {
            choose(editors[index - 1])
        } else {
            guard let other = pickApp() else { return false }
            choose(other)
        }
        return true
    }
}
