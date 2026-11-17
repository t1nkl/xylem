//
//  TerminalFocusTests.swift
//  XylemTests
//
//  When a terminal that just became active may take the keyboard. The tab
//  sidebar (a List, i.e. an NSTableView) keeps first responder after a click
//  that switched tabs, so it must not block the hand-off; text fields
//  (search, rename, palette) must.
//

import Testing
import AppKit

@MainActor
struct TerminalFocusTests {

    private func fixture() -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let terminal = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView?.addSubview(terminal)
        return (window, terminal)
    }

    @Test func takesFocusFromNothingOrTheTabList() {
        let (window, terminal) = fixture()
        let list = NSOutlineView(frame: .zero)
        window.contentView?.addSubview(list)
        #expect(TerminalContainerView.shouldTakeFocus(from: nil, in: window, for: terminal))
        #expect(TerminalContainerView.shouldTakeFocus(from: window, in: window, for: terminal))
        #expect(TerminalContainerView.shouldTakeFocus(from: list, in: window, for: terminal))
    }

    @Test func leavesTextFieldsAndItselfAlone() {
        let (window, terminal) = fixture()
        let field = NSTextField(frame: .zero)
        window.contentView?.addSubview(field)
        let inside = NSView(frame: .zero)
        terminal.addSubview(inside)
        #expect(!TerminalContainerView.shouldTakeFocus(from: field, in: window, for: terminal))
        #expect(!TerminalContainerView.shouldTakeFocus(from: NSTextView(), in: window, for: terminal))
        #expect(!TerminalContainerView.shouldTakeFocus(from: inside, in: window, for: terminal))
    }
}

/// A restarted tab puts a new terminal into the same container: a
/// background tab must hide it (a visible one at opacity 0 drew every frame).
@MainActor
struct TerminalContainerAdoptTests {
    @Test func aReplacedTerminalInABackgroundTabIsHidden() {
        let first = NSView(), second = NSView()
        let container = TerminalContainerView(terminal: first)
        container.setActive(false)
        #expect(first.isHidden)
        container.adopt(second)
        container.setActive(false)
        #expect(second.isHidden)
        #expect(second.superview === container)
        #expect(first.superview == nil)
    }
}
