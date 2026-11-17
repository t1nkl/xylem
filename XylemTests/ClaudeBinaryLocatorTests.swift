//
//  ClaudeBinaryLocatorTests.swift
//  XylemTests
//
//  The Doctor must find the claude the tabs will run: the Binary path
//  setting (a name or a path), looked up on the login shell's PATH like a
//  tab does, with the install folders only explaining an off-PATH install.
//  File checks are injected; one test checks the real disk.
//

import Testing
import Foundation

struct ClaudeBinaryLocatorTests {
    private let home = "/Users/someone"

    private typealias Location = ClaudeBinaryLocator.Location

    private func resolve(_ configured: String, existing: Set<String>, shellPath: [String]? = ["/usr/bin", "/bin"]) -> Location? {
        ClaudeBinaryLocator.resolve(configured: configured, home: home, shellPath: shellPath) { existing.contains($0) }
    }

    @Test func bareNameIsFoundOnTheShellPath() {
        // nvm: only the shell knows this folder.
        let nvm = "/Users/someone/.nvm/versions/node/v22.1.0/bin"
        #expect(resolve("claude", existing: [nvm + "/claude"], shellPath: [nvm, "/usr/bin"]) == .found(nvm + "/claude"))
    }

    @Test func shellPathWinsOverInstallFolders() {
        let found = resolve("claude",
                            existing: ["/Users/someone/.local/bin/claude", "/opt/homebrew/bin/claude"],
                            shellPath: ["/opt/homebrew/bin", "/usr/bin"])
        #expect(found == .found("/opt/homebrew/bin/claude"))
    }

    @Test func installFolderOffThePathIsNotFound() {
        // Anthropic's installer without ~/.local/bin on PATH: the tab says
        // "command not found", so the Doctor must not say "found".
        #expect(resolve("claude", existing: ["/Users/someone/.local/bin/claude"]) == .offPath("/Users/someone/.local/bin/claude"))
    }

    @Test func withoutTheShellInstallFoldersAreTrusted() {
        #expect(resolve("claude", existing: ["/Users/someone/.volta/bin/claude"], shellPath: nil) == .found("/Users/someone/.volta/bin/claude"))
        #expect(resolve("claude", existing: [], shellPath: nil) == nil)
    }

    @Test func customNameIsLookedUpNotClaude() {
        // The setting names another binary: finding plain claude would
        // report a binary the tabs never run.
        #expect(resolve("claude-beta", existing: ["/usr/bin/claude"]) == nil)
        #expect(resolve("claude-beta", existing: ["/usr/bin/claude-beta"]) == .found("/usr/bin/claude-beta"))
    }

    @Test func absolutePathIsCheckedAsIs() {
        #expect(resolve("/opt/tools/claude", existing: ["/opt/tools/claude"]) == .found("/opt/tools/claude"))
        // A wrong path is missing even when claude is on PATH.
        #expect(resolve("/opt/tools/claude", existing: ["/usr/bin/claude"]) == nil)
    }

    @Test func tildePathIsExpanded() {
        #expect(resolve("~/bin/claude", existing: ["/Users/someone/bin/claude"]) == .found("/Users/someone/bin/claude"))
    }

    @Test func pathEntriesAreSearchedInOrder() {
        let found = ClaudeBinaryLocator.firstExecutable(
            named: "claude",
            in: ["/a", "/b/", "/c"],
            isExecutable: { $0 == "/b/claude" || $0 == "/c/claude" }
        )
        #expect(found == "/b/claude")
    }

    @Test func realLookupChecksTheDisk() {
        #expect(ClaudeBinaryLocator.locate(configured: "/bin/sh", shellPath: nil) == .found("/bin/sh"))
        #expect(ClaudeBinaryLocator.locate(configured: "/nonexistent/xylem-claude", shellPath: nil) == nil)
        #expect(ClaudeBinaryLocator.locate(configured: "sh", shellPath: ["/nonexistent", "/bin"]) == .found("/bin/sh"))
    }
}

