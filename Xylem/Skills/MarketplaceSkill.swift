//
//  MarketplaceSkill.swift
//  Xylem
//
//  Immutable value object describing one skill discoverable through
//  https://skills.sh. The install identifier is `<source>/<skillId>`; we
//  preserve both pieces so we can display the repo hint alongside the name.
//
//  `nonisolated` so its Codable conformance is usable from the off-main
//  parse and cache I/O.
//

import Foundation

nonisolated struct MarketplaceSkill: Identifiable, Hashable, Codable, Sendable {
    var id: String { source + "/" + skillId }
    let source: String          // e.g. "anthropics/skills"
    let skillId: String         // e.g. "frontend-design"
    let name: String
    let installs: Int

    /// Install command to run inside an active claude tab or shell.
    /// Uses the CLI's `-s` flag to target just this skill from a multi-skill
    /// repo; the bare `npx skills add <source>` form would install the
    /// entire repository. Both parts come from skills.sh, so each is one
    /// shell word: a crafted entry can't add a command of its own.
    var installCommand: String {
        "npx skills add \(TerminalSession.shellWord(source)) -s \(TerminalSession.shellWord(skillId))"
    }

    /// Web URL for the skill's landing page on skills.sh.
    var skillsURL: URL? {
        URL(string: "https://skills.sh/\(source)/\(skillId)")
    }

    /// GitHub repo URL.
    var githubURL: URL? {
        URL(string: "https://github.com/\(source)")
    }
}
