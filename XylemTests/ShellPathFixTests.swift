//
//  ShellPathFixTests.swift
//  XylemTests
//
//  Doctor's "not on your PATH" fix must name the file the user's login
//  shell really reads, and the command must work when pasted. The last two
//  tests run the generated command in a real zsh / bash with a temporary
//  HOME and check that a new login shell then has the folder on PATH.
//

import Testing
import Foundation

struct ShellPathFixTests {
    private let home = "/Users/someone"
    private let folder = "/Users/someone/.local/bin"

    private func fix(_ shell: String, existing: Set<String> = [], zdotdir: String? = nil,
                     folder: String? = nil) -> ShellPathFix {
        ShellPathFix.make(folder: folder ?? self.folder, shell: shell, home: home, zdotdir: zdotdir,
                          fileExists: { existing.contains($0) })
    }

    @Test func zshWritesZshrc() {
        let f = fix("/bin/zsh")
        #expect(f.startupFile == "~/.zshrc")
        #expect(f.startupFilePath == "/Users/someone/.zshrc")
        #expect(f.command == #"echo 'export PATH="$HOME/.local/bin:$PATH"' >> "${ZDOTDIR:-$HOME}/.zshrc""#)
    }

    @Test func zshFollowsZdotdir() {
        let f = fix("/bin/zsh", zdotdir: "/Users/someone/.config/zsh")
        #expect(f.startupFile == "~/.config/zsh/.zshrc")
        #expect(f.startupFilePath == "/Users/someone/.config/zsh/.zshrc")
        #expect(fix("/bin/zsh", zdotdir: "").startupFile == "~/.zshrc")
    }

    @Test func bashUsesTheFirstFileLoginBashReads() {
        // None yet: .bash_profile.
        #expect(fix("/bin/bash").startupFile == "~/.bash_profile")
        // Only .profile: a new .bash_profile would stop .profile loading.
        #expect(fix("/bin/bash", existing: ["/Users/someone/.profile"]).startupFile == "~/.profile")
        #expect(fix("/bin/bash", existing: ["/Users/someone/.bash_login", "/Users/someone/.profile"]).startupFile == "~/.bash_login")
        let all: Set = ["/Users/someone/.bash_profile", "/Users/someone/.bash_login", "/Users/someone/.profile"]
        let f = fix("/opt/homebrew/bin/bash", existing: all)
        #expect(f.startupFile == "~/.bash_profile")
        #expect(f.command == #"echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bash_profile"#)
    }

    @Test func fishUsesFishAddPath() {
        let f = fix("/opt/homebrew/bin/fish")
        #expect(f.command == #"fish_add_path "$HOME/.local/bin""#)
        #expect(f.startupFilePath == nil)
    }

    @Test func cshFamilyUsesSetenv() {
        #expect(fix("/bin/tcsh").command == #"echo 'setenv PATH "$HOME/.local/bin:$PATH"' >> ~/.cshrc"#)
        #expect(fix("/bin/tcsh", existing: ["/Users/someone/.tcshrc"]).startupFile == "~/.tcshrc")
        #expect(fix("/bin/csh").startupFile == "~/.cshrc")
    }

    @Test func otherShellsUseProfile() {
        #expect(fix("/bin/ksh").startupFile == "~/.profile")
        #expect(fix("/bin/sh").command == #"echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.profile"#)
    }

    @Test func folderOutsideHomeStaysAbsolute() {
        #expect(fix("/bin/zsh", folder: "/opt/tools/bin").command
                == #"echo 'export PATH="/opt/tools/bin:$PATH"' >> "${ZDOTDIR:-$HOME}/.zshrc""#)
        // A sibling that only starts with the home path isn't inside it.
        #expect(ShellPathFix.homeRelative("/Users/someone2/bin", home: home) == "/Users/someone2/bin")
    }

    @Test func quotesInTheFolderAreEscaped() {
        let f = fix("/bin/zsh", folder: #"/Users/someone/it's "odd"/bin"#)
        #expect(f.command == #"echo 'export PATH="$HOME/it'\''s \"odd\"/bin:$PATH"' >> "${ZDOTDIR:-$HOME}/.zshrc""#)
    }

    @Test func detectsALineAlreadyInTheFile() {
        for line in [
            #"export PATH="$HOME/.local/bin:$PATH""#,
            #"export PATH="${HOME}/.local/bin:$PATH""#,
            "export PATH=~/.local/bin:$PATH",
            "# export PATH=/Users/someone/.local/bin:$PATH"
        ] {
            #expect(ShellPathFix.mentions(folder: folder, home: home, in: "alias ll='ls -l'\n\(line)\n"))
        }
        #expect(!ShellPathFix.mentions(folder: folder, home: home, in: "export PATH=/opt/homebrew/bin:$PATH\n"))
    }

    // MARK: - The command really works

    /// Pastes the command into `shell`, then asks a fresh login shell (like
    /// a tab) for its PATH - all inside a temporary HOME.
    private func pathAfterFix(shell: String, prepare: (URL) throws -> Void = { _ in }) throws -> (fix: ShellPathFix, path: String, home: URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: "shellpathfix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try prepare(home)
        let bin = home.appending(path: ".local/bin").path
        let fix = ShellPathFix.make(folder: bin, shell: shell, home: home.path,
                                    fileExists: { FileManager.default.fileExists(atPath: $0) })
        var env = ["HOME": home.path, "PATH": "/usr/bin:/bin", "TERM": "dumb"]
        _ = try run(shell, ["-c", fix.command], env: env)
        env["PATH"] = "/usr/bin:/bin"
        let out = try run(shell, ["-l", "-i", "-c", "printf '%s' \"$PATH\""], env: env)
        return (fix, out, home)
    }

    private func run(_ exe: String, _ args: [String], env: [String: String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test func zshCommandPutsTheFolderOnALoginShellsPath() throws {
        let r = try pathAfterFix(shell: "/bin/zsh")
        defer { try? FileManager.default.removeItem(at: r.home) }
        #expect(r.path.split(separator: ":").contains(Substring(r.home.path + "/.local/bin")))
        let written = try String(contentsOf: r.home.appending(path: ".zshrc"), encoding: .utf8)
        #expect(ShellPathFix.mentions(folder: r.home.path + "/.local/bin", home: r.home.path, in: written))
    }

    @Test func bashCommandKeepsAnExistingProfileLoading() throws {
        let r = try pathAfterFix(shell: "/bin/bash") { home in
            try "export XYLEM_PROFILE_MARK=1\nexport PATH=\"/opt/marker:$PATH\"\n"
                .write(to: home.appending(path: ".profile"), atomically: true, encoding: .utf8)
        }
        defer { try? FileManager.default.removeItem(at: r.home) }
        #expect(r.fix.startupFile == "~/.profile")
        let entries = r.path.split(separator: ":")
        #expect(entries.contains(Substring(r.home.path + "/.local/bin")))
        // The user's own .profile still loads.
        #expect(entries.contains("/opt/marker"))
        #expect(!FileManager.default.fileExists(atPath: r.home.appending(path: ".bash_profile").path))
    }
}
