//
//  OpenPanels.swift
//  Xylem
//
//  The app's NSOpenPanels, one per purpose, made on first use and reused.
//  A new `NSOpenPanel()` per pick kept about 16 MB alive on macOS 15
//  (Intel, measured with malloc_history: CoreGraphics image data allocated
//  while the panel ran, never freed - 8 picks, 131 MB). macOS 26 frees it.
//  Reusing the panel bounds that to one panel per purpose, and each one
//  remembers its own folder (the editor picker's /Applications doesn't leak
//  into the project-folder picker).
//

import AppKit
import UniformTypeIdentifiers

@MainActor
enum OpenPanels {
    enum Purpose: Hashable {
        /// A project folder (New Tab, ⌘O, Directories "+", onboarding).
        case projectFolder
        /// Any file, its path typed into Claude.
        case file
        /// An image, its path typed into Claude.
        case image
        /// The editor the drawer's Open button uses.
        case application
        /// Settings > Claude Code > Binary path.
        case claudeBinary
    }

    private static var panels: [Purpose: NSOpenPanel] = [:]

    /// Runs the panel for `purpose` modally: the picked URL, nil when cancelled.
    static func pick(_ purpose: Purpose) -> URL? {
        let panel = panels[purpose] ?? make(purpose)
        panels[purpose] = panel
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func make(_ purpose: Purpose) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        switch purpose {
        case .projectFolder:
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.prompt = "Open"
            panel.title = "Choose a project folder"
        case .file, .image:
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            if purpose == .image { panel.allowedContentTypes = [.image] }
        case .application:
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.applicationBundle]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.prompt = "Use This App"
        case .claudeBinary:
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.treatsFilePackagesAsDirectories = true
        }
        return panel
    }
}