/// The login shell probe: PATH and CLAUDE_CONFIG_DIR out of whatever the
/// rc files print, and a command every shell can run.
struct LoginShellEnvironmentTests {
    private typealias Env = LoginShellEnvironment

    @Test func valuesAreTakenFromNoisyOutput() {
        let output = """
        Welcome back!
        __XYLEM_PATH__ is a nice name
        [oh-my-zsh] update available

        __XYLEM_PATH__/Users/someone/.nvm/versions/node/v22.1.0/bin:/usr/bin::/bin
        __XYLEM_CLAUDE_CONFIG_DIR__/Users/someone/.claude-work

        """
        let snapshot = Env.parse(output)
        #expect(snapshot?.path == ["/Users/someone/.nvm/versions/node/v22.1.0/bin", "/usr/bin", "/bin"])
        #expect(snapshot?.claudeConfigDirectory == "/Users/someone/.claude-work")
    }

    @Test func unsetConfigFolderIsNil() {
        let snapshot = Env.parse("\n__XYLEM_PATH__/usr/bin\n__XYLEM_CLAUDE_CONFIG_DIR__\n")
        #expect(snapshot?.path == ["/usr/bin"])
        #expect(snapshot?.claudeConfigDirectory == nil)
    }

    @Test func noMarkerMeansNoAnswer() {
        #expect(Env.parse("zsh: command not found: printf\n") == nil)
        #expect(Env.parse("__XYLEM_PATH__\n")?.path == nil)
    }

    @Test func fishGetsItsOwnVariableSyntax() {
        #expect(Env.probeCommand(forShell: "/bin/zsh").contains("${CLAUDE_CONFIG_DIR-}"))
        #expect(!Env.probeCommand(forShell: "/opt/homebrew/bin/fish").contains("${"))
    }

    @Test func realShellAnswers() async throws {
        // The process's own shell, as a tab would run it.
        let snapshot = try #require(await Env.read(timeout: 10))
        #expect(snapshot.path?.contains("/usr/bin") == true)
    }
}

/// Where Claude Code's user files are, with and without CLAUDE_CONFIG_DIR.
struct ClaudeConfigDirectoryTests {
    private let home = URL(fileURLWithPath: "/Users/someone")

    @Test func defaultIsDotClaudeAndHomeConfigFile() {
        let paths = ClaudeConfigDirectory.makePaths(custom: nil, home: home)
        #expect(paths.root.path == "/Users/someone/.claude")
        #expect(paths.projects.path == "/Users/someone/.claude/projects")
        #expect(paths.globalConfigFile.path == "/Users/someone/.claude.json")
        #expect(ClaudeConfigDirectory.makePaths(custom: "  ", home: home) == paths)
    }

    @Test func customFolderHoldsEverythingIncludingTheConfigFile() {
        let paths = ClaudeConfigDirectory.makePaths(custom: "/Volumes/work/claude", home: home)
        #expect(paths.root.path == "/Volumes/work/claude")
        #expect(paths.projects.path == "/Volumes/work/claude/projects")
        #expect(paths.globalConfigFile.path == "/Volumes/work/claude/.claude.json")
    }

    @Test func tildeAndRelativeValuesAreUnderHome() {
        #expect(ClaudeConfigDirectory.makePaths(custom: "~/.claude-work", home: home).root.path == "/Users/someone/.claude-work")
        #expect(ClaudeConfigDirectory.makePaths(custom: ".claude-work", home: home).root.path == "/Users/someone/.claude-work")
    }

    @Test func symlinkedFolderIsResolved() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "xylem-ccd-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appending(path: "real")
        try FileManager.default.createDirectory(at: real.appending(path: "projects"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: base.appending(path: "link"), withDestinationURL: real)
        let paths = ClaudeConfigDirectory.makePaths(custom: base.appending(path: "link").path, home: home)
        #expect(paths.projects.path == real.appending(path: "projects").path)
    }
}
