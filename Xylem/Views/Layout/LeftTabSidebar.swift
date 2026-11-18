//
//  LeftTabSidebar.swift
//  Xylem
//
//  The tab list, as the window's native sidebar (NavigationSplitView): a
//  sidebar-style List with our own active-row fill, search, drag-to-reorder and
//  the Liquid Glass material. Each row shows the project avatar (rounded
//  square: accent when active, yellow pulse while Claude works, blue dot
//  when it finished unseen, orange "!" when it asks for permission, green
//  dot when idle), the title, the last prompt (or "Needs your permission")
//  and `branch · path`.
//
//  Density: this list stays Regular (three lines, 28 pt avatar) while the
//  rest of the window is Compact - chosen after comparing both.
//
//  Selecting a row hands the keyboard back to the terminal (`onSelect` does
//  that in ContentView): the list must never keep focus, or the next thing
//  typed would go into the sidebar instead of Claude.
//
//  The active row is drawn by us, not by `List(selection:)`: a system
//  selection is blue only while the list has the keyboard - which is never,
//  by the rule above - so the active tab sat grey and turned blue only when
//  a click on empty space left the keyboard in the list (the active tab
//  should be blue, as usual). The fill is the system selection colour
//  (`selectedContentBackgroundColor`, follows the user's accent colour) and
//  the row's grey texts get the selection's lighter variants
//  (`backgroundProminence`).
//

import SwiftUI

struct LeftTabSidebar: View {
    let tabs: [TerminalTab]
    let activeTabID: TerminalTab.ID?

    /// A click on another tab.
    var onSelect: (TerminalTab.ID) -> Void = { _ in }
    /// Hands the keyboard back to the active terminal: after a click on the
    /// tab that is already active and after a rename ends.
    var onReactivate: () -> Void = {}
    var onClose: (TerminalTab.ID) -> Void = { _ in }
    var onShowOverview: () -> Void = {}
    var onRename: (TerminalTab.ID, String) -> Void = { _, _ in }
    var onMove: (IndexSet, Int) -> Void = { _, _ in }
    var onCloseOthers: (TerminalTab.ID) -> Void = { _ in }

    @State private var searchQuery: String = ""
    /// Tab under the pointer: its row gets a faint fill (the active one
    /// keeps the selection colour).
    @State private var hoveredTabID: TerminalTab.ID?

