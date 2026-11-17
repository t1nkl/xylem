//
//  TerminalAppearance.swift
//  Xylem
//
//  The terminal's look: colours, caret, selection, padding and line
//  spacing. One place applies all of it to a SwiftTerm view, so a session
//  never ends up half-themed (e.g. a grid in #181818 framed by a layer that
//  still has SwiftTerm's default background).
//

import AppKit
import SwiftTerm

enum TerminalAppearance {

    // MARK: - Colours

    /// Matches `AppTheme.Colors.terminalBackground` (#181818). Kept as an
    /// NSColor here because SwiftTerm and AppKit layers need NSColor/CGColor.
    static let background = NSColor(hex: 0x181818)
    static let foreground = NSColor(hex: 0xCCCCCC)

    /// Block caret like the reference: light block, the glyph under it drawn
    /// in the background colour so it stays readable.
    static let caret = NSColor(hex: 0xCCCCCC)
    static let caretText = NSColor(hex: 0x181818)

    /// Neutral blue selection, distinct from Claude's #373737 prompt band.
    static let selection = NSColor(hex: 0x264F78)

    /// 16-colour ANSI palette for a #181818 background. Hues follow the app
    /// accents (green #49DE80, yellow #FACC14 in the design spec); black and
    /// bright black are lifted so they stay visible on the dark background,
    /// white/bright white are the spec's terminalForeground/textPrimary.
    static let ansiPalette: [UInt32] = [
        0x2E2E2E, // 0 black
        0xF87171, // 1 red
        0x4ADE80, // 2 green
        0xFACC15, // 3 yellow
        0x60A5FA, // 4 blue
        0xC084FC, // 5 magenta
        0x22D3EE, // 6 cyan
        0xCCCCCC, // 7 white
        0x6B6B6B, // 8 bright black
        0xFCA5A5, // 9 bright red
        0x86EFAC, // 10 bright green
        0xFDE047, // 11 bright yellow
        0x93C5FD, // 12 bright blue
        0xD8B4FE, // 13 bright magenta
        0x67E8F9, // 14 bright cyan
        0xEBEBEB  // 15 bright white
    ]

    // MARK: - Metrics

    /// Space between the terminal grid and the surrounding chrome. Painted
    /// with `background`, so there is no seam around the grid. The right
    /// inset is small because SwiftTerm's overlay scroller (the default)
    /// floats over the grid's right edge and reserves no width of its own.
    static let padding = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 4)

    /// Row height as a multiple of the font size. The reference rows are
    /// ~16.5 pt at 12 pt; SwiftTerm sizes a row as ascent + descent + leading
    /// (SF Mono 12: ~14.1 pt, rounded up), which reads cramped next to it.
    static let rowHeightToFontSize: CGFloat = 1.375

    // MARK: - Apply

    static func apply(to view: TerminalView) {
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = foreground
        view.installColors(ansiPalette.map(Self.terminalColor))
        view.caretColor = caret
        view.caretTextColor = caretText
        view.selectedTextBackgroundColor = selection
        // SwiftTerm paints its layer only once, at init, with whatever
        // background it had then. Re-paint it so the strip below the last
        // full row matches the grid.
        view.layer?.backgroundColor = background.cgColor
        applyLineSpacing(to: view)
    }

    /// `lineSpacing` multiplies the font's natural row height. It is derived
    /// from a target row height rather than fixed, so fonts with different
    /// natural heights (SF Mono vs JetBrains Mono) end up with the same rows.
    /// SwiftTerm rounds the row up to a whole point, hence the small epsilon
    /// below the target. The setter re-measures and resizes the grid, so it
    /// is only assigned when the value actually changes.
    private static func applyLineSpacing(to view: TerminalView) {
        let font = view.font
        let natural = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        guard natural > 0 else { return }
        let target = ceil(font.pointSize * rowHeightToFontSize)
        let spacing = max(1, (target - 0.01) / natural)
        if abs(view.lineSpacing - spacing) > 0.0001 {
            view.lineSpacing = spacing
        }
    }

    private nonisolated static func terminalColor(_ hex: UInt32) -> SwiftTerm.Color {
        // SwiftTerm colours are 16-bit per channel; 0xFF * 257 == 0xFFFF.
        SwiftTerm.Color(
            red: UInt16((hex >> 16) & 0xFF) * 257,
            green: UInt16((hex >> 8) & 0xFF) * 257,
            blue: UInt16(hex & 0xFF) * 257
        )
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
