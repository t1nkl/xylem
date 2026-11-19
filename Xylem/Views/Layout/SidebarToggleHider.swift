//
//  SidebarToggleHider.swift
//  Xylem
//
//  Hides the split view's sidebar button while the tabs are on top (there
//  is no sidebar to show then), and keeps the hidden column shut (see
//  `watchSplitView()`). SwiftUI's `.toolbar(removing: .sidebarToggle)`
//  leaves the button in place in this window wherever it is applied (the
//  split view, its sidebar or its detail), so the window's
//  NSToolbarItem is hidden directly. The item is matched by identifier;
//  SwiftUI names it `com.apple.SwiftUI.navigationSplitView.toggleSidebar`.
//  An item the toolbar adds later (SwiftUI rebuilds the toolbar when its
//  content changes) gets the same treatment. If no item matches, the button
//  simply stays: clicking it then does nothing, as the split view's column
//  visibility ignores changes while the tabs are on top.
//

import SwiftUI
import AppKit

struct SidebarToggleHider: NSViewRepresentable {
    let isHidden: Bool

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.hidesToggle = isHidden
        // Every update, not only on a change: SwiftUI may have rebuilt the
        // toolbar (its content changed) since the last one. ~8 items.
        nsView.attach()
    }

    final class Probe: NSView {
        var hidesToggle = false

        /// It lies behind the whole detail column: it takes no mouse events.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        private var observer: NSObjectProtocol?
        private weak var observedToolbar: NSToolbar?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
            // SwiftUI may attach or fill the toolbar after the content
            // joins the window (a launch with the tabs already on top).
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        /// Watches the window's current toolbar for re-added items (a new
        /// toolbar replaces the old observer), then hides the button.
        func attach() {
            let toolbar = window?.toolbar
            if toolbar !== observedToolbar {
                if let observer { NotificationCenter.default.removeObserver(observer) }
                observer = nil
                observedToolbar = toolbar
                if let toolbar {
                    observer = NotificationCenter.default.addObserver(
                        forName: NSToolbar.willAddItemNotification, object: toolbar, queue: .main
                    ) { [weak self] note in
                        guard let item = note.userInfo?["item"] as? NSToolbarItem else { return }
                        MainActor.assumeIsolated {
                            guard let self, Self.isSidebarToggle(item) else { return }
                            Self.setHidden(item, self.hidesToggle)
                        }
                    }
                }
            }
            for item in toolbar?.items ?? [] where Self.isSidebarToggle(item) {
                Self.setHidden(item, hidesToggle)
            }
            watchSplitView()
        }

        private var splitObserver: NSObjectProtocol?
        private weak var observedSplit: NSSplitView?

        /// A collapsed sidebar column can come back without the split view's
        /// visibility asking for it: in full screen on macOS 15 AppKit slides
        /// it in over the content when the pointer touches the screen's left
        /// edge, or on a drag from there, and the visibility changes only
        /// after that slide. While the tabs are on top the collapsed column is
        /// marked as not collapsible, which turns that off; it is collapsible
        /// again before the sidebar comes back. Checked on every update and
        /// every resize of the split view, so it also holds once the column
        /// has collapsed (a launch with the tabs on top).
        private func watchSplitView() {
            guard let split = enclosingSplitView() else { return }
            pinSidebar(in: split)
            guard split !== observedSplit else { return }
            if let splitObserver { NotificationCenter.default.removeObserver(splitObserver) }
            observedSplit = split
            splitObserver = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification, object: split, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let split = self.observedSplit else { return }
                    self.pinSidebar(in: split)
                }
            }
        }

        private func pinSidebar(in split: NSSplitView) {
            guard let item = (split.delegate as? NSSplitViewController)?
                .splitViewItems.first(where: { $0.behavior == .sidebar })
            else { return }
            if hidesToggle {
                if item.isCollapsed, item.canCollapse { item.canCollapse = false }
            } else if !item.canCollapse {
                item.canCollapse = true
            }
        }

        private func enclosingSplitView() -> NSSplitView? {
            var view = superview
            while let current = view {
                if let split = current as? NSSplitView, split.isVertical,
                   split.delegate is NSSplitViewController {
                    return split
                }
                view = current.superview
            }
            return nil
        }

        /// `isHidden` hides the item on macOS 26 and later; macOS 15 keeps
        /// the flag but still draws the button, so its view is hidden too
        /// (there its slot stays as a small gap).
        static func setHidden(_ item: NSToolbarItem, _ hidden: Bool) {
            if item.isHidden != hidden { item.isHidden = hidden }
            if let view = item.view, view.isHidden != hidden { view.isHidden = hidden }
        }

        static func isSidebarToggle(_ item: NSToolbarItem) -> Bool {
            item.itemIdentifier == .toggleSidebar || item.itemIdentifier.rawValue.hasSuffix(".toggleSidebar")
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if let splitObserver { NotificationCenter.default.removeObserver(splitObserver) }
        }
    }
}
