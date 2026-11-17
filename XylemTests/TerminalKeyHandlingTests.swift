//
//  TerminalKeyHandlingTests.swift
//  XylemTests
//
//  Key rewrites Xylem applies before SwiftTerm sees an event: Shift+Return
//  detection, Option-composed letters on non-Latin layouts, and Control
//  shortcuts re-labelled with the physical US key on non-Latin layouts.
//  The last suite runs the rewritten Control key through SwiftTerm itself and
//  checks the bytes Claude Code receives in both keyboard modes.
//

import Testing
import AppKit
import Carbon.HIToolbox
import SwiftTerm

@MainActor
struct TerminalKeyHandlingTests {

    private func key(
        _ characters: String,
        ignoringModifiers: String,
        keyCode: Int,
        flags: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: ignoringModifiers,
            isARepeat: false,
            keyCode: UInt16(keyCode)
        )!
    }

    // MARK: Shift+Return

    @Test func shiftReturnIsRecognised() {
        #expect(XylemTerminalView.isShiftReturn(key("\r", ignoringModifiers: "\r", keyCode: kVK_Return, flags: .shift)))
    }

    @Test func plainOrOtherModifiedReturnIsNotShiftReturn() {
        #expect(!XylemTerminalView.isShiftReturn(key("\r", ignoringModifiers: "\r", keyCode: kVK_Return)))
        #expect(!XylemTerminalView.isShiftReturn(key("\r", ignoringModifiers: "\r", keyCode: kVK_Return, flags: [.shift, .command])))
        #expect(!XylemTerminalView.isShiftReturn(key("\r", ignoringModifiers: "\r", keyCode: kVK_ANSI_KeypadEnter, flags: .shift)))
    }

    @Test func capsLockDoesNotBreakShiftReturn() {
        #expect(XylemTerminalView.isShiftReturn(key("\r", ignoringModifiers: "\r", keyCode: kVK_Return, flags: [.shift, .capsLock])))
    }

    // MARK: Option letters

    @Test func optionLetterOnCyrillicLayoutIsTypedAsText() {
        // Ukrainian-QWERTY: Option+г composes ґ.
        let event = key("ґ", ignoringModifiers: "г", keyCode: kVK_ANSI_U, flags: .option)
        #expect(XylemTerminalView.optionComposedText(for: event, optionAsMeta: true) == "ґ")
    }

    @Test func optionOnLatinLayoutStaysMeta() {
        let event = key("ƒ", ignoringModifiers: "f", keyCode: kVK_ANSI_F, flags: .option)
        #expect(XylemTerminalView.optionComposedText(for: event, optionAsMeta: true) == nil)
    }

    @Test func optionRewriteIsOffWhenOptionIsNotMeta() {
        let event = key("ґ", ignoringModifiers: "г", keyCode: kVK_ANSI_U, flags: .option)
        #expect(XylemTerminalView.optionComposedText(for: event, optionAsMeta: false) == nil)
    }

    // MARK: Control on non-Latin layouts

    @Test func controlOnCyrillicLayoutUsesThePhysicalUSKey() throws {
        let event = key("\u{03}", ignoringModifiers: "с", keyCode: kVK_ANSI_C, flags: .control)
        let rewritten = try #require(XylemTerminalView.latinControlEvent(for: event))
        #expect(rewritten.charactersIgnoringModifiers == "c")
        #expect(rewritten.characters == "\u{03}")
        #expect(rewritten.keyCode == UInt16(kVK_ANSI_C))
        #expect(rewritten.modifierFlags.contains(.control))
    }

    @Test func controlRewriteSkipsLatinLayoutsAndCommand() {
        let latin = key("\u{03}", ignoringModifiers: "c", keyCode: kVK_ANSI_C, flags: .control)
        #expect(XylemTerminalView.latinControlEvent(for: latin) == nil)
        let withCommand = key("\u{03}", ignoringModifiers: "с", keyCode: kVK_ANSI_C, flags: [.control, .command])
        #expect(XylemTerminalView.latinControlEvent(for: withCommand) == nil)
    }
}

/// What SwiftTerm sends for Control+С on a Cyrillic layout once Xylem has
/// rewritten the event. Claude Code (2.1.325, checked with a pty driver)
/// answers SwiftTerm's XTVERSION by pushing kitty flags 5 (disambiguate +
/// report alternates); it reads both `CSI 99;5u` and `CSI 1089::99;5u`
/// (the base-layout field) as Ctrl+C, but ignores `CSI 1089;5u`. Which of
/// the two good forms comes out depends on the keyboard layout active while
/// the test runs (SwiftTerm translates the key code against it), so both
/// are accepted; the bad one is not.
@MainActor
struct TerminalControlKeyEncodingTests {

    private final class Capture: TerminalViewDelegate {
        var sent: [UInt8] = []
        func send(source: TerminalView, data: ArraySlice<UInt8>) { sent += data }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    private func controlC(on view: TerminalView) throws -> [UInt8] {
        let capture = Capture()
        view.terminalDelegate = capture
        let cyrillic = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{03}",
            charactersIgnoringModifiers: "с", isARepeat: false, keyCode: UInt16(kVK_ANSI_C)
        )!
        let event = try #require(XylemTerminalView.latinControlEvent(for: cyrillic))
        view.keyDown(with: event)
        return capture.sent
    }

    @Test func legacyModeSendsETX() throws {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        #expect(try controlC(on: view) == [0x03])
    }

