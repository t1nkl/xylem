//
//  NewTabPickerView.swift
//  Xylem
//
//  Welcome / recents screen rendered inside an unconfigured pane. Card grid
//  for recent projects; hero area has bigger brand mark + call-to-action.
//  Keyboard hints surface the shortcuts that actually speed up the flow
//  (⌘O to open folder, ⌘P to search across everything).
//

import SwiftUI
import AppKit

struct NewTabPickerView: View {
    let recentProjects: [ClaudeProject]
    var onOpenFolder: (String) -> Void = { _ in }
    var onOpenRecent: (ClaudeProject) -> Void = { _ in }

    /// Cells (cards + the "Show more" tile) currently allowed; grows by a
    /// page per "Show more".
    @State private var recentCells: Int?
    /// Where the card grid starts in the scroll content and how tall one
    /// card is - together with the window height they give the rows that
    /// fit on screen (one page).
    @State private var gridTop: CGFloat = 0
    @State private var cardHeight: CGFloat = 0
    /// The grid's real width (a legacy scroller takes ~15 pt of the
    /// window's); nil until measured.
    @State private var gridWidth: CGFloat?

    // Card size: variant B from a four-way mock (2026-11-17) - the 180 pt
    // cards were too small on a full screen (seven columns, paths cut).
    private static let cardMinWidth: CGFloat = 220
    private static let cardMaxWidth: CGFloat = 320
    private static let gridSpacing: CGFloat = 12
    private static let horizontalPadding: CGFloat = 32
    private static let verticalPadding: CGFloat = 20
    private static let bottomGap: CGFloat = 20
    private static let stackSpacing: CGFloat = 28
    private static let contentSpace = "newTabPickerContent"

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: Self.stackSpacing) {
                    Spacer(minLength: max(8, proxy.size.height * 0.025))

                    hero

                    actionRow
                        .frame(maxWidth: 540)

                    if !recentProjects.isEmpty {
                        recentGrid(
                            columnCount: Self.columnCount(forWidth: gridWidth ?? proxy.size.width - 2 * Self.horizontalPadding),
                            rowCount: Self.rowCount(
                                // Below the grid: the stack's spacing, the
                                // bottom gap and the vertical padding.
                                forHeight: proxy.size.height - 2 * Self.verticalPadding - Self.stackSpacing - Self.bottomGap - gridTop,
                                cardHeight: cardHeight
                            )
                        )
                    } else {
                        firstLaunchHints
                            .frame(maxWidth: 540)
                    }

                    Spacer(minLength: Self.bottomGap)
                }
                .frame(maxWidth: .infinity)
                .coordinateSpace(.named(Self.contentSpace))
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.vertical, Self.verticalPadding)
            }
        }
        .background(AppTheme.Colors.background)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(AppTheme.Colors.accent.opacity(0.14))
                    .frame(width: 64, height: 64)
                RoundedRectangle(cornerRadius: 14)
                    .stroke(AppTheme.Colors.accent.opacity(0.5), lineWidth: 1)
                    .frame(width: 64, height: 64)
                Image(systemName: "terminal.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.accent)
            }

            // No app name here (design choice, 2026-11-15): the window
            // already says Xylem; the screen is about picking a folder.
            Text("Pick a project folder to spin up Claude Code.")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }

    // MARK: - Action row (open + search)

    private var actionRow: some View {
        HStack(spacing: 10) {
            primaryButton(
                icon: "folder.badge.plus",
                title: "Open Folder…",
                shortcut: "⌘O",
                action: presentOpenPanel
            )
            secondaryButton(
                icon: "command",
                title: "Command Palette",
                shortcut: "⌘K"
            ) {
                NotificationCenter.default.post(name: .xylemOpenCommandPalette, object: nil)
            }
        }
    }

    private func primaryButton(icon: String, title: String, shortcut: String, action: @escaping () -> Void) -> some View {
        PickerActionButton(icon: icon, title: title, shortcut: shortcut, isPrimary: true, action: action)
            // ⌘O lives in File > Open Folder… (any tab); the hint stays.
    }

    private func secondaryButton(icon: String, title: String, shortcut: String, action: @escaping () -> Void) -> some View {
        PickerActionButton(icon: icon, title: title, shortcut: shortcut, isPrimary: false, action: action)
    }

    // MARK: - First-launch hints

    /// What we show when `~/.claude/projects` has no sessions yet - i.e.
    /// first ever launch. Guide the user to try Claude in one of their own
    /// folders rather than leaving them with a bare "Open Folder…" button.
    private var firstLaunchHints: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("FIRST TIME HERE?")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(AppTheme.Colors.textMuted)

            VStack(alignment: .leading, spacing: 10) {
                hintRow(step: "1", label: "Pick a project folder", detail: "Xylem spins up Claude Code there and shows live stats.")
                hintRow(step: "2", label: "Try `/init`", detail: "Generates a CLAUDE.md so future sessions know your codebase.")
                hintRow(step: "3", label: "⌘K opens the command palette", detail: "Every action in one fuzzy list - tabs, git, past prompts.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hintRow(step: String, label: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(step)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.accent)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(AppTheme.Colors.accent.opacity(0.15))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
    }

    // MARK: - Recent grid

    /// Columns that fit, the way an adaptive grid of 220-320 pt cards
    /// would lay them out; the grid uses exactly this many so the paging
    /// below knows the row length.
    /// Which palette colour a project's card gets. FNV-1a over the name's
    /// UTF-8 bytes, so a project keeps its colour across launches - Swift's
    /// `hashValue` is seeded per process and reshuffled the colours on
    /// every launch.
    nonisolated static func accentIndex(for name: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int(hash % UInt64(count))
    }

    static func columnCount(forWidth width: CGFloat) -> Int {
        max(1, Int((width + gridSpacing) / (cardMinWidth + gridSpacing)))
    }

    /// Whole rows of cards that fit below the grid's top edge; at least
    /// two, so a short window still shows a useful page.
    static func rowCount(forHeight height: CGFloat, cardHeight: CGFloat) -> Int {
        guard cardHeight > 0 else { return 2 }
        return max(2, Int((height + gridSpacing) / (cardHeight + gridSpacing)))
    }

    private func recentGrid(columnCount: Int, rowCount: Int) -> some View {
        let paging = RecentProjectsPaging(
            total: recentProjects.count,
            columns: columnCount,
            rows: rowCount,
            cells: recentCells
        )
        // No minimum on the items: `columnCount` already keeps cards at
        // least `cardMinWidth` wide. A minimum here made the grid as wide as
        // its current columns, so it never got narrower when the right panel
        // opened or the window shrank (the cards went under the panel) and
        // the measured width kept the old column count.
        let columns = Array(
            repeating: GridItem(.flexible(minimum: 0, maximum: Self.cardMaxWidth), spacing: Self.gridSpacing),
            count: columnCount
        )
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("RECENT PROJECTS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(AppTheme.Colors.textMuted)
                Spacer()
                Text("\(recentProjects.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textMuted)
            }

            LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
                ForEach(recentProjects.prefix(paging.shownCards)) { project in
                    RecentCard(project: project, onSelect: { onOpenRecent(project) })
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            // The tallest card sets a row's height.
                            if height > cardHeight { cardHeight = height }
                        }
                }
                if paging.hasMore {
                    ShowMoreCard(count: paging.nextPageCards) {
                        recentCells = paging.cells + paging.page
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.contentSpace)).minY } action: { top in
                if abs(top - gridTop) > 0.5 { gridTop = top }
            }
        }
        // Full width whatever the columns are, so measuring it can't loop.
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if abs(width - (gridWidth ?? 0)) > 0.5 { gridWidth = width }
        }
    }

    // MARK: - NSOpenPanel

    private func presentOpenPanel() {
        if let url = OpenPanels.pick(.projectFolder) {
            onOpenFolder(url.path)
        }
    }
}

