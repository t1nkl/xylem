//
//  RightPanel.swift
//  Xylem
//
//  The right side of the window: the Claude / Git panel, the panel rail at
//  the window's edge and the Files / Changes drawer over the terminal. One
//  of panel and drawer at a time. Each is its
//  own view reading only its own state, so opening one re-renders it, not
//  ContentView.
//

import SwiftUI
import AppKit

// MARK: - Rail

/// Claude / Git switch the panel (a click on the shown one hides it),
/// Files / Changes toggle the drawer.
struct PanelRailContainer: View {
    let drawer: ProjectDrawerModel
    @Binding var showsInspector: Bool
    @Binding var panelTab: RightSidebarView.SidebarTab
    let directory: () -> String?
    /// The drawer closed (any way): the keyboard goes back to the terminal -
    /// a click in the preview or diff (selectable text) may have taken it.
    var onDrawerClosed: () -> Void = {}

    var body: some View {
        PanelRail(selected: selected) { item in
            PanelSwitch.select(item, showsInspector: $showsInspector, panelTab: $panelTab,
                               drawer: drawer, directory: directory())
        }
        // The drawer hides the panel in the frame it appears, not on the
        // click: it waits for its first load, and hiding the panel first
        // left the right side empty for that moment - it read as a blink.
        .onChange(of: drawer.mode) { old, mode in
            if mode != nil { showsInspector = false }
            if old != nil, mode == nil { onDrawerClosed() }
        }
    }

    private var selected: Set<PanelRailItem> {
        var items: Set<PanelRailItem> = []
        if showsInspector { items.insert(panelTab == .git ? .git : .claude) }
        switch drawer.mode {
        case .files: items.insert(.files)
        case .changes: items.insert(.changes)
        case nil: break
        }
        return items
    }

}

/// What a rail icon does - shared by the rail and its View-menu hotkeys
/// (⌃⌘1-4). Claude / Git: show that panel tab, or hide the panel when it
/// already shows it (showing it closes the drawer). Files / Changes: toggle
/// the drawer.
@MainActor
enum PanelSwitch {
    static func select(
        _ item: PanelRailItem,
        showsInspector: Binding<Bool>,
        panelTab: Binding<RightSidebarView.SidebarTab>,
        drawer: ProjectDrawerModel,
        directory: String?
    ) {
        switch item {
        case .claude, .git:
            let tab: RightSidebarView.SidebarTab = item == .git ? .git : .claude
            if showsInspector.wrappedValue && panelTab.wrappedValue == tab {
                showsInspector.wrappedValue = false
            } else {
                drawer.close()
                panelTab.wrappedValue = tab
                showsInspector.wrappedValue = true
            }
        case .files:
            drawer.toggle(.files, directory: directory)
        case .changes:
            drawer.toggle(.changes, directory: directory)
        }
    }
}

// MARK: - Panel

/// The Claude / Git panel, resizable by its left edge. Zero width (not
/// removed) while hidden, so its sections keep their expanded state.
struct RightPanelContainer<Content: View>: View {
    let isShown: Bool
    /// What the window can spare (see `maxWidth(detailWidth:)`).
    var maxWidth: CGFloat = AppTheme.Metrics.inspectorMaxWidth
    @ViewBuilder let content: () -> Content
    @AppStorage(AppSettings.Keys.rightPanelWidth) private var storedWidth: Double = AppTheme.Metrics.inspectorIdealWidth
    @State private var dragWidth: CGFloat?

    /// The panel never squeezes the terminal under `minTerminalWidth`: the
    /// rail takes 56 pt, so in a narrow window with a wide tab list the
    /// terminal would otherwise drop to ~240 pt.
    static func maxWidth(detailWidth: CGFloat) -> CGFloat {
        let room = detailWidth - AppTheme.Metrics.panelRailWidth - AppTheme.Metrics.minTerminalWidth
        return min(AppTheme.Metrics.inspectorMaxWidth, max(AppTheme.Metrics.inspectorMinWidth, room))
    }

    var body: some View {
        let range = AppTheme.Metrics.inspectorMinWidth...max(AppTheme.Metrics.inspectorMinWidth, maxWidth)
        let width = (dragWidth ?? CGFloat(storedWidth)).clamped(to: range)
        content()
            .frame(width: width)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(AppTheme.Colors.panelBackground)
            .overlay(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.black.opacity(0.5)).frame(width: 1)
                    ColumnResizeHandle(width: width, range: range, liveWidth: $dragWidth) { storedWidth = Double($0) }
                }
            }
            .frame(width: isShown ? width : 0, alignment: .leading)
            .clipped()
            .allowsHitTesting(isShown)
            .accessibilityHidden(!isShown)
    }
}

// MARK: - Drawer

struct ProjectDrawerContainer: View {
    let drawer: ProjectDrawerModel
    let actions: ProjectDrawerActions
    /// Dragged by the drawer's left edge; remembered.
    @AppStorage(AppSettings.Keys.drawerWidth) private var storedWidth: Double = AppTheme.Metrics.drawerWidth
    @State private var dragWidth: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            if drawer.mode != nil {
                let range = AppTheme.Metrics.drawerMinWidth...max(AppTheme.Metrics.drawerMinWidth, proxy.size.width * AppTheme.Metrics.drawerMaxFraction)
                let width = (dragWidth ?? CGFloat(storedWidth)).clamped(to: range)
                ProjectDrawerView(model: drawer, actions: actions)
                    .frame(width: width)
                    .overlay(alignment: .leading) {
                        ColumnResizeHandle(width: width, range: range, liveWidth: $dragWidth, handleWidth: 8) { storedWidth = Double($0) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
        }
        // No slide: the panel appears at once, and a drawer sliding next to
        // it looked inconsistent. Both switch instantly.
    }
}

// MARK: - Resize handle

/// An invisible strip on a right-anchored column's left edge: dragging left
/// widens the column. `liveWidth` follows the drag; `onCommit` gets the final
/// width once. The system's column-resize pointer, not NSCursor push/pop (a
/// column closed under the pointer never gets the hover exit, and the cursor
/// would stay pushed).
struct ColumnResizeHandle: View {
    let width: CGFloat
    let range: ClosedRange<CGFloat>
    @Binding var liveWidth: CGFloat?
    var handleWidth: CGFloat = 6
    let onCommit: (CGFloat) -> Void
    @State private var dragStart: CGFloat?

    var body: some View {
        Color.clear
            .frame(width: handleWidth)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStart == nil { dragStart = width }
                        liveWidth = ((dragStart ?? width) - value.translation.width).clamped(to: range)
                    }
                    .onEnded { _ in
                        if let liveWidth { onCommit(liveWidth) }
                        liveWidth = nil
                        dragStart = nil
                    }
            )
            .help("Drag to resize")
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
