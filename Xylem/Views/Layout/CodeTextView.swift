//
//  CodeTextView.swift
//  Xylem
//
//  Read-only code for the drawer: the Files preview and the Changes diff.
//  A native NSTextView, so text selects like in an editor - drag across
//  lines, double-click a word, ⌘A, ⌘C (SwiftUI text rows select only
//  inside one line). Line numbers, the
//  diff's +/- and the green / red line backgrounds are drawn beside the
//  text, not in it, so they are never selected or copied. Hunk headers
//  and notes are shown but left out of a copy: a copy is just the code.
//

import AppKit
import SwiftUI

/// One displayed line.
nonisolated struct CodeTextLine: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case plain, added, removed, hunk, note }

    var text: String
    /// Syntax colours; nil = plain (until they arrive).
    var runs: [SyntaxRun]?
    var kind: Kind = .plain
    /// One label per gutter column (line numbers, the +/- marker).
    var gutter: [String] = []

    /// Hunk headers and notes are not code: never copied.
    var isCopied: Bool { kind != .hunk && kind != .note }
}

/// A gutter column: its width and how its labels look.
struct CodeGutterColumn: Equatable {
    var width: CGFloat
    var alignment: NSTextAlignment = .right
    /// Labels coloured by the line's kind (the diff marker), else muted.
    var colouredByKind = false
}

struct CodeTextView: NSViewRepresentable {
    let lines: [CodeTextLine]
    let columns: [CodeGutterColumn]

    static let lineHeight: CGFloat = 18
    static let fontSize: CGFloat = 12

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let view = CodeNSTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.usesFindBar = true
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.lineFragmentPadding = 0
        // Showing the end of a 1 MB file doesn't lay out everything above it.
        view.layoutManager?.allowsNonContiguousLayout = true
        view.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        scroll.documentView = view
        view.show(lines, columns: columns)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (scroll.documentView as? CodeNSTextView)?.show(lines, columns: columns)
    }
}

/// The text view behind `CodeTextView`. Internal (not private) so tests
/// can build and draw it.
final class CodeNSTextView: NSTextView {
    private(set) var lines: [CodeTextLine] = []
    private var columns: [CodeGutterColumn] = []
    /// UTF-16 offset where each line starts in the text storage.
    private var lineStarts: [Int] = []

    private static let gap: CGFloat = 10
    private var gutterWidth: CGFloat { columns.reduce(0) { $0 + $1.width } + (columns.isEmpty ? 0 : Self.gap) }

    /// New text replaces the storage (selection resets); the same text with
    /// new colours only restyles it, so a selection survives the highlighter.
    func show(_ newLines: [CodeTextLine], columns newColumns: [CodeGutterColumn]) {
        let sameText = newLines.count == lines.count && zip(newLines, lines).allSatisfy { $0.text == $1.text && $0.kind == $1.kind }
        let columnsChanged = newColumns != columns
        if sameText && !columnsChanged && newLines == lines { return }
        lines = newLines
        columns = newColumns
        textContainerInset = NSSize(width: gutterWidth, height: 6)
        guard let storage = textStorage else { return }
        if sameText {
            storage.beginEditing()
            for (index, line) in lines.enumerated() {
                storage.setAttributes(Style.text, range: range(ofLine: index))
                apply(line, at: lineStarts[index], to: storage)
            }
            storage.endEditing()
        } else {
            var starts: [Int] = []
            starts.reserveCapacity(lines.count)
            let text = NSMutableString()
            for (index, line) in lines.enumerated() {
                starts.append(text.length)
                text.append(line.text)
                if index < lines.count - 1 { text.append("\n") }
            }
            lineStarts = starts
            storage.beginEditing()
            storage.setAttributedString(NSAttributedString(string: text as String, attributes: Style.text))
            for (index, line) in lines.enumerated() { apply(line, at: starts[index], to: storage) }
            storage.endEditing()
            setSelectedRange(NSRange(location: 0, length: 0))
        }
        needsDisplay = true
    }

