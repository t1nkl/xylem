//
//  HotkeyStore.swift
//  Xylem
//
//  User-overridable keyboard shortcuts. Bindings are stored in
//  ~/.xylem/keybindings.json; defaults are baked into code and merged at
//  read time so the user only persists the overrides they care about.
//
//  Changes apply live: the resolved bindings live in `HotkeyRegistry`, an
//  @Observable the menu commands read, so SwiftUI rebuilds the menu when a
//  binding changes - from Settings, or from a hand edit of
//  keybindings.json (the registry watches the file).
//
//  Overrides are read from disk once and kept in memory (XylemApp asks for
//  nine shortcuts at launch and the cheatsheet resolves all of them on
//  open). `set` / `reset`
//  re-read the file before writing so hand edits to keybindings.json are
//  never clobbered by a stale in-memory copy; `reload()` drops the cache.
//

import Foundation
import SwiftUI

enum HotkeyAction: String, CaseIterable, Codable, Identifiable {
    case newTab, closeTab, closeOtherTabs, nextWaitingTab
    case clear, interrupt
    case commandPalette
    case findInTerminal, findNextMatch, findPreviousMatch
    case togglePanel
    case openFolder, toggleTabList
    case showClaude, showGit, showFiles, showChanges

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .newTab:         return "New Tab"
        case .closeTab:       return "Close Tab"
        case .closeOtherTabs: return "Close Other Tabs"
        case .nextWaitingTab: return "Next Tab Waiting for You"
        case .clear:          return "Clear Terminal"
        case .interrupt:      return "Interrupt"
        case .commandPalette: return "Command Palette"
        case .findInTerminal:      return "Find in Terminal"
        case .findNextMatch:       return "Find Next"
        case .findPreviousMatch:   return "Find Previous"
        case .togglePanel:         return "Show / Hide Claude / Git Panel"
        case .openFolder:          return "Open Folder"
        case .toggleTabList:       return "Show / Hide Tab List"
        case .showClaude:          return "Claude Panel"
        case .showGit:             return "Git Panel"
        case .showFiles:           return "Files"
        case .showChanges:         return "Changes"
        }
    }
}

struct HotkeyBinding: Codable, Hashable {
    /// Either a character ("d", "w") or a named key ("leftArrow", "return").
    let key: String
    /// Subset of ["cmd", "shift", "option", "control"].
    let modifiers: [String]

    /// User-facing rendering: "⌘⇧D"
    var display: String {
        var parts = ""
        let order: [(String, String)] = [("control", "⌃"), ("option", "⌥"), ("shift", "⇧"), ("cmd", "⌘")]
        for (name, glyph) in order where modifiers.contains(name) {
            parts.append(glyph)
        }
        parts.append(Self.keyGlyph(for: key))
        return parts
    }

    private static func keyGlyph(for key: String) -> String {
        switch key {
        case "leftArrow":  return "←"
        case "rightArrow": return "→"
        case "upArrow":    return "↑"
        case "downArrow":  return "↓"
        case "return":     return "↩"
        case "escape":     return "⎋"
        default:           return key.uppercased()
        }
    }

    /// Parses strings like "cmd+shift+d" or "⌘⇧D" into a binding. Unknown
    /// tokens are ignored so the user gets a best-effort result.
    static func parse(_ raw: String) -> HotkeyBinding? {
        let cleaned = raw.lowercased()
            .replacingOccurrences(of: "⌘", with: "cmd+")
            .replacingOccurrences(of: "⇧", with: "shift+")
            .replacingOccurrences(of: "⌥", with: "option+")
            .replacingOccurrences(of: "⌃", with: "control+")
            .replacingOccurrences(of: " ", with: "")
        let parts = cleaned.split(separator: "+").map(String.init)
        var modifiers: [String] = []
        var key: String?
        for part in parts {
            switch part {
            case "cmd", "command", "meta": modifiers.append("cmd")
            case "shift":   modifiers.append("shift")
            case "option", "alt", "opt": modifiers.append("option")
            case "control", "ctrl": modifiers.append("control")
            default: key = part
            }
        }
        guard let key, !key.isEmpty else { return nil }
        return HotkeyBinding(key: key, modifiers: Array(Set(modifiers)))
    }

    var keyEquivalent: KeyEquivalent? {
        switch key {
        case "leftArrow":  return .leftArrow
        case "rightArrow": return .rightArrow
        case "upArrow":    return .upArrow
        case "downArrow":  return .downArrow
        case "return":     return .return
        case "escape":     return .escape
        case "space":      return .space
        case "tab":        return .tab
        default:
            guard let first = key.first else { return nil }
            return KeyEquivalent(Character(String(first).lowercased()))
        }
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains("cmd")     { result.insert(.command) }
        if modifiers.contains("shift")   { result.insert(.shift) }
        if modifiers.contains("option")  { result.insert(.option) }
        if modifiers.contains("control") { result.insert(.control) }
        return result
    }
}

