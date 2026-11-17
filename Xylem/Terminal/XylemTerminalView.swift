//
//  XylemTerminalView.swift
//  Xylem
//
//  SwiftTerm's LocalProcessTerminalView with the key handling Claude Code
//  needs on top: Shift+Return as a newline, and Control shortcuts and
//  Option letters that work on non-Latin layouts. Everything else (text
//  input, IME, Option-as-Meta, copy and bracketed paste) stays SwiftTerm's.
//

import AppKit
import Carbon.HIToolbox
import SwiftTerm

final class XylemTerminalView: LocalProcessTerminalView {

    /// Told about the user's keystrokes and the terminal's own reports, so
    /// output that merely echoes typing doesn't read as Claude working, an
    /// answer to a permission prompt is seen, and focus is known
    /// (ClaudeTabState).
    var activityMonitor: TerminalActivityMonitor?

    override init(frame: CGRect) {
        super.init(frame: frame)
        Self.installKeyMonitor()
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        Self.installKeyMonitor()
        registerForDraggedTypes([.fileURL])
    }

    // MARK: - Dropping files

    /// Files dropped on the terminal (from the Files / Changes drawer or
    /// Finder) type their shell-quoted paths, space-separated, with no
    /// Enter - as Terminal.app does. SwiftTerm itself accepts no drops.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.droppedPaths(sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.droppedPaths(sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = Self.droppedPaths(sender.draggingPasteboard)
        guard let text = Self.pathInsertion(paths) else {
            NSSound.beep()
            return false
        }
        activityMonitor?.noteInput()
        send(txt: text)
        window?.makeFirstResponder(self)
        return true
    }

    /// The text that types `paths` into the terminal: each shell-quoted,
    /// space-separated, a space after the last (`trailingSpace`), no Enter -
    /// as Terminal.app types a dropped file. nil when there is nothing to
    /// type or a path holds a control character: the terminal is in raw
    /// mode, so a file named `x<Ctrl-U>rm -rf ~<Return>` would run that
    /// command (quoting can't help - the keys act before the shell parses
    /// anything). Plain typing, not a bracketed paste: Claude Code turns a
    /// typed image path into an attachment (the Image button relies on it).
    nonisolated static func pathInsertion(_ paths: [String], trailingSpace: Bool = true) -> String? {
        guard !paths.isEmpty, !paths.contains(where: containsControlCharacter) else { return nil }
        return paths.map(TerminalSession.shellQuote).joined(separator: " ") + (trailingSpace ? " " : "")
    }

    /// C0 controls, DEL and C1 controls (some terminals act on 0x9B as CSI).
    nonisolated static func containsControlCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }
    }

    private static func droppedPaths(_ pasteboard: NSPasteboard) -> [String] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return (urls ?? []).map(\.path)
    }

    /// What the terminal itself sends: mouse and focus reports, replies to
    /// the program's queries. Keystrokes, paste and `send(txt:)` do NOT pass
    /// here - SwiftTerm 1.99's LocalProcessTerminalView delivers them
    /// straight to the process (seen in a byte log) - so the key monitor
    /// below and `TerminalSession.send(text:)` note those.
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        activityMonitor?.noteSent(data)
        super.send(source: source, data: data)
    }

    /// Return's virtual key code (kVK_Return). The keypad Enter key is left
    /// alone on purpose.
    private static let returnKeyCode: UInt16 = 36

    /// Shift+Return must insert a newline in Claude's prompt instead of
    /// submitting it. With the kitty keyboard protocol on (Claude Code turns
    /// it on whenever the terminal answers `CSI ? u`) SwiftTerm already sends
    /// `CSI 13 ; 2 u`, so nothing is done then. In legacy mode SwiftTerm sends
    /// a bare CR for every Return, so Shift+Return is sent as ESC CR
    /// (Meta+Enter), which Claude Code also treats as "insert newline".
    /// While an input method is composing, Return belongs to the IME.
    ///
    /// `keyDown` is `public` (not `open`) in SwiftTerm, so it cannot be
    /// overridden from here; `interpretKeyEvents` is the AppKit hook keyDown
    /// hands plain and Shift-modified keys to.
    override func interpretKeyEvents(_ eventArray: [NSEvent]) {
        if eventArray.count == 1, let event = eventArray.first, Self.isShiftReturn(event),
           keyboardEnhancementFlags.isEmpty, !hasMarkedText() {
            send(txt: "\u{1b}\r")
            return
        }
        super.interpretKeyEvents(eventArray)
    }

    static func isShiftReturn(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == returnKeyCode else { return false }
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        return modifiers == .shift
    }

    // MARK: - Non-Latin layouts

    /// One app-local key monitor covers two cases on non-Latin layouts.
    /// SwiftTerm's `keyDown` cannot be overridden from outside the module, so
    /// the monitor rewrites or consumes the event before AppKit delivers it,
    /// and only when a Xylem terminal is the first responder.
    private static var keyMonitor: Any?

    private static func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let view = event.window?.firstResponder as? XylemTerminalView else { return event }
            if typesIntoTerminal(event) { view.activityMonitor?.noteInput() }
            if let text = optionComposedText(for: event, optionAsMeta: view.optionAsMetaKey) {
                // Plain text in both keyboard modes. Not `insertText`: in kitty
                // mode it would encode the letter against SwiftTerm's pending
                // (previous) key event and send that key's code and modifiers.
                view.send(txt: text)
                return nil
            }
            return latinControlEvent(for: event) ?? latinCommandEvent(for: event) ?? event
        }
    }

    /// A key press the terminal turns into input: anything but a Command
    /// shortcut (menu items, ⌘K, ⌘1…), except ⌘V, which pastes.
    static func typesIntoTerminal(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard event.modifierFlags.contains(.command) else { return true }
        return event.charactersIgnoringModifiers?.lowercased() == "v"
            || event.keyCode == UInt16(kVK_ANSI_V)
    }

    /// With Option as Meta, SwiftTerm sends Option+key as ESC + the key's
    /// unmodified character. On a non-Latin layout that is ESC + a Cyrillic
    /// letter, which no Claude Code or shell binding uses, while it makes
    /// letters a layout only offers on Option untypeable (Ukrainian-QWERTY
    /// puts ґ, щ and ї there). So when the unmodified key is non-ASCII and
    /// Option (± Shift) composes a letter, type that letter instead. Latin
    /// layouts keep full Meta: Option+F stays Meta-f, not "ƒ".
    static func optionComposedText(for event: NSEvent, optionAsMeta: Bool) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard optionAsMeta, event.type == .keyDown,
              flags == .option || flags == [.option, .shift],
              let base = event.charactersIgnoringModifiers?.unicodeScalars.first, !base.isASCII,
              let text = event.characters, text.unicodeScalars.count == 1,
              let composed = text.unicodeScalars.first,
              !composed.isASCII, CharacterSet.letters.contains(composed)
        else { return nil }
        return text
    }

    /// On a Cyrillic (or any non-Latin) layout, Control+C arrives with
    /// `charactersIgnoringModifiers == "с"`, which has no Control translation.
    /// SwiftTerm's legacy encoder falls back to the key's PC-101 position on
    /// its own, so for the legacy path this rewrite is a safety net that
    /// keeps the Latin letter whatever SwiftTerm does. In kitty mode
    /// SwiftTerm re-derives the key from the key code and reports the
    /// physical key in the base-layout field (`CSI 1089::99;5u`).
    ///
    /// Returns the same key press re-labelled with the US-layout letter for
    /// its physical key, or nil when no rewrite is needed (Command held, the
    /// layout already yields ASCII, or the key is not a letter or bracket).
    static func latinControlEvent(for event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags
        guard event.type == .keyDown,
              flags.contains(.control), !flags.contains(.command),
              let typed = event.charactersIgnoringModifiers?.unicodeScalars.first,
              !typed.isASCII,
              let latin = physicalKeyCharacters[Int(event.keyCode)],
              let ascii = latin.unicodeScalars.first?.value
        else { return nil }
        // Control maps @..._ (and a..z) onto 0x00...0x1F.
        let control = String(UnicodeScalar(UInt8(ascii & 0x1F)))
        return NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: flags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: control,
            charactersIgnoringModifiers: latin,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        )
    }

    /// Command+letter on a Cyrillic (or any non-Latin) layout arrives with
    /// `characters == "c"` but `charactersIgnoringModifiers == "с"`. With
    /// Claude Code running (kitty keyboard mode) SwiftTerm reports the key
    /// from the latter, as super+"с", which Claude Code didn't take as its
    /// shortcut and typed as the letter: ⌘С copied *and* put "с" in the
    /// prompt (seen 2026-11-16). Relabelled with the US letter of the
    /// physical key, the press is exactly what the US layout sends - for the
    /// menus (⌘C, ⌘V, ⌘K…) and for the program - as macOS shortcuts work by
    /// key position on every layout.
    static func latinCommandEvent(for event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags
        guard event.type == .keyDown,
              flags.contains(.command), !flags.contains(.control),
              let typed = event.charactersIgnoringModifiers?.unicodeScalars.first,
              !typed.isASCII,
              let key = commandKeyCharacters[Int(event.keyCode)]
        else { return nil }
        let latin = key.base
        let characters = flags.contains(.shift) ? key.shifted : latin
        return NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: flags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: latin,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        )
    }

    /// Physical key -> US character, unshifted and shifted, for Command
    /// shortcuts: the letters and the punctuation keys, which also carry
    /// Cyrillic letters on Ukrainian and Russian layouts (⌘, is "б").
    private static let commandKeyCharacters: [Int: (base: String, shifted: String)] = {
        var keys: [Int: (base: String, shifted: String)] = [:]
        for (code, letter) in physicalKeyCharacters where letter.first?.isLetter == true {
            keys[code] = (letter, letter.uppercased())
        }
        let punctuation: [(Int, String, String)] = [
            (kVK_ANSI_LeftBracket, "[", "{"), (kVK_ANSI_RightBracket, "]", "}"), (kVK_ANSI_Backslash, "\\", "|"),
            (kVK_ANSI_Comma, ",", "<"), (kVK_ANSI_Period, ".", ">"), (kVK_ANSI_Slash, "/", "?"),
            (kVK_ANSI_Semicolon, ";", ":"), (kVK_ANSI_Quote, "'", "\""), (kVK_ANSI_Grave, "`", "~"),
            (kVK_ANSI_Minus, "-", "_"), (kVK_ANSI_Equal, "=", "+")
        ]
        for (code, base, shifted) in punctuation { keys[code] = (base, shifted) }
        return keys
    }()

    /// Physical key -> character on the ANSI US layout, for the keys that
    /// have a Control meaning in a terminal.
    private static let physicalKeyCharacters: [Int: String] = [
        kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d",
        kVK_ANSI_E: "e", kVK_ANSI_F: "f", kVK_ANSI_G: "g", kVK_ANSI_H: "h",
        kVK_ANSI_I: "i", kVK_ANSI_J: "j", kVK_ANSI_K: "k", kVK_ANSI_L: "l",
        kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o", kVK_ANSI_P: "p",
        kVK_ANSI_Q: "q", kVK_ANSI_R: "r", kVK_ANSI_S: "s", kVK_ANSI_T: "t",
        kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x",
        kVK_ANSI_Y: "y", kVK_ANSI_Z: "z",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\"
    ]
}
