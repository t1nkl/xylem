//
//  NewTabPickerLayoutTests.swift
//  XylemTests
//
//  The New Tab screen gets narrower when the right panel opens or the
//  window shrinks. The Recent Projects grid must follow, not keep the width
//  of its current columns and leave cards under the panel.
//

import Testing
import AppKit
import SwiftUI

@MainActor
struct NewTabPickerLayoutTests {

    @MainActor @Observable final class Probe {
        var panelWidth: CGFloat = 0
        var pickerWidth: CGFloat = 0
    }

    /// The window's layout in small: the picker, then a right panel that
    /// opens to a fixed width.
    struct Harness: View {
        let probe: Probe
        let projects: [ClaudeProject]

        var body: some View {
            HStack(spacing: 0) {
                NewTabPickerView(recentProjects: projects)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { probe.pickerWidth = $0 }
                Color.gray.frame(width: probe.panelWidth)
            }
        }
    }

    private static let projects: [ClaudeProject] = (0..<20).map { i in
        ClaudeProject(id: "p\(i)", path: "/Users/dev/code/project-\(i)", displayName: "project-\(i)",
                      sessionCount: 1, lastModified: Date(timeIntervalSince1970: 1_800_000_000 - Double(i) * 60))
    }

    /// The picker's scroll view (SwiftUI's ScrollView is an NSScrollView on
    /// macOS): the overflow was inside the picker, its own frame was right.
    private func scrollWidth(in view: NSView) -> CGFloat? {
        if let scroll = view as? NSScrollView { return scroll.frame.width }
        for sub in view.subviews { if let w = scrollWidth(in: sub) { return w } }
        return nil
    }

    private func settle(_ view: NSView) {
        for _ in 0..<8 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    @Test func theGridMakesRoomForTheRightPanel() {
        let probe = Probe()
        let host = NSHostingView(rootView: Harness(probe: probe, projects: Self.projects))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1150, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // Panel hidden: four columns of 220 pt cards.
        settle(host)
        #expect(probe.pickerWidth > 1100)
        #expect((scrollWidth(in: host) ?? 0) > 1100)

        probe.panelWidth = 300
        settle(host)
        // Panel shown: the picker takes what is left and drops a column.
        #expect(probe.pickerWidth <= 850)
        #expect((scrollWidth(in: host) ?? .infinity) <= 850)
        window.close()
    }
}
