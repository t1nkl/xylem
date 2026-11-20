//
//  InstantTooltip.swift
//  Xylem
//
//  A tooltip that shows the moment the pointer is over a view (the system
//  one, `.help`, waits about a second). It is a borderless panel under the
//  view that never becomes key or main and ignores the mouse: the terminal
//  keeps the keyboard, so Claude sees no focus change (a popover would take
//  key, and the terminal would report focus-out to Claude on every hover).
//  One panel is shared by every such tooltip. AppKit doesn't always send the
//  hover exit (a sheet, a tab switch, full screen), so the panel also goes
//  when its window stops being key, moves, resizes, minimizes or closes, and
//  when the app is deactivated.
//

import AppKit
import SwiftUI

extension View {
    /// `text` in a tooltip shown at once on hover; also the view's
    /// accessibility value.
    func instantTooltip(_ text: String) -> some View {
        modifier(InstantTooltipModifier(text: text))
    }
}

private struct InstantTooltipModifier: ViewModifier {
    let text: String
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(TooltipAnchor(text: text, isShown: isHovering))
            .onHover { isHovering = $0 }
            .accessibilityValue(text)
    }
}

/// Finds where the view is on screen and shows or hides the shared panel.
private struct TooltipAnchor: NSViewRepresentable {
    let text: String
    let isShown: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        if isShown {
            TooltipPanel.shared.show(text, below: view)
        } else {
            TooltipPanel.shared.hide(from: view)
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        TooltipPanel.shared.hide(from: view)
    }
}

private final class TooltipPanel: NSPanel {
    static let shared = TooltipPanel()

    private let host = NSHostingView(rootView: TooltipText(text: ""))
    /// The view the panel is shown for: a hide from another anchor (an
    /// update of a view the pointer already left) leaves it alone.
    private weak var owner: NSView?
    /// Window notifications that end the tooltip, for the owner's window.
    private var windowObservers: [NSObjectProtocol] = []
    private weak var observedWindow: NSWindow?

    private init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        level = .popUpMenu
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ text: String, below anchor: NSView) {
        // Not over a sheet or another app: a re-render while the pointer
        // still rests on the view would bring it back.
        guard let window = anchor.window, let screen = window.screen, window.isKeyWindow, NSApp.isActive
        else { return }
        owner = anchor
        host.rootView = TooltipText(text: text)
        let size = host.fittingSize
        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let visible = screen.visibleFrame
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 6)
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        // No room below (the window at the bottom of the screen): above.
        if origin.y < visible.minY { origin.y = rect.maxY + 6 }
        setFrame(NSRect(origin: origin, size: size), display: true)
        observe(window)
        if !isVisible { orderFront(nil) }
    }

    func hide(from anchor: NSView) {
        guard owner === anchor else { return }
        dismiss()
    }

    private func dismiss() {
        owner = nil
        orderOut(nil)
    }

    private func observe(_ window: NSWindow) {
        guard observedWindow !== window else { return }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        observedWindow = window
        let names: [Notification.Name] = [
            NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didMoveNotification,
            NSWindow.didResizeNotification, NSWindow.willEnterFullScreenNotification,
            NSWindow.willExitFullScreenNotification
        ]
        windowObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        }
    }
}

private struct TooltipText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(AppTheme.Colors.textPrimary)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(AppTheme.Colors.panelBackground))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(AppTheme.Colors.panelBorderStrong, lineWidth: 1))
    }
}
