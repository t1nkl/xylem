//
//  TopTabBar.swift
//  Xylem
//
//  The tab list above the terminal, for Settings > General > Tabs "Above the
//  terminal" (the sidebar is the default): two-line tabs of a fixed width
//  (avatar with the same status marks as the sidebar, title, the latest prompt
//  or "Needs your permission…"), scrolling sideways when they don't fit, and a
//  card with the whole prompt, branch and path after a moment's hover.
//
//  Reordering is a drag gesture, not drag and drop: tabs have one width,
//  so each neighbour crossed is one `moveTab(by:)` step on the live order.
//  Nothing goes through the pasteboard, so a cancelled drag or a file
//  dragged in from the Finder can never reorder anything.
//
//  A mouse's vertical wheel over the bar scrolls the tabs sideways, like a
//  browser's tab strip; without it a mouse could only scroll them with
//  Shift held.
//
//  Like the sidebar, a click hands the keyboard back to the terminal
//  (`onSelect` / `onReactivate`), and each tab is its own view, so a tab's
//  busy or prompt change re-renders only that tab.
//

import SwiftUI
import AppKit

struct TopTabBar: View {
    let tabs: [TerminalTab]
    let activeTabID: TerminalTab.ID?
    /// Changes when the active tab should come into view though it stayed
    /// the same (⌘1-9 on the tab that is already active).
    var revealRequest: Int = 0

    var onSelect: (TerminalTab.ID) -> Void = { _ in }
    /// After a click on the active tab and after a rename ends.
    var onReactivate: () -> Void = {}
    var onClose: (TerminalTab.ID) -> Void = { _ in }
    var onRename: (TerminalTab.ID, String) -> Void = { _, _ in }
    /// One step left (-1) or right (+1); false when nothing moved.
    var onMoveTab: (TerminalTab.ID, Int) -> Bool = { _, _ in false }
    var onCloseOthers: (TerminalTab.ID) -> Void = { _ in }
    var onNewTab: () -> Void = {}
    var onShowOverview: () -> Void = {}

    static let height: CGFloat = 56
    static let tabWidth: CGFloat = 200
    static let spacing: CGFloat = 6
    /// Where a drag's translation is measured: the row of tabs, which
    /// stays put while the dragged tab moves through it.
    fileprivate static let dragSpace = "TopTabBar.tabs"

    /// The tab being dragged, how far it sits from its slot, and how much
    /// of the drag's translation the steps so far have used up.
    @State private var draggedID: TerminalTab.ID?
    @State private var dragOffset: CGFloat = 0
    @State private var consumedTranslation: CGFloat = 0
    /// For the vertical wheel: where the row is scrolled to and how far it
    /// can go, in a plain box so geometry reports don't re-render the bar
    /// (a wheel step itself does, through `scrollPosition`).
    @State private var scroll = ScrollState()
    @State private var scrollPosition = ScrollPosition()