private struct RecentCard: View {
    let project: ClaudeProject
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            // Layout F from a mock (2026-11-17), with the date moved up:
            // icon, name and date on one row, then the path, then the
            // sessions pill. The old icon row above the name took a third
            // of the card's height.
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(cardAccentColor.opacity(0.18))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Image(systemName: "folder.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(cardAccentColor)
                        )
                    Text(project.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    RelativeTimeText(date: project.lastModified)
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.Colors.textMuted)
                        .fixedSize()
                }

                Text(shortPath(project.path))
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Always present, so every card (and every grid row) has the
                // same height: LazyVGrid estimates the rows it hasn't built
                // yet, and mixed heights made scrolling a long list jump.
                Text(Self.sessionsLabel(project.sessionCount))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(project.sessionCount > 0 ? AppTheme.Colors.textSecondary : AppTheme.Colors.textMuted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule()
                            .fill(AppTheme.Colors.tabBackground)
                    )
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovering ? AppTheme.Colors.panelBackgroundRaised : AppTheme.Colors.panelBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isHovering ? AppTheme.Colors.accent.opacity(0.4) : AppTheme.Colors.panelBorder, lineWidth: 0.8)
            )
            .animation(.easeInOut(duration: 0.15), value: isHovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(project.path)
    }

    static func sessionsLabel(_ count: Int) -> String {
        switch count {
        case 0: "No sessions"
        case 1: "1 session"
        default: "\(count) sessions"
        }
    }

    /// Derives a stable accent color from the project name so every card
    /// in the grid has a small visual signature - helps scan-by-color.
    private var cardAccentColor: Color {
        let palette: [Color] = [
            AppTheme.Colors.accent,
            AppTheme.Colors.statusBlue,
            AppTheme.Colors.statusAmber,
            Color(nsColor: NSColor(srgbRed: 0.80, green: 0.52, blue: 0.95, alpha: 1.0)),
            Color(nsColor: NSColor(srgbRed: 0.35, green: 0.82, blue: 0.87, alpha: 1.0)),
            Color(nsColor: NSColor(srgbRed: 0.95, green: 0.60, blue: 0.70, alpha: 1.0))
        ]
        return palette[NewTabPickerView.accentIndex(for: project.displayName, count: palette.count)]
    }

    private func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }
}

