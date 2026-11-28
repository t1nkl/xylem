//
//  ClaudeAgentsListing.swift
//  Xylem
//
//  Claude Code's own list of the sessions open on this Mac: `claude agents
//  --json` prints every live interactive and background session with its
//  pid and current `sessionId`, also one opened from the `/resume` picker,
//  whose id is on no command line (checked on 2.1.332: ~0.17 s, writes
//  nothing). OpenSessionDetector asks it next to `ps`; a claude without the
//  command (older versions) or one that doesn't answer in time simply adds
//  nothing.
//
//  Which claude to run is Doctor's answer (`ClaudeExecutable`): until Doctor
//  has one (the first second of a launch), the Binary path or the install
//  folders, as the version bootstrap does.
//

import Foundation
import Synchronization

nonisolated enum ClaudeAgentsListing {
    struct Entry: Equatable, Sendable {
        let pid: Int32
        let sessionID: String
    }

    /// The listing, or nil when claude can't be run or doesn't answer. A
    /// restored tab waits for it: a claude macOS is still checking after an
    /// update (~4.6 s once) is given up on rather than waited for.
    static func read(timeout: TimeInterval = 2) -> [Entry]? {
        guard let claude = ClaudeExecutable.current() else { return nil }
        let arguments = environmentArguments(claude: claude, configDirectory: ClaudeConfigDirectory.current.custom)
            + [claude.path, "agents", "--json"]
        guard let result = ProcessRunner.run("/usr/bin/env", arguments, timeout: timeout),
              result.exited, result.status == 0 else { return nil }
        return parse(result.output)
    }

    /// `env` arguments: the claude's PATH, the config folder the tabs'
    /// claude uses (its sessions are listed there), and none of a parent
    /// Claude Code session's markers (Xylem launched from a terminal
    /// running Claude Code), as the tabs get them.
    static func environmentArguments(claude: ClaudeExecutable.Location, configDirectory: String?) -> [String] {
        let path = (claude.searchPath + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).filter { !$0.isEmpty }
        var arguments = ShellConfiguration.parentClaudeSessionKeys.sorted().flatMap { ["-u", $0] }
        if let configDirectory {
            arguments.append("CLAUDE_CONFIG_DIR=" + configDirectory)
        } else {
            arguments += ["-u", "CLAUDE_CONFIG_DIR"]
        }
        arguments.append("PATH=" + path.joined(separator: ":"))
        return arguments
    }

    /// Pure: the JSON array → its entries with a pid and a session id.
    static func parse(_ data: Data) -> [Entry]? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return nil }
        return list.compactMap { item in
            guard let object = item as? [String: Any],
                  let pid = (object["pid"] as? NSNumber)?.int32Value, pid > 0,
                  let id = object["sessionId"] as? String, !id.isEmpty
            else { return nil }
            return Entry(pid: pid, sessionID: id)
        }
    }
}

/// The claude the tabs run, as Doctor last found it, for tools that run it
/// on their own (`claude agents --json`).
nonisolated enum ClaudeExecutable {
    struct Location: Equatable, Sendable {
        let path: String
        /// PATH it runs with: an npm install is `#!/usr/bin/env node`.
        let searchPath: [String]
    }

    private static let found = Mutex<Location?>(nil)

    static func remember(_ location: Location) {
        found.withLock { $0 = location }
    }

    /// At launch, before Doctor has asked the login shell: a claude at the
    /// Binary path or in the install folders (a few `stat`s), so a restored
    /// tab's check can run it. Doctor's answer replaces it.
    static func seed(configured: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard case .found(let path)? = ClaudeBinaryLocator.resolve(
            configured: configured, home: home, shellPath: nil,
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
        ) else { return }
        let location = Location(path: path, searchPath: ClaudeBinaryLocator.knownDirectories(home: home))
        found.withLock { if $0 == nil { $0 = location } }
    }

    /// Doctor found no claude at all: nothing to run.
    static func forget() {
        found.withLock { $0 = nil }
    }

    static func current() -> Location? {
        found.withLock { $0 }
    }
}