    var body: some View {
        HStack(spacing: Self.spacing) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: Self.spacing) {
                        ForEach(tabs) { tab in
                            let isDragged = tab.id == draggedID
                            TopTab(
                                tab: tab,
                                isActive: tab.id == activeTabID,
                                canClose: tabs.count > 1,
                                isDragging: draggedID != nil,
                                onSelect: { onSelect(tab.id) },
                                onReactivate: onReactivate,
                                onClose: { onClose(tab.id) },
                                onRename: { onRename(tab.id, $0) },
                                onCloseOthers: { onCloseOthers(tab.id) },
                                onDragChanged: { dragChanged(tab.id, translation: $0) },
                                onDragEnded: dragEnded
                            )
                            .frame(width: Self.tabWidth)
                            .offset(x: isDragged ? dragOffset : 0)
                            .zIndex(isDragged ? 1 : 0)
                            .id(tab.id)
                        }
                    }
                    // 4 + the scroll view's 1 below = 5 above the tabs, as below.
                    .padding(.top, 4)
                    .padding(.bottom, 5)
                    .coordinateSpace(.named(Self.dragSpace))
                }
                .scrollIndicators(.never)
                // Not touching the toolbar: a scroll view at the top edge of
                // the safe area extends under the toolbar. macOS 26 and later
                // give it a matching content inset; macOS 15 does not, so its
                // AppKit document view sat ~40 pt above the drawn tabs and
                // hover and clicks worked only in their top ~10 pt.
                .padding(.top, 1)
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: CGRect.self) { geometry in
                    CGRect(x: geometry.contentOffset.x, y: 0,
                           width: max(0, geometry.contentSize.width - geometry.containerSize.width), height: 0)
                } action: { _, now in
                    scroll.offset = now.minX
                    scroll.maxOffset = now.width
                }
                .modifier(VerticalWheelScrollsSideways { delta in
                    let x = min(max(0, scroll.offset - delta), scroll.maxOffset)
                    guard x != scroll.offset else { return }
                    scrollPosition.scrollTo(x: x)
                    // Wheel events can arrive before the next layout reports it.
                    scroll.offset = x
                })
                .onAppear { reveal(activeTabID, with: proxy, animated: false) }
                // A tab opened with ⌘T, a ⌘1-9 switch, the palette: the
                // active tab is always in view.
                .onChange(of: activeTabID) { _, id in reveal(id, with: proxy, animated: true) }
                .onChange(of: revealRequest) { reveal(activeTabID, with: proxy, animated: true) }
                // A drag whose tab went away (⌘W mid-drag) never ends:
                // without this the bar would think it is still dragging.
                .onChange(of: tabs.map(\.id)) { _, ids in
                    if let draggedID, !ids.contains(draggedID) { dragEnded() }
                }
            }
            TopBarButton(systemImage: "plus", help: "New Tab (⌘T)", action: onNewTab)
            TopBarButton(systemImage: "square.grid.2x2", help: "All sessions overview", action: onShowOverview)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(AppTheme.Colors.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppTheme.Colors.divider).frame(height: 1)
        }
    }

    private func reveal(_ id: TerminalTab.ID?, with proxy: ScrollViewProxy, animated: Bool) {
        guard let id, draggedID == nil else { return }
        // On the next turn: a tab that was just added has no frame yet.
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id) }
            } else {
                proxy.scrollTo(id)
            }
        }
    }

    /// The dragged tab follows the pointer; past half a neighbour it trades
    /// places with it, and its offset drops by that one slot so it stays
    /// under the pointer while the neighbour slides over.
    private func dragChanged(_ id: TerminalTab.ID, translation: CGFloat) {
        if draggedID != id {
            draggedID = id
            consumedTranslation = 0
        }
        let slot = Self.tabWidth + Self.spacing
        let offset = translation - consumedTranslation
        guard abs(offset) > slot / 2 else {
            dragOffset = offset
            return
        }
        // The move and the offset change in one animated transaction: the
        // dragged tab's slot and its offset interpolate together, so it stays
        // under the pointer while the neighbour slides over. A fast drag can
        // cross several tabs between two events.
        withAnimation(.easeInOut(duration: 0.15)) {
            var remaining = offset
            while abs(remaining) > slot / 2 {
                let step = remaining > 0 ? 1 : -1
                guard onMoveTab(id, step) else { break }
                consumedTranslation += CGFloat(step) * slot
                remaining -= CGFloat(step) * slot
            }
            dragOffset = remaining
        }
    }

    private func dragEnded() {
        withAnimation(.easeOut(duration: 0.15)) { dragOffset = 0 }
        draggedID = nil
        consumedTranslation = 0
        // The keyboard belongs to the terminal (the terminals' stack was
        // reordered under it).
        onReactivate()
    }
}

/// Where the tab row is scrolled to, kept out of SwiftUI's change tracking.
private final class ScrollState {
    var offset: CGFloat = 0
    var maxOffset: CGFloat = 0
}