/// Recent Projects paging (2026-11-15): a page is the whole
/// rows of cards that fit on screen (at least two). When more projects
/// remain, the page's last cell is the "Show more" tile, so the grid ends
/// on a full row and its last card is never alone (e.g. 5 x 5 = 24 cards +
/// the tile). Each "Show more" adds a page.
nonisolated struct RecentProjectsPaging: Equatable {
    let total: Int
    let page: Int
    /// Cells allowed now (cards + tile).
    let cells: Int

    init(total: Int, columns: Int, rows: Int, cells: Int? = nil) {
        let page = max(1, columns) * max(1, rows)
        self.total = total
        self.page = page
        // Keep what was opened, re-rounded to the current page (the window
        // may have been resized since).
        let opened = cells ?? page
        self.cells = max(page, (opened + page - 1) / page * page)
    }

    var hasMore: Bool { total > cells }
    var shownCards: Int { hasMore ? cells - 1 : total }

    /// Cards the next "Show more" adds.
    var nextPageCards: Int {
        RecentProjectsPaging(total: total, columns: page, rows: 1, cells: cells + page).shownCards - shownCards
    }
}

/// The last grid cell when more projects remain.
private struct ShowMoreCard: View {
    let count: Int
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                Text("Show \(count) more")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(isHovering ? AppTheme.Colors.textPrimary : AppTheme.Colors.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 60)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovering ? AppTheme.Colors.panelBackgroundRaised : AppTheme.Colors.panelBackground.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(AppTheme.Colors.panelBorder, style: StrokeStyle(lineWidth: 0.8, dash: [4, 3]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Show \(count) more projects")
    }
}

/// Open Folder (primary, green) and Command Palette (secondary) on the New
/// Tab screen. Hover brightens the fill and the border; a press dims it.
private struct PickerActionButton: View {
    let icon: String
    let title: String
    let shortcut: String
    let isPrimary: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12, weight: isPrimary ? .semibold : .regular))
                Text(title).font(.system(size: 12, weight: isPrimary ? .semibold : .medium))
                Spacer(minLength: 0)
                Text(shortcut)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(isPrimary ? AppTheme.Colors.textPrimary.opacity(0.7) : AppTheme.Colors.textMuted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(isPrimary ? AppTheme.Colors.textPrimary.opacity(0.25) : AppTheme.Colors.panelBorder, lineWidth: 0.5)
                    )
            }
            .foregroundStyle(isPrimary || isHovering ? AppTheme.Colors.textPrimary : AppTheme.Colors.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(border, lineWidth: isPrimary ? 1 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDimStyle())
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }

    private var fill: Color {
        isPrimary
            ? AppTheme.Colors.accent.opacity(isHovering ? 0.34 : 0.22)
            : AppTheme.Colors.panelBackgroundRaised.opacity(isHovering ? 1 : 0.7)
    }

    private var border: Color {
        isPrimary
            ? AppTheme.Colors.accent.opacity(isHovering ? 0.85 : 0.5)
            : (isHovering ? AppTheme.Colors.textMuted.opacity(0.6) : AppTheme.Colors.panelBorder)
    }
}

/// Plain button that dims while pressed.
private struct PressDimStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.75 : 1)
    }
}
