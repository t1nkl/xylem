//
//  CodeTextViewTests.swift
//  XylemTests
//
//  The drawer's code view selects across lines and copies just the code:
//  no line numbers, no +/- markers, no hunk headers or notes. Colours
//  arriving later keep the selection. One test also draws a sample diff
//  to a PNG (XYLEM_SNAPSHOT_DIR) for a look at it.
//

import Testing
import AppKit
import SwiftUI

@MainActor
struct CodeTextViewTests {
    private func makeView(_ lines: [CodeTextLine], columns: [CodeGutterColumn] = [CodeGutterColumn(width: 30)]) -> CodeNSTextView {
        let view = CodeNSTextView(usingTextLayoutManager: false)
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 260)
        view.isEditable = false
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.lineFragmentPadding = 0
        view.drawsBackground = false
        view.show(lines, columns: columns)
        return view
    }

    private let diff: [CodeTextLine] = [
        CodeTextLine(text: "@@ -1,3 +1,4 @@", kind: .hunk, gutter: ["", "", ""]),
        CodeTextLine(text: "func total() -> Int {", gutter: ["1", "1", ""]),
        CodeTextLine(text: "    let a = 1", kind: .removed, gutter: ["2", "", "-"]),
        CodeTextLine(text: "    let a = 2", kind: .added, gutter: ["", "2", "+"]),
        CodeTextLine(text: "", kind: .added, gutter: ["", "3", "+"]),
        CodeTextLine(text: "    return a", gutter: ["3", "4", ""]),
        CodeTextLine(text: "}", gutter: ["4", "5", ""])
    ]

    @Test func copyingAcrossLinesGivesJustTheCode() {
        let view = makeView(diff)
        view.selectAll(nil)
        // No hunk header, no numbers, no markers; the blank added line stays.
        #expect(view.copiedText() == "func total() -> Int {\n    let a = 1\n    let a = 2\n\n    return a\n}")
    }

    @Test func aPartialSelectionCopiesItsPart() {
        let view = makeView(diff)
        let text = view.string as NSString
        let start = text.range(of: "a = 1").location
        let end = NSMaxRange(text.range(of: "let a = 2"))
        view.setSelectedRange(NSRange(location: start, length: end - start))
        #expect(view.copiedText() == "a = 1\n    let a = 2")
    }

    @Test func aSelectionInsideOneHunkHeaderCopiesNothing() {
        let view = makeView(diff)
        view.setSelectedRange(NSRange(location: 0, length: 5))
        #expect(view.copiedText() == "")
    }

    @Test func coloursArrivingKeepTheSelection() {
        let view = makeView(diff)
        let selection = NSRange(location: 20, length: 12)
        view.setSelectedRange(selection)
        var coloured = diff
        coloured[1].runs = [SyntaxRun(text: "func", scope: .keyword), SyntaxRun(text: " total() -> Int {", scope: nil)]
        view.show(coloured, columns: [CodeGutterColumn(width: 30)])
        #expect(view.selectedRange() == selection)
        // New text (another file) starts unselected.
        view.show([CodeTextLine(text: "other")], columns: [CodeGutterColumn(width: 30)])
        #expect(view.selectedRange().length == 0)
        #expect(view.string == "other")
    }

    /// Colours never cross into the next line, even when a run list is
    /// longer than its line's text.
    @Test func runsStayInsideTheirLine() throws {
        let lines = [CodeTextLine(text: "ab", runs: [SyntaxRun(text: "abcdef", scope: .keyword)]),
                     CodeTextLine(text: "cd")]
        let view = makeView(lines)
        let storage = try #require(view.textStorage)
        let first = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let next = storage.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor
        #expect(first != next)
    }

    /// Redrawing only the gutter strip (scrolling back to the left edge)
    /// still draws the line numbers.
    @Test func aGutterOnlyRedrawKeepsTheNumbers() throws {
        let view = makeView(diff, columns: [CodeGutterColumn(width: 40)])
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let gutter = NSRect(x: 0, y: 0, width: 40, height: 120)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: gutter))
        view.cacheDisplay(in: gutter, to: rep)
        let background = rep.colorAt(x: 1, y: 1)
        var differing = 0
        for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh where rep.colorAt(x: x, y: y) != background { differing += 1 } }
        #expect(differing > 20, "no digits drawn in the gutter")
    }

    /// Draws the sample diff for a visual check when XYLEM_SNAPSHOT_DIR is set.
    @Test func drawsASampleDiff() throws {
        guard let dir = ProcessInfo.processInfo.environment["XYLEM_SNAPSHOT_DIR"] else { return }
        let width: CGFloat = 7.5 + 10
        let view = makeView(diff, columns: [
            CodeGutterColumn(width: width), CodeGutterColumn(width: width),
            CodeGutterColumn(width: 18, alignment: .center, colouredByKind: true)
        ])
        view.textContainerInset = NSSize(width: width * 2 + 18 + 10, height: 6)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        view.setSelectedRange((view.string as NSString).range(of: "let a = 2\n\n    return"))
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("code-text-view.png"))
    }
}
