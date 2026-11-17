//
//  LoginShellEnvironment.swift
//  Xylem
//
//  What a tab's shell knows that Xylem doesn't. A GUI app gets launchd's
//  environment; the tabs run an interactive login shell, whose rc files
//  (`.zshrc`, `config.fish`) add PATH entries (nvm, volta, mise) and may set
//  CLAUDE_CONFIG_DIR. One such shell, run off the main actor with a
//  timeout, prints both: the Doctor finds the claude the tabs will run
//  (ClaudeBinaryLocator) and Xylem reads the config folder their claude
//  writes to (ClaudeConfigDirectory).
//
//  An rc file can do anything (attach tmux, prompt, start an agent): output
//  goes to a temp file rather than a pipe (an agent inheriting the pipe
//  would keep it open forever), stdin is /dev/null, TERM is dumb, and the
//  shell is killed after the timeout.
//

import Foundation

nonisolated enum LoginShellEnvironment {
    struct Snapshot: Equatable, Sendable {
        /// PATH entries in order; nil when the shell printed none.
        let path: [String]?
        /// CLAUDE_CONFIG_DIR as the shell has it; nil when unset or empty.
        let claudeConfigDirectory: String?
    }

    static let pathMarker = "__XYLEM_PATH__"
    static let configMarker = "__XYLEM_CLAUDE_CONFIG_DIR__"

    /// The command for `shell -l -i -c`. fish has no `${VAR-}`; POSIX
    /// shells get it so a `set -u` in an rc file can't abort on an unset
    /// variable.
    static func probeCommand(forShell shell: String) -> String {
        let config = (shell as NSString).lastPathComponent == "fish" ? "$CLAUDE_CONFIG_DIR" : "${CLAUDE_CONFIG_DIR-}"
        return "printf '\\n\(pathMarker)%s\\n\(configMarker)%s\\n' \"$PATH\" \"\(config)\""
    }

    /// Pure: everything the shell wrote → the two values. Only the last
    /// marked lines count; whatever the rc files print is ignored.
    static func parse(_ output: String) -> Snapshot? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let pathLine = lines.last(where: { $0.hasPrefix(pathMarker) }) else { return nil }
        let entries = pathLine.dropFirst(pathMarker.count).split(separator: ":").map(String.init).filter { !$0.isEmpty }
        let config = lines.last(where: { $0.hasPrefix(configMarker) })
            .map { String($0.dropFirst(configMarker.count)) }
            .flatMap { $0.isEmpty ? nil : $0 }
        return Snapshot(path: entries.isEmpty ? nil : entries, claudeConfigDirectory: config)
    }

    private static let queue = DispatchQueue(label: "xylem.login-shell", qos: .utility)

    /// Runs the probe on a GCD thread (the wait blocks; not on the
    /// cooperative pool). nil when the shell failed or timed out.
    static func read(timeout: TimeInterval = 5) async -> Snapshot? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: readBlocking(timeout: timeout)) }
        }
    }

    /// Blocking variant for the one launch that has no saved answer yet.
    static func readBlocking(timeout: TimeInterval) -> Snapshot? {
        let environment = ProcessInfo.processInfo.environment
        let shell = ShellConfiguration.userShell(environment: environment)
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "xylem-shell-env-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let output = try? FileHandle(forWritingTo: outputURL)
        else { return nil }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", probeCommand(forShell: shell)]
        // Like a tab's shell (minus a parent Claude Code session's markers),
        // but a dumb terminal so rc files skip prompts and colour.
        var env = ShellConfiguration.removingParentClaudeSession(from: environment)
        env["TERM"] = "dumb"
        process.environment = env
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            // Interactive zsh ignores SIGTERM; SIGKILL if it's still there.
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            return nil
        }
        guard let data = try? Data(contentsOf: outputURL) else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }
}
