//
//  WhatsNew.swift
//  Xylem
//
//  "What's new" after an update. Most updates install on quit, where
//  Sparkle shows no notes, so a plain restart would show no changelog.
//  So when Sparkle stages an update, its notes from the
//  appcast are kept here, and the first launch of that version shows them
//  once (WhatsNewSheet). No network is needed after the restart.
//

import Foundation

nonisolated enum WhatsNewStore {
    struct Pending: Codable, Equatable, Identifiable {
        let version: String
        /// The appcast item's description: our release notes, markdown.
        let notes: String
        var id: String { version }
    }

    static let defaultsKey = "whatsNewPending"

    /// Sparkle staged `version`; keep its notes for its first launch.
    static func remember(version: String, notes: String, defaults: UserDefaults = .standard) {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = try? JSONEncoder().encode(Pending(version: version, notes: trimmed))
        else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// The notes to show now, at most once: those of the running version.
    /// Notes of an older version are dropped; a newer one's (staged, not
    /// installed yet) are kept for its own launch.
    static func take(runningVersion: String, defaults: UserDefaults = .standard) -> Pending? {
        guard let data = defaults.data(forKey: defaultsKey),
              let pending = try? JSONDecoder().decode(Pending.self, from: data)
        else { return nil }
        switch pending.version.compare(runningVersion, options: .numeric) {
        case .orderedSame:
            defaults.removeObject(forKey: defaultsKey)
            return pending
        case .orderedAscending:
            defaults.removeObject(forKey: defaultsKey)
            return nil
        case .orderedDescending:
            return nil
        }
    }

    /// Sparkle's own window showed the notes (Install and Relaunch).
    static func forget(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    static var runningVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}

/// Our release notes' shape: "### New / Improved / Fixed" headings with
/// "- " items (release-notes/*.md). Anything else becomes an item of the
/// current section.
nonisolated struct ReleaseNotes: Equatable {
    struct Section: Equatable {
        var title: String?
        var items: [String]
    }

    var sections: [Section]

    init(markdown: String) {
        var sections: [Section] = []
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                sections.append(Section(title: title.isEmpty ? nil : title, items: []))
                continue
            }
            let item = line.hasPrefix("- ") || line.hasPrefix("* ") ? String(line.dropFirst(2)) : line
            if sections.isEmpty { sections.append(Section(title: nil, items: [])) }
            sections[sections.count - 1].items.append(item)
        }
        self.sections = sections.filter { !$0.items.isEmpty }
    }
}
