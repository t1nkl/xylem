//
//  ScreenText.swift
//  Xylem
//
//  Text read off a terminal screen, compared with the whitespace gone and
//  lowercased, so a line the terminal wrapped or padded still matches.
//

import Foundation

nonisolated enum ScreenText {
    static func flattened(_ screen: String) -> String {
        String(screen.lowercased().unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(Character.init))
    }
}
