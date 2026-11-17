//
//  TerminalProcessCoordinator.swift
//  Xylem
//
//  Owns the SwiftTerm process delegate responsibilities.
//  Kept separate so the NSViewRepresentable stays declarative and thin.
//

import Foundation
import SwiftTerm

final class TerminalProcessCoordinator: NSObject, LocalProcessTerminalViewDelegate {
    var onExit: ((Int32?) -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onDirectoryChange: ((String?) -> Void)?
    /// Told about size changes: the program's redraw is not Claude working.
    var activityMonitor: TerminalActivityMonitor?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        activityMonitor?.noteResize()
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        onTitleChange?(title)
    }

    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {
        onDirectoryChange?(directory)
    }

    func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
        onExit?(exitCode)
    }
}
