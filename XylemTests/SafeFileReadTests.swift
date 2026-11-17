//
//  SafeFileReadTests.swift
//  XylemTests
//
//  Files a project folder controls are read only when they are regular
//  files of a sane size: a FIFO or a link to /dev/zero under the name of a
//  settings file must answer nil at once, never block or read forever.
//

import Testing
import Foundation

struct SafeFileReadTests {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xylem-safe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func regularFilesAndLinksToThemAreRead() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.json")
        try #"{"a":1}"#.write(to: file, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(SafeFileRead.string(file) == #"{"a":1}"#)
        #expect(SafeFileRead.string(link) == #"{"a":1}"#)
        #expect(SafeFileRead.handle(link) != nil)
    }

    @Test func specialFilesAreRefusedAtOnce() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("settings.json").path
        #expect(mkfifo(fifo, 0o600) == 0)
        let zero = dir.appendingPathComponent(".mcp.json")
        try FileManager.default.createSymbolicLink(atPath: zero.path, withDestinationPath: "/dev/zero")
        #expect(SafeFileRead.data(URL(fileURLWithPath: fifo)) == nil)
        #expect(SafeFileRead.handle(URL(fileURLWithPath: fifo)) == nil)
        #expect(SafeFileRead.data(zero) == nil)
        #expect(SafeFileRead.handle(zero) == nil)
        #expect(SafeFileRead.data(dir) == nil)
        #expect(SafeFileRead.data(dir.appendingPathComponent("missing")) == nil)
    }

    @Test func oversizedFilesAreRefused() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("big")
        try Data(count: 2048).write(to: file)
        #expect(SafeFileRead.data(file, limit: 1024) == nil)
        #expect(SafeFileRead.data(file, limit: 4096)?.count == 2048)
    }

    /// Settings under a FIFO name: the reader answers nil, it doesn't hang.
    @Test func settingsReaderSkipsAFIFO() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        #expect(mkfifo(dir.appendingPathComponent(".claude/settings.json").path, 0o600) == 0)
        let settings = ClaudeSettingsReader().readProjectSettings(at: dir.path)
        #expect(settings.shared == nil)
    }
}