    /// ⌘С on a Cyrillic layout, as AppKit delivers it (logged live).
    private func cyrillicCommandC() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "c",
            charactersIgnoringModifiers: "с", isARepeat: false, keyCode: UInt16(kVK_ANSI_C)
        )!
    }

    private func kittyBytes(for event: NSEvent) -> String {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.feed(text: "\u{1b}[>5u")
        let capture = Capture()
        view.terminalDelegate = capture
        view.keyDown(with: event)
        return String(decoding: capture.sent, as: UTF8.self)
    }

    /// Unrewritten, SwiftTerm reports the Cyrillic letter (1089 = "с") -
    /// what Claude Code typed into its prompt.
    @Test func cyrillicCommandKeyWasReportedAsTheCyrillicLetter() {
        #expect(kittyBytes(for: cyrillicCommandC()).hasPrefix("\u{1b}[1089"))
    }

    @Test func cyrillicCommandKeyIsSentLikeTheUSLayout() throws {
        let event = try #require(XylemTerminalView.latinCommandEvent(for: cyrillicCommandC()))
        #expect(event.charactersIgnoringModifiers == "c")
        #expect(event.characters == "c")
        #expect(event.modifierFlags.contains(.command))
        let usLayout = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "c",
            charactersIgnoringModifiers: "c", isARepeat: false, keyCode: UInt16(kVK_ANSI_C)
        )!
        #expect(kittyBytes(for: event) == kittyBytes(for: usLayout))
        #expect(kittyBytes(for: event) == "\u{1b}[99;9u")
    }

    /// ⌘, on a Ukrainian layout ("б" on the comma key) reaches Settings;
    /// ⇧⌘[ keeps its shifted character.
    @Test func commandPunctuationOnCyrillicUsesTheUSKey() throws {
        let comma = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                     windowNumber: 0, context: nil, characters: ",",
                                     charactersIgnoringModifiers: "б", isARepeat: false, keyCode: UInt16(kVK_ANSI_Comma))!
        let relabelled = try #require(XylemTerminalView.latinCommandEvent(for: comma))
        #expect(relabelled.charactersIgnoringModifiers == ",")
        let bracket = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                                       windowNumber: 0, context: nil, characters: "{",
                                       charactersIgnoringModifiers: "х", isARepeat: false, keyCode: UInt16(kVK_ANSI_LeftBracket))!
        let shifted = try #require(XylemTerminalView.latinCommandEvent(for: bracket))
        #expect(shifted.charactersIgnoringModifiers == "[")
        #expect(shifted.characters == "{")
    }

    @Test func commandRewriteSkipsLatinLayoutsControlAndNonLetters() {
        let latin = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                     windowNumber: 0, context: nil, characters: "c",
                                     charactersIgnoringModifiers: "c", isARepeat: false, keyCode: UInt16(kVK_ANSI_C))!
        #expect(XylemTerminalView.latinCommandEvent(for: latin) == nil)
        let withControl = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .control], timestamp: 0,
                                           windowNumber: 0, context: nil, characters: "c",
                                           charactersIgnoringModifiers: "с", isARepeat: false, keyCode: UInt16(kVK_ANSI_C))!
        #expect(XylemTerminalView.latinCommandEvent(for: withControl) == nil)
        let digit = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                     windowNumber: 0, context: nil, characters: "1",
                                     charactersIgnoringModifiers: "1", isARepeat: false, keyCode: UInt16(kVK_ANSI_1))!
        #expect(XylemTerminalView.latinCommandEvent(for: digit) == nil)
    }

    @Test func kittyModeSendsAKeyClaudeReadsAsControlC() throws {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.feed(text: "\u{1b}[>5u")   // what Claude Code pushes
        let sent = String(decoding: try controlC(on: view), as: UTF8.self)
        #expect(sent == "\u{1b}[99;5u" || sent == "\u{1b}[1089::99;5u", "sent \(sent.debugDescription)")
    }
}


/// Keystrokes reach the activity monitor through the key monitor (SwiftTerm
/// sends them to the process directly); Command shortcuts are not typing.
@MainActor
struct TerminalTypingDetectionTests {
    private func key(_ chars: String, keyCode: Int, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: UInt16(keyCode))!
    }

    @Test func lettersControlAndPasteAreTypingCommandShortcutsAreNot() {
        #expect(XylemTerminalView.typesIntoTerminal(key("a", keyCode: kVK_ANSI_A)))
        #expect(XylemTerminalView.typesIntoTerminal(key("\u{03}", keyCode: kVK_ANSI_C, flags: .control)))
        #expect(XylemTerminalView.typesIntoTerminal(key("\r", keyCode: kVK_Return)))
        #expect(XylemTerminalView.typesIntoTerminal(key("v", keyCode: kVK_ANSI_V, flags: .command)))
        #expect(!XylemTerminalView.typesIntoTerminal(key("k", keyCode: kVK_ANSI_K, flags: .command)))
        #expect(!XylemTerminalView.typesIntoTerminal(key("1", keyCode: kVK_ANSI_1, flags: .command)))
    }

    @Test func xylemsOwnSendCountsAsInput() {
        let session = TerminalSession(title: "t", configuration: .loginShell(workingDirectory: "/tmp"),
                                      startsImmediately: false)
        defer { session.close() }
        #expect(session.activity.snapshot().lastInput == nil)
        session.send(text: "/compact")
        #expect(session.activity.snapshot().lastInput != nil)
    }
}
