//
//  RecentProjectColourTests.swift
//  XylemTests
//
//  A recent project's card colour comes from its name: the same on every
//  launch (String.hashValue is seeded per process) and spread evenly over
//  the palette.
//

import Testing

struct RecentProjectColourTests {

    @Test func cardColourIsStableAcrossLaunches() {
        // Fixed values: the same in every process (hashValue is not).
        #expect(NewTabPickerView.accentIndex(for: "billing-api", count: 6) == 2)
        #expect(NewTabPickerView.accentIndex(for: "storefront", count: 6) == 1)
        #expect(NewTabPickerView.accentIndex(for: "notes", count: 6) == 5)
        #expect(NewTabPickerView.accentIndex(for: "", count: 6) == 2)
        #expect(NewTabPickerView.accentIndex(for: "x", count: 0) == 0)
    }

    @Test func cardColoursSpreadOverThePalette() {
        // Every byte of these names is odd ("a", "c", "e", "g"), so plain
        // FNV-1a gave them one parity: only colours 1, 3 and 5.
        let letters = ["a", "c", "e", "g"]
        let names = letters.flatMap { a in letters.flatMap { b in letters.flatMap { c in letters.map { a + b + c + $0 } } } }
        var counts = [Int](repeating: 0, count: 6)
        for name in names { counts[NewTabPickerView.accentIndex(for: name, count: 6)] += 1 }
        let expected = Double(names.count) / 6
        #expect(counts.allSatisfy { Double($0) > expected * 0.75 && Double($0) < expected * 1.25 })
    }
}
