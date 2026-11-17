//
//  AboutPanel.swift
//  Xylem
//
//  The standard About window with a copyright line that keeps up with the
//  calendar: "Copyright © 2026 t1nkl" this year, "Copyright © 2026-2027
//  t1nkl" from next year on, without a rebuild. The Info.plist line
//  (Finder's Get Info) stays the first year.
//

import AppKit

enum AboutPanel {
    static let firstYear = 2026
    static let holder = "t1nkl"

    static func copyright(now: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let year = calendar.component(.year, from: now)
        let years = year > firstYear ? "\(firstYear)-\(year)" : "\(firstYear)"
        return "Copyright © \(years) \(holder)"
    }

    static func show() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): copyright()
        ])
    }
}
