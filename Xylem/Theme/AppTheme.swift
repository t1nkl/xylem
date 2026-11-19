//
//  AppTheme.swift
//  Xylem
//
//  Centralised colours, fonts, and metrics. The app ships dark-only - the
//  terminal (SwiftTerm) is always dark regardless of system appearance, and
//  macOS Tahoe's Liquid Glass re-tints sidebar/top-bar materials anyway, so
//  a light palette would be half-working.
//

import SwiftUI

enum AppTheme {
    static var Colors: Palette { ColorsHolder.current }
    enum Fonts {
        // Compact density: everything but the tab list.
        static let sectionHeader = Font.system(size: 13, weight: .semibold, design: .default)
        static let sectionItem = Font.system(size: 13, weight: .regular, design: .default)
        static let sectionMeta = Font.system(size: 12, weight: .regular, design: .default)
        static let toolbarButton = Font.system(size: 11, weight: .regular, design: .default)
    }

    /// Region sizes. The window toolbar and the tab sidebar are sized by the
    /// system; these are the parts we draw ourselves (right panel included).
    enum Metrics {
        static let bottomBarHeight: CGFloat = 28
        /// Right panel width range (resizable by its left edge).
        static let inspectorMinWidth: CGFloat = 240
        static let inspectorIdealWidth: CGFloat = 290
        static let inspectorMaxWidth: CGFloat = 440
        /// Tab sidebar width range.
        static let tabSidebarMinWidth: CGFloat = 200
        static let tabSidebarIdealWidth: CGFloat = 250
        static let tabSidebarMaxWidth: CGFloat = 360
        /// The icon column at the window's right edge (widened twice:
        /// 42 -> 50 -> 56).
        static let panelRailWidth: CGFloat = 56
        /// The Files / Changes drawer over the terminal: this wide, but
        /// never more than `drawerMaxFraction` of the terminal's width.
        static let drawerWidth: CGFloat = 560
        static let drawerMinWidth: CGFloat = 340
        /// The right panel never narrows the terminal below this.
        static let minTerminalWidth: CGFloat = 420
        static let drawerMaxFraction: CGFloat = 0.85
    }

    /// Canonical icon point sizes. Call sites should pick the tier by intent,
    /// not by rendering accident, so chrome stays visually aligned across
    /// top bar / bottom toolbar / sidebar rails / empty states.
    enum Icons {
        /// Chevrons, corner overlays, status dot glyphs - 8pt.
        static let micro: CGFloat = 8
        /// Inline cell icons that sit next to a short text value - 10pt.
        static let inline: CGFloat = 10
        /// Clickable toolbar / rail action buttons - 11pt.
        static let button: CGFloat = 11
        /// Section-leading / empty-state accent icons - 14pt.
        static let emphasis: CGFloat = 14
    }
}

// MARK: - Theme palette

struct Palette {
    // Surfaces
    let background: Color
    let panelBackground: Color
    let panelBackgroundRaised: Color
    let panelBorder: Color
    let panelBorderStrong: Color
    let surfaceHover: Color
    let terminalBackground: Color
    let tabActiveBackground: Color
    let divider: Color
    let contextTrack: Color

    // Text
    let textPrimary: Color
    /// Rows and headers of the right panel (Claude / Git): a step below
    /// `textPrimary` so the panel doesn't outshine the terminal. Same grey as the terminal's text.
    let panelText: Color
    let textSecondary: Color
    let textMuted: Color

    // Accents
    let accent: Color
    let accentStrong: Color
    /// Tint for segmented controls. macOS lightens a tinted selected segment
    /// in dark mode (#16A34A shows as #60AF6A), so this darker input is what
    /// renders at the accent's lightness (#108E3F shows as #539D5F, same
    /// luminance as #16A34A - measured from a window snapshot).
    let segmentTint: Color
    let tabBackground: Color
    let statusGreen: Color
    let statusAmber: Color
    /// "Claude is working" pulse around a tab avatar (yellow by design).
    let statusBusy: Color
    let statusRed: Color
    let statusBlue: Color
}

private extension Color {
    /// sRGB colour from a 0xRRGGBB literal.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension Palette {
    /// The app's only palette (dark).
    static let dark = Palette(
        background: Color(hex: 0x1A1A1A),
        panelBackground: Color(hex: 0x232323),
        panelBackgroundRaised: Color(hex: 0x2E2E2E),
        panelBorder: Color(hex: 0x2E2E2E),
        panelBorderStrong: Color(hex: 0x3A3A3A),
        surfaceHover: Color.white.opacity(0.04),
        terminalBackground: Color(hex: 0x181818),
        tabActiveBackground: Color(hex: 0x2E2E2E),
        divider: Color(hex: 0x2E2E2E),
        contextTrack: Color(hex: 0x333333),
        textPrimary: Color(hex: 0xEBEBEB),
        panelText: Color(hex: 0xCCCCCC),
        textSecondary: Color(hex: 0xA0A0A0),
        textMuted: Color(hex: 0x6B6B6B),
        // Every green is the darker brand green except status dots, which keep `statusGreen`.
        accent: Color(hex: 0x16A34A),
        accentStrong: Color(hex: 0x22C55E),
        segmentTint: Color(hex: 0x108E3F),
        tabBackground: Color(hex: 0x2E2E2E),
        statusGreen: Color(hex: 0x49DE80),
        statusAmber: Color(hex: 0xF5A524),
        statusBusy: Color(hex: 0xFACC15),
        statusRed: Color(hex: 0xF0605A),
        statusBlue: Color(hex: 0x6EA8FE)
    )
}

enum ColorsHolder {
    static let current: Palette = .dark
}

// MARK: - Environment key

private struct PaletteKey: EnvironmentKey {
    static let defaultValue: Palette = .dark
}

extension EnvironmentValues {
    var xylemPalette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}