    private var filteredTabs: [TerminalTab] {
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return tabs }
        return tabs.filter {
            $0.displayTitle.lowercased().contains(q) ||
            ($0.liveCwd ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        let visibleTabs = filteredTabs
        let isFiltering = !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
        List {
            Section("Tabs") {
                ForEach(visibleTabs) { tab in
                    let isActive = tab.id == activeTabID
                    TabRow(
                        tab: tab,
                        isActive: isActive,
                        canClose: tabs.count > 1,
                        onSelect: { onSelect(tab.id) },
                        onReactivate: onReactivate,
                        onClose: {
                            // The row leaves under the pointer: AppKit may
                            // not send the exit that would clear its fill.
                            if hoveredTabID == tab.id { hoveredTabID = nil }
                            onClose(tab.id)
                        },
                        onRename: { onRename(tab.id, $0) },
                        onCloseOthers: { onCloseOthers(tab.id) },
                        onHover: { hovering in
                            if hovering { hoveredTabID = tab.id } else if hoveredTabID == tab.id { hoveredTabID = nil }
                        }
                    )
                    .listRowBackground(
                        isActive ? AnyView(ActiveRowBackground())
                            : hoveredTabID == tab.id ? AnyView(HoverRowBackground()) : nil
                    )
                }
                // Reordering a filtered list would drop into hidden slots.
                .onMove(perform: isFiltering ? nil : { from, to in
                    hoveredTabID = nil
                    onMove(from, to)
                })

                if visibleTabs.isEmpty && isFiltering {
                    Text("No matches")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.sidebarRowSize, .medium)
        .searchable(text: $searchQuery, placement: .sidebar, prompt: "Search tabs")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button(action: onShowOverview) {
                    Label("All Sessions", systemImage: "square.grid.2x2")
                        .foregroundStyle(AppTheme.Colors.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight()
                .help("All sessions overview")
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
        }
    }
}

// MARK: - Row

/// One tab. Its own struct so a tab's `isBusy` / `lastPrompt` changes
/// re-render only this row.
private struct TabRow: View {
    let tab: TerminalTab
    let isActive: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onReactivate: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void
    let onCloseOthers: () -> Void
    /// The list draws the row background, so it needs to know.
    var onHover: (Bool) -> Void = { _ in }

    @State private var isHovering = false
    @State private var isEditing = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            TabAvatar(tab: tab, isActive: isActive)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    title
                    Spacer(minLength: 4)
                    if !isEditing && canClose && isHovering {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(CloseTabButtonStyle())
                        .help("Close Tab")
                        .accessibilityLabel("Close \(tab.displayTitle)")
                    }
                }
                promptLine
                locationLine
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // On the selection fill, `.secondary` / `.tertiary` texts take the
        // light variants a system selection gives them.
        .environment(\.backgroundProminence, isActive ? .increased : .standard)
        // Simultaneous, so the List can still drag the row (`.onMove`).
        .simultaneousGesture(TapGesture().onEnded {
            guard !isEditing else { return }
            if isActive { onReactivate() } else { onSelect() }
        })
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .onHover { hovering in
            isHovering = hovering
            onHover(hovering)
        }
        // One element per row that still contains the close button (a
        // `.combine` swallowed it and glued every child's tooltip together).
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tab.displayTitle)
        .help(pathLabel)
        .contextMenu {
            Button("Rename…") { isEditing = true }
            Divider()
            if canClose {
                Button("Close Tab", action: onClose)
                Button("Close Other Tabs", action: onCloseOthers)
            }
        }
    }

    private var title: some View {
        TabTitleField(title: tab.displayTitle, isEditing: $isEditing,
                      onRename: onRename, onFinish: onReactivate) {
            Text(tab.displayTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
        }
    }

    /// Last user prompt; a dimmed placeholder until there is one (the path
    /// already sits on the third line).
    @ViewBuilder
    private var promptLine: some View {
        if tab.needsAttention, case .needsInput(let message) = tab.claudeState {
            Text(TabRowText.needsInputLine(message))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.Colors.statusAmber)
                .lineLimit(1)
        } else if let prompt = tab.lastPrompt, !prompt.isEmpty {
            Text(prompt)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            Text(tab.hasAnyRunningSession ? "No prompt yet" : "Pick a folder")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    /// `⎇ branch · ~/path`. A plain HStack with an explicit icon size and
    /// colour: a `Label` in a sidebar List gets an icon column and the
    /// system accent tint (the oversized blue glyph of 0.6.0).
    private var locationLine: some View {
        HStack(spacing: 4) {
            if let branch = tab.gitBranch, !branch.isEmpty {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9, weight: .medium))
                Text(branch)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Text("·")
            }
            Text(pathLabel)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
    }

    /// Home reads as `~`; follows `liveCwd`, so a `cd` in the shell shows.
    private var pathLabel: String {
        guard let path = tab.liveCwd, !path.isEmpty else { return "No folder selected" }
        return PathDisplay.abbreviatingHome(path)
    }
}

/// A tab's title that turns into a text field for Rename (sidebar rows and
/// top tabs). Starts from what the tab shows (it follows the cwd), not the
/// stored title. Return or leaving the field renames; Esc cancels. Either
/// way the keyboard goes back to the terminal (`onFinish`): the field
/// leaving the window would otherwise leave nothing focused.
struct TabTitleField<Content: View>: View {
    let title: String
    @Binding var isEditing: Bool
    let onRename: (String) -> Void
    let onFinish: () -> Void
    @ViewBuilder let label: () -> Content

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if isEditing {
                field
            } else {
                label()
            }
        }
        // When the edit starts, not when the field appears: a list row
        // re-appearing mid-edit must not reset what was typed.
        .onChange(of: isEditing) { _, editing in
            guard editing else { return }
            draft = title
            // On the next turn: in the sidebar's List the field isn't in
            // the window yet, and the focus request was dropped (typing
            // went to the terminal).
            DispatchQueue.main.async { focused = true }
        }
    }

    private var field: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .focused($focused)
            .onSubmit(commit)
            .onExitCommand {
                isEditing = false
                onFinish()
            }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func commit() {
        guard isEditing else { return }
        isEditing = false
        onRename(draft)
        onFinish()
    }
}

/// A hovered inactive tab: the active row's shape in a faint fill.
private struct HoverRowBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.06))
            .padding(.horizontal, 10)
            .padding(.vertical, 1)
    }
}

/// The tab's ×: grey, brighter with a small fill under the pointer.
/// Shared with the top tab bar.
struct CloseTabButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CloseTabButtonBody(configuration: configuration)
    }

    private struct CloseTabButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(isHovering ? .primary : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : isHovering ? 0.1 : 0))
                )
                .onHover { isHovering = $0 }
        }
    }
}

/// The active row's fill: the system selection shape and colour, shown
/// whether or not the list has the keyboard.
private struct ActiveRowBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: .selectedContentBackgroundColor))
            .padding(.horizontal, 10)
            .padding(.vertical, 1)
    }
}

nonisolated enum TabRowText {
    /// "Claude needs your permission" (Claude Code's wording) reads as
    /// "Needs your permission" under the tab title.
    static func needsInputLine(_ message: String?) -> String {
        guard let message, !message.isEmpty else { return "Needs your input" }
        if message.hasPrefix("Claude needs ") {
            return "Needs " + message.dropFirst("Claude needs ".count)
        }
        return message
    }
}

/// `/Users/me/x` → `~/x`.
nonisolated enum PathDisplay {
    static func abbreviatingHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}