/// A vertical wheel (or a vertical swipe) over the view scrolls it sideways.
/// One app-wide monitor while the bar exists; each event is checked against
/// the bar itself (an AppKit probe behind it: its window and frame), so a
/// wheel anywhere else - the terminal's scrollback, another window, a sheet
/// over the bar - passes through untouched. Not tied to hover: a missed
/// hover exit could otherwise leave the terminal unable to scroll.
private struct VerticalWheelScrollsSideways: ViewModifier {
    /// Points to move; positive = towards the start.
    let scrollBy: (CGFloat) -> Void
    @State private var monitor: Any?
    @State private var probe = WheelProbe()

    /// A mouse wheel reports lines, not points.
    private static let pointsPerLine: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background(WheelProbe.Anchor(probe: probe))
            .onAppear(perform: install)
            .onDisappear(perform: remove)
    }

    private func install() {
        guard monitor == nil else { return }
        let scrollBy = scrollBy
        let probe = probe
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                  MainActor.assumeIsolated({ probe.contains(event) }) else { return event }
            let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : Self.pointsPerLine)
            scrollBy(delta)
            return nil
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// The bar's place in AppKit terms, for the wheel monitor: a plain view
/// behind the bar, held weakly.
private final class WheelProbe {
    weak var view: NSView?

    /// The event is a wheel over the bar in a window the user works in.
    func contains(_ event: NSEvent) -> Bool {
        guard let view, let window = view.window, event.window === window,
              window.isKeyWindow, window.attachedSheet == nil else { return false }
        return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
    }

    struct Anchor: NSViewRepresentable {
        let probe: WheelProbe

        func makeNSView(context: Context) -> NSView {
            let view = PassThroughView()
            probe.view = view
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            probe.view = nsView
        }
    }

    /// Takes no clicks: it only marks where the bar is.
    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - Tab

/// One tab: avatar, title and the prompt line. Its own view so a tab's
/// state or prompt change re-renders only this tab.
private struct TopTab: View {
    let tab: TerminalTab
    let isActive: Bool
    let canClose: Bool
    /// Some tab is being dragged: no hover card meanwhile.
    let isDragging: Bool
    let onSelect: () -> Void
    let onReactivate: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void
    let onCloseOthers: () -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    @State private var isHovering = false
    @State private var isEditing = false
    @State private var showsCard = false

    private static let cardDelay: Duration = .milliseconds(700)

    var body: some View {
        HStack(spacing: 8) {
            TabAvatar(tab: tab, isActive: isActive, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    TabTitleField(title: tab.displayTitle, isEditing: $isEditing,
                                  onRename: onRename, onFinish: onReactivate) {
                        Text(tab.displayTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isActive ? AppTheme.Colors.textPrimary : AppTheme.Colors.panelText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 2)
                    if !isEditing && canClose && isHovering {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .semibold))
                                .frame(width: 15, height: 15)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(CloseTabButtonStyle())
                        .help("Close Tab")
                        .accessibilityLabel("Close \(tab.displayTitle)")
                    }
                }
                .frame(height: 16)
                promptLine
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isActive ? AppTheme.Colors.tabActiveBackground : Color.white.opacity(isHovering ? 0.06 : 0.025))
                .shadow(color: .black.opacity(isActive ? 0.35 : 0), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.white.opacity(isActive ? 0.10 : 0.04), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isEditing else { return }
            showsCard = false
            if isActive { onReactivate() } else { onSelect() }
        }
        .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named(TopTabBar.dragSpace))
                .onChanged { onDragChanged($0.translation.width) }
                .onEnded { _ in onDragEnded() },
            isEnabled: !isEditing && canClose
        )
        .onHover { hovering in
            isHovering = hovering
            if !hovering { showsCard = false }
        }
        .task(id: isHovering) {
            guard isHovering else { return }
            try? await Task.sleep(for: Self.cardDelay)
            if !Task.isCancelled, isHovering { showsCard = true }
        }
        .anchorPreference(key: TopTabHoverCardKey.self, value: .bounds) { anchor in
            showsCard && !isDragging && !isEditing ? [tab.id: anchor] : [:]
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { if isActive { onReactivate() } else { onSelect() } }
        .contextMenu {
            Button("Rename…") { isEditing = true }
            Divider()
            if canClose {
                Button("Close Tab", action: onClose)
                Button("Close Other Tabs", action: onCloseOthers)
            }
        }
    }

    /// The latest prompt, or the permission question in amber; a dimmed
    /// placeholder until there is a prompt.
    @ViewBuilder
    private var promptLine: some View {
        if tab.needsAttention, case .needsInput(let message) = tab.claudeState {
            Text(TabRowText.needsInputLine(message))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Colors.statusAmber)
                .lineLimit(1)
        } else if let prompt = tab.lastPrompt, !prompt.isEmpty {
            Text(prompt)
                .font(.system(size: 11))
                .foregroundStyle(isActive ? AppTheme.Colors.textSecondary : AppTheme.Colors.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            Text(tab.hasAnyRunningSession ? "No prompt yet" : "Pick a folder")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.Colors.textMuted.opacity(0.7))
                .lineLimit(1)
        }
    }
}

