//
//  AboutPanelTests.swift
//  XylemTests
//

import Testing
import Foundation

struct AboutPanelTests {
    private func date(_ year: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = 6
        components.day = 1
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    @Test func theFirstYearStandsAlone() {
        #expect(AboutPanel.copyright(now: date(2026)) == "Copyright © 2026 t1nkl")
    }

    @Test func laterYearsBecomeARange() {
        #expect(AboutPanel.copyright(now: date(2027)) == "Copyright © 2026-2027 t1nkl")
        #expect(AboutPanel.copyright(now: date(2031)) == "Copyright © 2026-2031 t1nkl")
    }
}
