//
//  ProjectDrawerTests.swift
//  XylemTests
//
//  The Files / Changes drawer: git status + numstat parsing, the unified
//  diff parser, the directory listing and the file preview. Sample names
//  only.
//

import Testing
import Foundation
import AppKit
import SwiftUI

struct ProjectFilesTests {

    @Test func listingPutsFoldersFirstInFinderOrderAndHidesGit() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "xylem-files-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for dir in ["src", ".git", ".github", "lib"] {
            try FileManager.default.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
        }
        for file in ["file10.txt", "file2.txt", ".DS_Store", ".env.example"] {
            try Data().write(to: root.appending(path: file))
        }
        let names = ProjectDirectoryReader.list(root.path).entries.map(\.name)
        #expect(names == [".github", "lib", "src", ".env.example", "file2.txt", "file10.txt"])
    }

    @Test func previewTextBinaryAndLimits() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "xylem-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = dir.appending(path: "a.txt"); try "first\r\nsecond\n".write(to: text, atomically: true, encoding: .utf8)
        #expect(FilePreview.Loader.load(text.path) == .text(lines: ["first", "second"], truncated: false))
        let binary = dir.appending(path: "b.bin"); try Data([0x50, 0x00, 0x01]).write(to: binary)
        #expect(FilePreview.Loader.load(binary.path) == .binary)
        let big = dir.appending(path: "big.txt"); try Data(repeating: 0x61, count: FilePreview.Loader.maxBytes + 10).write(to: big)
        if case .text(_, let truncated) = FilePreview.Loader.load(big.path) { #expect(truncated) } else { Issue.record("expected text") }
        #expect(FilePreview.Loader.load(dir.appending(path: "missing").path) == .unreadable)
    }
}

@MainActor
struct ProjectDrawerModelTests {

    @Test func treeRowsFollowExpandedFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "xylem-tree-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "src/api"), withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: "src/api/handler.ts"))
        try Data().write(to: root.appending(path: "README.md"))

        let model = ProjectDrawerModel()
        model.open(.files, directory: root.path)
        // It slides in once the first load is done (or after 150 ms).
        for _ in 0..<100 where model.mode == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.mode == .files)
        await model.refreshOnce()
        #expect(model.visibleRows.map(\.entry.name) == ["src", "README.md"])
        model.toggleFolder(root.appending(path: "src").path)
        await model.refreshOnce()
        #expect(model.visibleRows.map(\.entry.name) == ["src", "api", "README.md"])
        #expect(model.visibleRows.map(\.depth) == [0, 1, 0])
        model.toggleFolder(root.appending(path: "src").path)
        #expect(model.visibleRows.map(\.entry.name) == ["src", "README.md"])
        // A rail click on the open mode closes it; another tab's folder resets the tree.
        model.toggle(.files, directory: root.path)
        #expect(model.mode == nil)
        model.setDirectory("/nonexistent-\(UUID().uuidString)")
        #expect(model.visibleRows.isEmpty)
        model.close()
    }
}

struct TerminalDropTests {
    @Test func droppedPathsAreQuotedAndSpaced() {
        #expect(XylemTerminalView.pathInsertion(["/tmp/a b.txt", "/tmp/it's.ts"]) == "'/tmp/a b.txt' '/tmp/it'\\''s.ts' ")
        // The File / Image buttons: the same quoting, no trailing space (as before).
        #expect(XylemTerminalView.pathInsertion(["/x/shot.png"], trailingSpace: false) == "'/x/shot.png'")
        #expect(XylemTerminalView.pathInsertion([]) == nil)
    }

    /// A file name with control characters would act as keys in the raw-mode
    /// terminal (Ctrl-U wipes the line, Return runs it): nothing is typed.
    @Test func pathsWithControlCharactersAreRefused() {
        #expect(XylemTerminalView.pathInsertion(["/tmp/x\u{15}rm -rf ~\r"]) == nil)
        #expect(XylemTerminalView.pathInsertion(["/ok.txt", "/tmp/\u{1B}[201~evil"]) == nil)
        #expect(XylemTerminalView.pathInsertion(["/tmp/c1\u{9B}x"]) == nil)
        #expect(XylemTerminalView.pathInsertion(["/tmp/\u{0444}\u{0430}\u{0439}\u{043B}.md"]) != nil)
    }
}

@MainActor
struct DrawerSymlinkTests {
    /// The tab's folder spelled through a symlink (/tmp/... vs git's
    /// /private/tmp/...): the tree still gets its change colours.
    @Test func changeKindsUseTheTreesSpelling() async throws {
        let real = FileManager.default.temporaryDirectory.appending(path: "xylem-real-\(UUID().uuidString)").resolvingSymlinksInPath()
        let link = FileManager.default.temporaryDirectory.appending(path: "xylem-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: real); try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["init", "-q"]
        p.currentDirectoryURL = real; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        try Data("x".utf8).write(to: real.appending(path: "new.txt"))

        let model = ProjectDrawerModel()
        model.open(.files, directory: link.path)
        for _ in 0..<200 where model.mode == nil || model.changes == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.changeKinds[link.appending(path: "new.txt").path] == .untracked)
        model.close()
    }
}

