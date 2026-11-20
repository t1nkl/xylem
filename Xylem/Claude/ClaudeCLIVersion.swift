//
//  ClaudeCLIVersion.swift
//  Xylem
//
//  The version of the claude the tabs run, asked from the binary itself
//  (`claude --version` prints "2.1.329 (Claude Code)") when Doctor finds it.
//  A tab's hook settings depend on it (ClaudeHookBridge.settingsPath): the
//  answer is kept in UserDefaults, so tabs restored at launch use the last
//  known version while the new answer is on its way; with none kept yet,
//  `bootstrap` reads it once before the restore. The status line input of a
//  running tab names its claude's version too and updates it: that is the
//  claude the tabs really run (a project's PATH may put another in front).
//

import Foundation

nonisolated enum ClaudeCLIVersion {
    static let defaultsKey = "claudeCLIVersion"
    /// Set once `bootstrap` has tried: a binary that never answers must not
    /// hold up every launch.
    static let bootstrappedKey = "claudeCLIVersionBootstrapped"

    /// The last version read from the binary; nil before the first answer.
    static var known: String? { known(in: .standard) }

    static func known(in defaults: UserDefaults) -> String? {
        defaults.string(forKey: defaultsKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A new answer replaces the kept one; a failed read (nil) keeps it,
    /// so one slow `--version` doesn't send new tabs back to the settings
    /// without StopFailure.
    static func remember(_ version: String?) { remember(version, in: .standard) }

    static func remember(_ version: String?, in defaults: UserDefaults) {
        guard let version, version != known(in: defaults) else { return }
        defaults.set(version, forKey: defaultsKey)
    }

    /// Dotted versions compared number by number ("2.1.76" < "2.1.257").
    static func isVersion(_ version: String, atLeast minimum: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = minimum.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    /// Runs `<executable> --version` (blocking, at most `timeout`) with
    /// `searchPath` as PATH: an npm install is a `#!/usr/bin/env node`
    /// script, and the app's own PATH has no node. nil when it fails or
    /// prints no version (a wrapper script, say).
    static func read(executable: String, searchPath: [String], timeout: TimeInterval = 5) -> String? {
        let path = (searchPath + systemPath).filter { !$0.isEmpty }.joined(separator: ":")
        guard let result = ProcessRunner.run("/usr/bin/env", ["PATH=" + path, executable, "--version"], timeout: timeout),
              result.exited, result.status == 0
        else { return nil }
        return parse(String(decoding: result.output.prefix(4096), as: UTF8.self))
    }

    private static let systemPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// Before the first launch's tabs are restored, while no version is
    /// known yet (the first launch with this feature): a restored tab builds
    /// its command at once, and would otherwise run without StopFailure
    /// until the next launch. Once ever, looks only where Doctor would
    /// without a login shell (an absolute Binary path, else the install
    /// folders), at most `timeout` (a native `claude --version` takes
    /// ~10 ms); Doctor and the tabs' status lines keep it current after.
    static func bootstrap(configured: String, timeout: TimeInterval = 1) {
        let defaults = UserDefaults.standard
        guard known == nil, !defaults.bool(forKey: bootstrappedKey) else { return }
        defaults.set(true, forKey: bootstrappedKey)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders = ClaudeBinaryLocator.knownDirectories(home: home)
        guard case .found(let executable)? = ClaudeBinaryLocator.resolve(
            configured: configured, home: home, shellPath: nil,
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
        ) else { return }
        remember(read(executable: executable, searchPath: folders, timeout: timeout))
    }

    /// "2.1.329 (Claude Code)" → "2.1.329"; the first line only.
    static func parse(_ output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).first,
              let word = line.split(whereSeparator: \.isWhitespace).first,
              word.wholeMatch(of: /\d+\.\d+\.\d+/) != nil
        else { return nil }
        return String(word)
    }
}