// MARK: - Avatar

/// Tab avatar: a rounded square with the project's first letter for a live
/// session, a folder glyph for a picker tab. The active tab is filled with
/// the accent; a busy tab (Claude writing) gets a yellow pulse around it
/// ("busy" reads yellow, apart from the green "idle");
/// an idle session that is not active shows a small status dot.
struct TabAvatar: View {
    let tab: TerminalTab
    let isActive: Bool
    /// The square's side: 28 in the sidebar, 24 in the top tab bar.
    var size: CGFloat = 28
    /// Room around the square for the busy ring and the corner marks.
    private var frameSize: CGFloat { size + 6 }
    private var cornerRadius: CGFloat { size * 2 / 7 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(backgroundFill)
                .frame(width: size, height: size)
            glyph
            if tab.isBusy {
                BusyRing(side: frameSize - 1, cornerRadius: cornerRadius + 2)
                    // A click or drag on a working tab's avatar is the row's.
                    .allowsHitTesting(false)
            } else if tab.needsAttention, case .needsInput = tab.claudeState {
                AttentionBadge(color: AppTheme.Colors.statusAmber, symbol: "exclamationmark")
                    .frame(width: frameSize, height: frameSize, alignment: .topTrailing)
            } else if tab.needsAttention {
                AttentionBadge(color: AppTheme.Colors.statusBlue, symbol: nil)
                    .frame(width: frameSize, height: frameSize, alignment: .topTrailing)
            } else if tab.session?.isStarted == true && !isActive {
                // A restored tab not opened yet runs nothing: no dot.
                Circle()
                    .fill(AppTheme.Colors.statusGreen)
                    .frame(width: 6, height: 6)
                    .frame(width: frameSize, height: frameSize, alignment: .bottomTrailing)
            }
        }
        .frame(width: frameSize, height: frameSize)
    }

    @ViewBuilder
    private var glyph: some View {
        if tab.hasAnyRunningSession {
            Text(Self.initial(of: projectName))
                .font(.system(size: size * 13 / 28, weight: .bold, design: .rounded))
                .foregroundStyle(glyphColor)
        } else {
            Image(systemName: "folder")
                .font(.system(size: size * 11 / 28, weight: .semibold))
                .foregroundStyle(glyphColor)
        }
    }

    /// The project folder of the shell's current directory; the tab title
    /// when there is no directory yet.
    private var projectName: String {
        if let cwd = tab.liveCwd, !cwd.isEmpty {
            let folder = (cwd as NSString).lastPathComponent
            if !folder.isEmpty, folder != "/" { return folder }
        }
        return tab.displayTitle
    }

    /// First letter or digit, uppercased (`.dotfiles` → "D", `sample-api`
    /// → "S", `проєкт` → "П"); "?" when the name has none.
    static func initial(of name: String) -> String {
        guard let first = name.first(where: { $0.isLetter || $0.isNumber }) else { return "?" }
        return String(first).uppercased()
    }

    private var backgroundFill: Color {
        if isActive { return AppTheme.Colors.accent }
        return Color.primary.opacity(tab.hasAnyRunningSession ? 0.14 : 0.06)
    }

    private var glyphColor: Color {
        if isActive { return .white }
        return tab.hasAnyRunningSession ? .secondary : Color.secondary.opacity(0.7)
    }
}

/// Top-right mark on the avatar: blue dot = Claude finished and the tab
/// hasn't been looked at, orange "!" = Claude asks for permission (picked
/// from attention mock-ups). A dark ring keeps it apart from the
/// square on any row background.
private struct AttentionBadge: View {
    let color: Color
    let symbol: String?

    var body: some View {
        ZStack {
            Circle().fill(color)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(.black.opacity(0.8))
            }
        }
        .frame(width: symbol == nil ? 9 : 12, height: symbol == nil ? 9 : 12)
        .overlay(Circle().stroke(Color(white: 0.12), lineWidth: 1.5))
    }
}

/// Busy pulse: a yellow outline around the avatar that breathes, with a
/// soft ripple spreading out from it ("busy" reads yellow, apart
/// from the green "idle"; a spinning arc looked cheap). Its own view so the
/// animation state lives only while the tab is busy.
private struct BusyRing: View {
    let side: CGFloat
    let cornerRadius: CGFloat
    @State private var animating = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            shape
                .stroke(AppTheme.Colors.statusBusy, lineWidth: 3)
                .scaleEffect(animating ? 1.22 : 1)
                .opacity(animating ? 0 : 0.5)
                .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: animating)
            shape
                .stroke(AppTheme.Colors.statusBusy, lineWidth: 1.5)
                .opacity(animating ? 1 : 0.45)
                .shadow(color: AppTheme.Colors.statusBusy.opacity(animating ? 0.6 : 0), radius: 3)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: animating)
        }
        .frame(width: side, height: side)
        .onAppear { animating = true }
    }
}
