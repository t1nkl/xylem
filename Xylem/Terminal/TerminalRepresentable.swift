//
//  TerminalRepresentable.swift
//  Xylem
//
//  Thin SwiftUI bridge. The terminal NSView is owned by TerminalSession;
//  this representable puts it, inset by the terminal padding, into a
//  container painted with the terminal background.
//
//  It also carries the tab's active state down to AppKit, because two
//  things SwiftUI's `opacity(0)` can't do have to happen on the NSView:
//  stop a background tab from rendering, and move keyboard focus to the
//  terminal that just became visible.
//

import SwiftUI
import AppKit
import SwiftTerm

struct TerminalRepresentable: NSViewRepresentable {
    let session: TerminalSession
    let isActive: Bool

    func makeNSView(context: Context) -> TerminalContainerView {
        TerminalContainerView(terminal: session.terminalView)
    }

    func updateNSView(_ nsView: TerminalContainerView, context: Context) {
        nsView.adopt(session.terminalView)
        nsView.setActive(isActive)
    }
}

/// Hosts the terminal with `TerminalAppearance.padding` around it. The
/// padding is painted with the terminal background so the grid and the
/// frame read as one surface, and clicks in it focus the terminal.
final class TerminalContainerView: NSView {
    private weak var terminal: NSView?
    /// nil until the first `setActive`, so the first call always applies.
    private var isActive: Bool?
    /// The first time this terminal is shown (app launch with this tab
    /// active, or a project just opened into it) it takes the keyboard
    /// unconditionally. Otherwise AppKit's initial first responder - the
    /// tab sidebar's "Search tabs…" field - kept it, and the first thing
    /// typed after launch went into the search box instead of Claude.
    private var hasHadInitialFocus = false

    init(terminal: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = TerminalAppearance.background.cgColor
        adopt(terminal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The session's view outlives any one container (SwiftUI may rebuild
    /// it), so take it over if another container still holds it.
    func adopt(_ view: NSView) {
        guard view.superview !== self else { return }
        if let previous = terminal, previous !== view, previous.superview === self {
            previous.removeFromSuperview()
        }
        let replaced = terminal != nil && terminal !== view
        view.removeFromSuperview()
        addSubview(view)
        terminal = view
        needsLayout = true
        // Another terminal in this container (a restarted tab's new
        // session): forget the old state so the next `setActive` hides it
        // in a background tab, or focuses it in the active one. Before, a
        // restarted background terminal stayed unhidden and drew every
        // frame.
        if replaced { isActive = nil }
    }

    // MARK: - Active state

    /// Hides inactive terminals and focuses the active one.
    ///
    /// Hiding is what stops a background tab streaming Claude output from
    /// drawing on main: SwiftTerm's FrameDriver ticks from
    /// `NSView.displayLink(target:selector:)` (macOS 14+ backend, which our
    /// macOS 15 minimum always gets), and per MacTerminalView's own docs that
    /// link "does not fire while the view is hidden", so output only marks
    /// the driver dirty. `viewDidUnhide` then draws a frame immediately, so
    /// unhiding never flashes stale content. SwiftTerm's own pausing only
    /// covers window occlusion / miniaturise / app hide - never a sibling
    /// at opacity 0.
    ///
    /// `isHidden` goes on the terminal view, not on this container: the
    /// container belongs to SwiftUI's hierarchy. The terminal stays in the
    /// window with its frame intact - leaving the window or collapsing to
    /// zero size would tear down the display link or SIGWINCH the shell
    /// down to a 1x1 grid.
    func setActive(_ active: Bool) {
        let wasActive = isActive
        isActive = active
        guard let terminal, terminal.superview === self else { return }

        if !active {
            guard wasActive != false else { return }
            // Hiding the first responder makes AppKit hand focus to the next
            // valid key view - possibly the sidebar search field, which would
            // then block the focus hand-off below. Park focus on the window
            // instead so the newly active terminal can take it.
            if let window, let responder = window.firstResponder as? NSView,
               responder.isDescendant(of: terminal) {
                window.makeFirstResponder(nil)
            }
            terminal.isHidden = true
            return
        }

        if terminal.isHidden { terminal.isHidden = false }
        // Runs on first attach too (picker → session, restored active tab):
        // a fresh terminal must get the keyboard without an extra click.
        if wasActive != true { requestFocus() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // `setActive(true)` may have run before SwiftUI put us in a window.
        guard isActive == true, let window, let terminal, terminal.superview === self else { return }
        // Picked by AppKit when the window first becomes key, before any
        // text field can claim the keyboard.
        window.initialFirstResponder = terminal
        requestFocus()
    }

    /// Deferred one turn so every tab's `updateNSView` in this SwiftUI
    /// update has run (the outgoing terminal has parked focus by then) and
    /// so we never mutate the responder chain mid-update.
    private func requestFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive == true,
                  let terminal = self.terminal, terminal.superview === self,
                  let window = self.window
            else { return }
            let initial = !self.hasHadInitialFocus
            if initial || Self.shouldTakeFocus(from: window.firstResponder, in: window, for: terminal) {
                if window.makeFirstResponder(terminal) { self.hasHadInitialFocus = true }
            }
        }
    }

    /// Takes focus only when nothing meaningful holds it: nothing focused
    /// (the window itself), another terminal (the tab we just left, or its
    /// SwiftTerm find bar), or a list - the tab sidebar keeps the keyboard
    /// after a click that switched tabs. Already inside this terminal -
    /// including its find bar - is left alone, and so is anything else: the
    /// tab rename field, the sidebar search, palette fields.
    static func shouldTakeFocus(
        from responder: NSResponder?,
        in window: NSWindow,
        for terminal: NSView
    ) -> Bool {
        guard let responder, responder !== window else { return true }
        guard let view = responder as? NSView else { return false }
        if view.isDescendant(of: terminal) { return false }
        if view is NSTableView { return true }
        return isInsideTerminal(view)
    }

    private static func isInsideTerminal(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if candidate is SwiftTerm.TerminalView { return true }
            current = candidate.superview
        }
        return false
    }

    // MARK: - NSView

    override var isOpaque: Bool { true }

    override func layout() {
        super.layout()
        // A newer container may have adopted the view; never resize it then.
        guard let terminal, terminal.superview === self else { return }
        let inset = TerminalAppearance.padding
        let rect = NSRect(
            x: inset.left,
            y: inset.bottom,
            width: max(0, bounds.width - inset.left - inset.right),
            height: max(0, bounds.height - inset.top - inset.bottom)
        )
        if terminal.frame != rect {
            terminal.frame = rect
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let terminal, terminal.superview === self {
            window?.makeFirstResponder(terminal)
        }
    }
}