/// The terminal's real AppKit drop path, with a drag that carries file URLs
/// (no mouse needed): a normal file is accepted, a name with a control
/// character is refused.
@MainActor
struct TerminalDropPathTests {
    private final class FakeDrag: NSObject, NSDraggingInfo {
        let pasteboard: NSPasteboard
        init(urls: [URL]) {
            pasteboard = NSPasteboard(name: NSPasteboard.Name("xylem-test-\(UUID().uuidString)"))
            pasteboard.clearContents()
            pasteboard.writeObjects(urls as [NSURL])
        }
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggingLocation: NSPoint { .zero }
        var draggedImageLocation: NSPoint { .zero }
        var draggedImage: NSImage? { nil }
        var draggingPasteboard: NSPasteboard { pasteboard }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination: Bool = false
        var numberOfValidItemsForDrop: Int = 1
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                    classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    @Test func dropAcceptsFilesAndRefusesControlCharacters() {
        let view = XylemTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let ok = FakeDrag(urls: [URL(fileURLWithPath: "/tmp/notes file.md")])
        #expect(view.draggingEntered(ok) == .copy)
        #expect(view.performDragOperation(ok))
        let evil = FakeDrag(urls: [URL(fileURLWithPath: "/tmp/x\u{15}rm -rf ~\r")])
        #expect(!view.performDragOperation(evil))
        let none = FakeDrag(urls: [])
        #expect(view.draggingEntered(none) == [])
        ok.pasteboard.releaseGlobally(); evil.pasteboard.releaseGlobally(); none.pasteboard.releaseGlobally()
    }
}

@MainActor
struct DrawerFollowsTheTabTests {
    /// A new tab (no project yet) closes the drawer; another project keeps it
    /// open on that project.
    @Test func newTabClosesTheDrawerOtherProjectsKeepIt() async throws {
        let a = FileManager.default.temporaryDirectory.appending(path: "xylem-follow-a-\(UUID().uuidString)")
        let b = FileManager.default.temporaryDirectory.appending(path: "xylem-follow-b-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        for dir in [a, b] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

        let model = ProjectDrawerModel()
        model.open(.files, directory: a.path)
        for _ in 0..<100 where model.mode == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.mode == .files)
        model.setDirectory(b.path)
        #expect(model.mode == .files && model.directory == b.path)
        model.setDirectory(nil)
        #expect(model.mode == nil)
        // Opening it on a tab without a project still works (it explains why it's empty).
        model.open(.changes, directory: nil)
        for _ in 0..<100 where model.mode == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.mode == .changes)
        model.close()
    }
}

@MainActor
struct RightPanelLayoutTests {
    /// The panel never squeezes the terminal below 420 pt, and never goes
    /// under its own minimum.
    @Test func panelWidthLeavesRoomForTheTerminal() {
        let rail = AppTheme.Metrics.panelRailWidth
        #expect(RightPanelContainer<EmptyView>.maxWidth(detailWidth: 2000) == AppTheme.Metrics.inspectorMaxWidth)
        #expect(RightPanelContainer<EmptyView>.maxWidth(detailWidth: 420 + rail + 300) == 300)
        #expect(RightPanelContainer<EmptyView>.maxWidth(detailWidth: 500) == AppTheme.Metrics.inspectorMinWidth)
    }
}

@MainActor
struct DrawerColouringTests {
    /// The whole path the drawer takes: a real repository, the model loads a
    /// diff and a preview, and both get colours from the bundled engine.
    @Test func modelColoursTheDiffAndThePreview() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "xylem-colour-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func git(_ args: String...) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + args
            p.currentDirectoryURL = root
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
        }
        let file = root.appending(path: "Invoice.php")
        try "<?php\nclass Invoice {\n    public function total() { return 1; }\n}\n".write(to: file, atomically: true, encoding: .utf8)
        try git("init", "-q"); try git("add", "."); try git("commit", "-q", "-m", "init")
        try "<?php\nclass Invoice {\n    public function total() { return 2; }\n}\n".write(to: file, atomically: true, encoding: .utf8)

        let model = ProjectDrawerModel()
        model.open(.changes, directory: root.path)
        for _ in 0..<200 where model.changes == nil { try await Task.sleep(for: .milliseconds(10)) }
        let change = try #require(model.changes?.changes.first)
        model.selectChange(change)
        for _ in 0..<300 where model.diffColours == nil { try await Task.sleep(for: .milliseconds(10)) }
        let diff = try #require(model.diff)
        let added = try #require(diff.lines.first { $0.kind == .added })
        #expect(model.diffColours?[added.id]?.contains { $0.text == "function" && $0.scope == .keyword } == true)

        model.open(.files, directory: root.path)
        model.selectFile(file.path)
        for _ in 0..<300 where model.previewColours == nil { try await Task.sleep(for: .milliseconds(10)) }
        let colours = try #require(model.previewColours)
        #expect(colours[1].contains { $0.text == "class" && $0.scope == .keyword })
        model.close()
    }

    // MARK: - Special files never block the preview

    @Test func previewRefusesAFIFOWithoutBlocking() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xylem-fifo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("pipe").path
        #expect(mkfifo(fifo, 0o600) == 0)
        // Opening a FIFO with no writer blocks forever; the guard must answer at once.
        #expect(FilePreview.Loader.load(fifo) == .unreadable)
    }

    @Test func previewReadsSymlinksToFilesButNotDevices() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xylem-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try "hello\n".write(to: file, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(FilePreview.Loader.load(link.path) == .text(lines: ["hello"], truncated: false))
        #expect(FilePreview.Loader.load("/dev/null") == .unreadable)
    }

    @Test func refreshPauseGrowsWithASlowPass() {
        #expect(ProjectDrawerModel.pause(after: .milliseconds(200)) == .seconds(3))
        #expect(ProjectDrawerModel.pause(after: .seconds(1.5)) == .seconds(3))
        #expect(ProjectDrawerModel.pause(after: .seconds(10)) == .seconds(20))
    }
}