struct HotkeyStore {
    static let defaults: [HotkeyAction: HotkeyBinding] = [
        .newTab:         HotkeyBinding(key: "t", modifiers: ["cmd"]),
        .closeTab:       HotkeyBinding(key: "w", modifiers: ["cmd"]),
        .closeOtherTabs: HotkeyBinding(key: "w", modifiers: ["cmd", "option"]),
        .nextWaitingTab: HotkeyBinding(key: "u", modifiers: ["cmd", "control"]),
        .clear:          HotkeyBinding(key: "l", modifiers: ["cmd"]),
        .interrupt:      HotkeyBinding(key: "c", modifiers: ["cmd", "control"]),
        .commandPalette: HotkeyBinding(key: "k", modifiers: ["cmd"]),
        .findInTerminal:     HotkeyBinding(key: "f", modifiers: ["cmd"]),
        .findNextMatch:      HotkeyBinding(key: "g", modifiers: ["cmd"]),
        .findPreviousMatch:  HotkeyBinding(key: "g", modifiers: ["cmd", "shift"]),
        // The system inspector's shortcut, kept for the custom panel.
        .togglePanel:        HotkeyBinding(key: "i", modifiers: ["cmd", "control"]),
        .openFolder:         HotkeyBinding(key: "o", modifiers: ["cmd"]),
        .toggleTabList:      HotkeyBinding(key: "s", modifiers: ["cmd", "control"]),
        // The panel rail, top to bottom.
        .showClaude:         HotkeyBinding(key: "1", modifiers: ["cmd", "control"]),
        .showGit:            HotkeyBinding(key: "2", modifiers: ["cmd", "control"]),
        .showFiles:          HotkeyBinding(key: "3", modifiers: ["cmd", "control"]),
        .showChanges:        HotkeyBinding(key: "4", modifiers: ["cmd", "control"])
    ]

    /// Backing store for the static API. Tests build their own
    /// `HotkeyOverridesStore` on a temp file instead of touching this one.
    static let shared = HotkeyOverridesStore(
        fileURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".xylem/keybindings.json")
    )

    /// Resolved bindings (defaults overridden by the user's JSON file).
    /// Read through the observable registry, so a view or menu that asks
    /// is rebuilt when a binding changes.
    static func all() -> [HotkeyAction: HotkeyBinding] {
        HotkeyRegistry.shared.bindings
    }

    static func binding(for action: HotkeyAction) -> HotkeyBinding {
        all()[action] ?? defaults[action]!
    }

    static func shortcut(for action: HotkeyAction) -> KeyboardShortcut? {
        let b = binding(for: action)
        guard let ke = b.keyEquivalent else { return nil }
        return KeyboardShortcut(ke, modifiers: b.eventModifiers)
    }

    static func set(_ binding: HotkeyBinding, for action: HotkeyAction) {
        shared.set(binding, for: action)
        HotkeyRegistry.shared.refresh()
    }

    static func reset(_ action: HotkeyAction) {
        shared.reset(action)
        HotkeyRegistry.shared.refresh()
    }

    /// Forgets the in-memory overrides and re-reads keybindings.json (edits
    /// made outside the app).
    static func reload() {
        shared.invalidate()
        HotkeyRegistry.shared.refresh()
    }

    /// Defaults with every recognised override applied; unknown action
    /// names in the file are ignored.
    static func resolve(overrides: [String: HotkeyBinding]) -> [HotkeyAction: HotkeyBinding] {
        var result = defaults
        for (key, binding) in overrides {
            guard let action = HotkeyAction(rawValue: key) else { continue }
            result[action] = binding
        }
        return result
    }
}

/// keybindings.json with a read-once in-memory copy of its contents.
final class HotkeyOverridesStore {
    let fileURL: URL
    private var cached: [String: HotkeyBinding]?
    /// Number of times the file was actually read; lets tests prove reads
    /// are served from memory.
    private(set) var diskReadCount = 0

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func overrides() -> [String: HotkeyBinding] {
        if let cached { return cached }
        let loaded = readFromDisk()
        cached = loaded
        return loaded
    }

    func set(_ binding: HotkeyBinding, for action: HotkeyAction) {
        // Fresh read, not `cached`: the user may have hand-edited the file
        // since it was loaded, and writing the stale copy would drop that.
        var overrides = readFromDisk()
        overrides[action.rawValue] = binding
        write(overrides)
    }

    func reset(_ action: HotkeyAction) {
        var overrides = readFromDisk()
        overrides.removeValue(forKey: action.rawValue)
        write(overrides)
    }

    func invalidate() {
        cached = nil
    }

    private func readFromDisk() -> [String: HotkeyBinding] {
        diskReadCount += 1
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: HotkeyBinding].self, from: data)) ?? [:]
    }

    private func write(_ overrides: [String: HotkeyBinding]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(overrides)
            try data.write(to: fileURL, options: .atomic)
            cached = overrides
        } catch {
            // Non-fatal - next save attempts again. Drop the cache so the
            // next read reflects whatever is actually on disk.
            cached = nil
        }
    }
}

/// The resolved bindings as observable state. The menu commands in
/// XylemApp read `bindings` (through `HotkeyStore.shortcut`), so a change
/// re-evaluates them and the new shortcut works without a relaunch.
@Observable
final class HotkeyRegistry {
    static let shared = HotkeyRegistry()

    private(set) var bindings: [HotkeyAction: HotkeyBinding]
    @ObservationIgnored private let watcher = FileSystemWatcher()

    private init() {
        bindings = HotkeyStore.resolve(overrides: HotkeyStore.shared.overrides())
        // keybindings.json edited by hand: pick it up. Our own writes land
        // here too and resolve to the same bindings (no change published).
        watcher.setHandler {
            Task { @MainActor in HotkeyStore.reload() }
        }
        watcher.watch(paths: Self.watchedPaths)
    }

    /// The file, and its folder: a keybindings.json created by hand after
    /// launch shows up only as a change of the folder. Other files there
    /// (tabs-state.json) also wake it; the reload is a small read and
    /// publishes nothing when the bindings are the same.
    private static var watchedPaths: [String] {
        let file = HotkeyStore.shared.fileURL
        return [file.path, file.deletingLastPathComponent().path]
    }

    func refresh() {
        let fresh = HotkeyStore.resolve(overrides: HotkeyStore.shared.overrides())
        if fresh != bindings { bindings = fresh }
        // Re-arm: the file may have been created or replaced.
        watcher.watch(paths: Self.watchedPaths)
    }
}