    private func apply(_ line: CodeTextLine, at start: Int, to storage: NSTextStorage) {
        switch line.kind {
        case .hunk:
            storage.addAttribute(.foregroundColor, value: Style.hunk, range: NSRange(location: start, length: (line.text as NSString).length))
        case .note:
            storage.addAttribute(.foregroundColor, value: Style.muted, range: NSRange(location: start, length: (line.text as NSString).length))
        default:
            guard let runs = line.runs else { return }
            // Runs stay inside their line: a run list that doesn't match the
            // text (a clip that counted differently) must not colour the
            // next line.
            let end = start + (line.text as NSString).length
            var offset = start
            for run in runs where offset < end {
                let range = NSRange(location: offset, length: min((run.text as NSString).length, end - offset))
                offset += range.length
                storage.addAttribute(.foregroundColor, value: Style.syntax(run.scope), range: range)
                if run.scope == .comment { storage.addAttribute(.font, value: Self.italicFont, range: range) }
                if run.scope == .heading { storage.addAttribute(.font, value: Self.boldFont, range: range) }
            }
        }
    }

    // MARK: - Look

    private static let font = NSFont.monospacedSystemFont(ofSize: CodeTextView.fontSize, weight: .regular)
    private static let boldFont = NSFont.monospacedSystemFont(ofSize: CodeTextView.fontSize, weight: .semibold)
    private static let italicFont: NSFont = {
        let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: CodeTextView.fontSize) ?? font
    }()

    /// Built once: every redraw draws each visible line's gutter, and
    /// `show` styles every line.
    private enum Style {
        static let text: [NSAttributedString.Key: Any] = {
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = CodeTextView.lineHeight
            paragraph.maximumLineHeight = CodeTextView.lineHeight
            // Centre the 12 pt line in its 18 pt row like the SwiftUI rows did.
            let baseline = (CodeTextView.lineHeight - (font.ascender - font.descender)) / 2
            return [.font: font, .foregroundColor: primary, .paragraphStyle: paragraph, .baselineOffset: baseline]
        }()
        static let primary = NSColor(AppTheme.Colors.textPrimary)
        static let muted = NSColor(AppTheme.Colors.textMuted)
        static let hunk = NSColor(AppTheme.Colors.statusBlue)
        static let added = NSColor(AppTheme.Colors.statusGreen)
        static let removed = NSColor(AppTheme.Colors.statusRed)
        static let canvas = NSColor(AppTheme.Colors.terminalBackground)
        static let addedRow = added.withAlphaComponent(0.12)
        static let removedRow = removed.withAlphaComponent(0.13)
        static let hunkRow = hunk.withAlphaComponent(0.08)
        static let mutedLabel = text.merging([.foregroundColor: muted]) { $1 }
        static let addedLabel = text.merging([.foregroundColor: added]) { $1 }
        static let removedLabel = text.merging([.foregroundColor: removed]) { $1 }

        /// One NSColor per syntax scope, not one per coloured run.
        private static var syntaxColours: [SyntaxScope?: NSColor] = [:]
        static func syntax(_ scope: SyntaxScope?) -> NSColor {
            if let colour = syntaxColours[scope] { return colour }
            let colour = NSColor(SyntaxPalette.color(scope))
            syntaxColours[scope] = colour
            return colour
        }
    }

    private static func background(_ kind: CodeTextLine.Kind) -> NSColor? {
        switch kind {
        case .added: Style.addedRow
        case .removed: Style.removedRow
        case .hunk: Style.hunkRow
        default: nil
        }
    }

    // MARK: - Drawing: line backgrounds and the gutter

    override func drawBackground(in rect: NSRect) {
        Style.canvas.setFill()
        rect.fill()
        guard let layoutManager, let textContainer, !lines.isEmpty else { return }
        let origin = textContainerOrigin
        // Lines by height only: a redraw of just the gutter strip (scrolling
        // back to the left edge) lies left of the text container and would
        // find no line, erasing the numbers.
        let band = NSRect(x: 0, y: rect.minY - origin.y, width: textContainer.size.width, height: rect.height)
        let glyphs = layoutManager.glyphRange(forBoundingRect: band, in: textContainer)
        var drawn = Set<Int>()
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, glyphRange, _ in
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            let line = self.lineIndex(containing: charIndex)
            guard drawn.insert(line).inserted else { return }
            let y = fragment.minY + origin.y
            let row = NSRect(x: 0, y: y, width: max(self.bounds.width, rect.maxX), height: CodeTextView.lineHeight)
            if let colour = Self.background(self.lines[line].kind) {
                colour.setFill()
                row.fill()
            }
            self.drawGutter(for: self.lines[line], in: row)
        }
        // An empty last line (no glyphs) still gets its background and gutter.
        if let last = lines.indices.last, !drawn.contains(last), layoutManager.extraLineFragmentRect.height > 0 {
            let y = layoutManager.extraLineFragmentRect.minY + origin.y
            let row = NSRect(x: 0, y: y, width: max(bounds.width, rect.maxX), height: CodeTextView.lineHeight)
            if let colour = Self.background(lines[last].kind) {
                colour.setFill()
                row.fill()
            }
            drawGutter(for: lines[last], in: row)
        }
    }

    private func drawGutter(for line: CodeTextLine, in row: NSRect) {
        var x: CGFloat = 0
        for (index, column) in columns.enumerated() {
            defer { x += column.width }
            guard index < line.gutter.count, !line.gutter[index].isEmpty else { continue }
            // The text's own attributes (line height, baseline), so the
            // label sits exactly on its line.
            let attributes = !column.colouredByKind ? Style.mutedLabel
                : line.kind == .added ? Style.addedLabel : Style.removedLabel
            let label = NSAttributedString(string: line.gutter[index], attributes: attributes)
            let width = ceil(label.size().width)
            let labelX: CGFloat = switch column.alignment {
            case .center: x + (column.width - width) / 2
            case .left: x
            default: x + column.width - width
            }
            label.draw(in: NSRect(x: labelX, y: row.minY, width: width + 1, height: CodeTextView.lineHeight))
        }
    }

    // MARK: - Lines

    private func lineIndex(containing charIndex: Int) -> Int {
        // Last start <= charIndex.
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= charIndex { low = mid } else { high = mid - 1 }
        }
        return max(0, low)
    }

    private func range(ofLine index: Int) -> NSRange {
        NSRange(location: lineStarts[index], length: (lines[index].text as NSString).length)
    }

    // MARK: - Find

    /// ⌘F / ⌘G while the drawer's code has the keyboard search it with its
    /// own find bar, not the terminal under the drawer. False when no code
    /// view has the keyboard (the caller then searches the terminal).
    static func performFindIfFocused(_ action: NSTextFinder.Action) -> Bool {
        // The window's own first responder, not only the key window's:
        // the window that has the code focused, whether or not it is key.
        let window = NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.firstResponder is CodeNSTextView }
        guard let view = window?.firstResponder as? CodeNSTextView else { return false }
        // NSTextView reads the action from the sender's tag.
        let item = NSMenuItem()
        item.tag = action.rawValue
        view.performTextFinderAction(item)
        return true
    }

    // MARK: - Copy: just the code

    /// The selected text without hunk headers and notes.
    func copiedText() -> String {
        guard let storage = textStorage, !lines.isEmpty else { return "" }
        let string = storage.string as NSString
        var pieces: [String] = []
        for value in selectedRanges {
            let selection = value.rangeValue
            guard selection.length > 0 else { continue }
            let first = lineIndex(containing: selection.location)
            let last = lineIndex(containing: NSMaxRange(selection) - 1)
            for index in first...last where lines[index].isCopied {
                let lineRange = range(ofLine: index)
                let piece = NSIntersectionRange(lineRange, selection)
                // An empty line inside the selection still counts (keeps
                // the blank lines of the code).
                guard piece.length > 0 || (lineRange.length == 0 && NSLocationInRange(lineRange.location, selection))
                else { continue }
                pieces.append(piece.length > 0 ? string.substring(with: piece) : "")
            }
        }
        return pieces.joined(separator: "\n")
    }

    override func copy(_ sender: Any?) {
        let text = copiedText()
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