/// "+" and All Sessions after the tabs.
private struct TopBarButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHovering ? AppTheme.Colors.textPrimary : AppTheme.Colors.textSecondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(isHovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Hover card

/// The hovered tab's frame, reported only while its card should show.
struct TopTabHoverCardKey: PreferenceKey {
    static let defaultValue: [TerminalTab.ID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TerminalTab.ID: Anchor<CGRect>],
                       nextValue: () -> [TerminalTab.ID: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Draws the hover card of a top tab over this view (the tab bar and
    /// the terminal under it), below the tab and kept inside the view.
    func topTabHoverCard(tabs: [TerminalTab]) -> some View {
        overlayPreferenceValue(TopTabHoverCardKey.self) { anchors in
            GeometryReader { proxy in
                if let (id, anchor) = anchors.first, let tab = tabs.first(where: { $0.id == id }) {
                    let rect = proxy[anchor]
                    let x = min(max(8, rect.minX), proxy.size.width - TopTabHoverCard.width - 8)
                    TopTabHoverCard(tab: tab)
                        .offset(x: x, y: rect.maxY + 6)
                }
            }
            // Never in the way of clicks, selection or drops on the terminal.
            .allowsHitTesting(false)
        }
    }
}

/// The whole prompt, the state, branch and path of a hovered top tab: what
/// the sidebar's three lines show, which a 200 pt tab can't.
private struct TopTabHoverCard: View {
    let tab: TerminalTab
    static let width: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text(state.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(state.color)
            }
            if let prompt = tab.lastPrompt, !prompt.isEmpty {
                Text(prompt)
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.Colors.panelText)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let branch = tab.gitBranch, !branch.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9, weight: .medium))
                        Text(branch).lineLimit(1).truncationMode(.middle)
                    }
                }
                Text(path).lineLimit(2).truncationMode(.head)
            }
            .font(.system(size: 11))
            .foregroundStyle(AppTheme.Colors.textMuted)
        }
        .padding(12)
        .frame(width: Self.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppTheme.Colors.panelBackground))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppTheme.Colors.panelBorderStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
    }

    private var path: String {
        guard let cwd = tab.liveCwd, !cwd.isEmpty else { return "No folder selected" }
        return PathDisplay.abbreviatingHome(cwd)
    }

    /// The same states the avatar marks, in words.
    private var state: (text: String, color: Color) {
        if tab.isBusy { return ("Claude is working", AppTheme.Colors.statusBusy) }
        if tab.needsAttention, case .needsInput(let message) = tab.claudeState {
            return (TabRowText.needsInputLine(message), AppTheme.Colors.statusAmber)
        }
        if tab.needsAttention { return ("Claude finished", AppTheme.Colors.statusBlue) }
        if !tab.hasAnyRunningSession { return ("Waiting for a folder", AppTheme.Colors.textMuted) }
        if tab.session?.isStarted != true { return ("Starts when you open it", AppTheme.Colors.textMuted) }
        return ("Idle", AppTheme.Colors.textMuted)
    }
}
