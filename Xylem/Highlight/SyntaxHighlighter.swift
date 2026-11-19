//
//  SyntaxHighlighter.swift
//  Xylem
//
//  Syntax colours for the Files preview and the Changes diff, from
//  highlight.js 11.9 (BSD-3, `highlight.min.js` next to this file, 51
//  languages) run in JavaScriptCore.
//
//  Not the HighlightSwift package: it turns highlight.js' HTML into text
//  through the HTML importer, which trims leading/trailing lines and the
//  first line's indent (8 lines in, 4 out - our line numbers would be wrong)
//  and takes 1.1 s for 6000 lines. Here highlight.js' `<span class="hljs-…">`
//  output is parsed directly: lossless, ~0.26 s for the same 6000 lines.
//
//  Size: everything the preview shows is highlighted (up to
//  `FilePreview.Loader.maxBytes`, 1 MB - a 10 000-line class is ~0.5 s,
//  measured worst cases 911 KB JSON 1.5 s, 301 KB minified JS 0.5 s). It runs
//  off main and never blocks: the plain text shows at once and the colours
//  replace it when ready. Lines over `maxLineLength` are cut after
//  highlighting, as the plain preview cuts them. The language comes from the
//  file name; no auto-detection (slow, and it calls TypeScript JavaScript).
//

import Foundation
import JavaScriptCore

/// One coloured piece of a line. `scope` nil = plain text.
nonisolated struct SyntaxRun: Equatable, Sendable {
    let text: String
    let scope: SyntaxScope?
}

/// The colour classes we draw (highlight.js has ~40; these group them).
nonisolated enum SyntaxScope: Hashable, Sendable {
    case keyword, string, number, comment, function, type, property, tag, meta, variable, heading
}

nonisolated enum SyntaxHighlighter {
    /// The preview's cap too (`FilePreview.Loader.maxBytes`): 1 MB.
    static let maxBytes = 1024 * 1024
    /// The preview's per-line cut (`UnifiedDiffParser.maxLineLength`).
    static var maxLineLength: Int { UnifiedDiffParser.maxLineLength }

    /// Lines of runs, one entry per line of `text` (split on "\n"), each cut
    /// like the plain preview cuts it; nil when the text is over `maxBytes`,
    /// the language isn't bundled, or the task was cancelled while it
    /// waited its turn.
    static func highlight(_ text: String, language: String) async -> [[SyntaxRun]]? {
        guard text.utf8.count <= maxBytes else { return nil }
        guard let lines = await Engine.shared.highlight(text, language: language) else { return nil }
        return lines.map(clip)
    }

    /// A line longer than `maxLineLength` characters: its first ones and "…".
    static func clip(_ runs: [SyntaxRun]) -> [SyntaxRun] {
        var remaining = maxLineLength
        guard runs.reduce(0, { $0 + $1.text.count }) > remaining else { return runs }
        var clipped: [SyntaxRun] = []
        for run in runs {
            if run.text.count <= remaining {
                clipped.append(run); remaining -= run.text.count
            } else {
                clipped.append(SyntaxRun(text: String(run.text.prefix(remaining)), scope: run.scope))
                break
            }
        }
        clipped.append(SyntaxRun(text: "…", scope: nil))
        return clipped
    }

    /// highlight.js' name for a file's language, nil when we don't know it.
    static func language(forFile path: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        if let byName = namedFiles[name] { return byName }
        if name.hasPrefix("dockerfile") { return "dockerfile" }
        let ext = (name as NSString).pathExtension
        return extensions[ext]
    }

    private static let namedFiles: [String: String] = [
        "makefile": "makefile", "gnumakefile": "makefile", "gemfile": "ruby", "rakefile": "ruby",
        "podfile": "ruby", "package.swift": "swift", ".bashrc": "bash", ".zshrc": "bash", ".zshenv": "bash",
        ".bash_profile": "bash", ".profile": "bash", ".gitignore": "plaintext", ".env": "bash",
    ]

    private static let extensions: [String: String] = [
        "ts": "typescript", "tsx": "typescript", "mts": "typescript", "cts": "typescript",
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
        "php": "php", "py": "python", "pyi": "python", "go": "go", "rb": "ruby", "swift": "swift",
        "css": "css", "scss": "scss", "less": "less", "sql": "sql", "json": "json", "jsonc": "json",
        "md": "markdown", "markdown": "markdown", "yml": "yaml", "yaml": "yaml",
        "sh": "bash", "bash": "bash", "zsh": "bash", "kt": "kotlin", "kts": "kotlin", "rs": "rust",
        "java": "java", "cs": "csharp", "c": "c", "h": "c", "cpp": "cpp", "cc": "cpp", "cxx": "cpp",
        "hpp": "cpp", "hh": "cpp", "m": "objectivec", "mm": "objectivec", "html": "xml", "htm": "xml",
        "xml": "xml", "svg": "xml", "plist": "xml", "xcscheme": "xml", "vue": "xml",
        "toml": "ini", "ini": "ini", "cfg": "ini", "conf": "ini", "lua": "lua", "pl": "perl", "pm": "perl",
        "r": "r", "scala": "scala", "dart": "dart", "graphql": "graphql", "gql": "graphql",
        "diff": "diff", "patch": "diff", "mk": "makefile", "vb": "vbnet", "wasm": "wasm",
    ]

    // MARK: - Engine

    /// One JavaScriptCore context for the app, used by one request at a
    /// time (an actor), loaded on first use (~30 ms).
    private actor Engine {
        static let shared = Engine()
        private var hljs: JSValue?
        private var context: JSContext?

        func highlight(_ text: String, language: String) -> [[SyntaxRun]]? {
            // A request that was superseded while it waited: skip the work.
            guard !Task.isCancelled, let hljs = load() else { return nil }
            guard hljs.invokeMethod("getLanguage", withArguments: [language])?.isUndefined == false else { return nil }
            let result = hljs.invokeMethod("highlight", withArguments: [text, ["language": language, "ignoreIllegals": true]])
            // isUndefined, not the string "undefined": a file whose text is
            // literally `undefined` would otherwise lose its colours.
            guard let value = result?.objectForKeyedSubscript("value"), !value.isUndefined, let html = value.toString() else { return nil }
            let lines = HighlightHTML.lines(html)
            // A big file grows the JS heap by hundreds of MB, and JavaScriptCore
            // keeps those pages after a collection (measured on an Intel Mac,
            // macOS 15: 250 MB of "WebKit malloc" with the drawer closed after
            // a 1 MB preview). Dropping the whole virtual machine gives them
            // back; the next request loads the script again (~30 ms).
            if text.utf8.count > Self.unloadAfterBytes { unload() }
            return lines
        }

        /// Inputs over this size free the JS machine afterwards.
        static let unloadAfterBytes = 100_000

        private func unload() {
            hljs = nil
            context = nil
        }

        private func load() -> JSValue? {
            if let hljs { return hljs }
            // Its own virtual machine, so dropping the context frees its heap.
            guard let url = Bundle(for: BundleToken.self).url(forResource: "highlight.min", withExtension: "js"),
                  let script = try? String(contentsOf: url, encoding: .utf8),
                  let machine = JSVirtualMachine(),
                  let context = JSContext(virtualMachine: machine)
            else { return nil }
            context.evaluateScript(script)
            guard let value = context.objectForKeyedSubscript("hljs"), !value.isUndefined else { return nil }
            self.context = context
            self.hljs = value
            return value
        }
    }

    /// The bundle with the script: the app, or the unit-test bundle (the
    /// tests compile these sources themselves).
    private final class BundleToken {}
}

/// highlight.js' HTML (`<span class="hljs-keyword">if</span>` and escaped
/// text, nothing else) as lines of runs. Lossless: the runs' text joined
/// is the original source.
nonisolated enum HighlightHTML {
    static func lines(_ html: String) -> [[SyntaxRun]] {
        var lines: [[SyntaxRun]] = [[]]
        var scopes: [SyntaxScope?] = []
        var buffer = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            let scope = scopes.last ?? nil
            // A run can span lines (comments, strings): cut it at each "\n".
            let parts = buffer.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, part) in parts.enumerated() {
                if index > 0 { lines.append([]) }
                if !part.isEmpty { lines[lines.count - 1].append(SyntaxRun(text: String(part), scope: scope)) }
            }
            buffer = ""
        }
        var index = html.startIndex
        while index < html.endIndex {
            let character = html[index]
            if character == "<" {
                flush()
                guard let close = html[index...].firstIndex(of: ">") else { break }
                let tag = html[html.index(after: index)..<close]
                if tag.hasPrefix("/") {
                    _ = scopes.popLast()
                } else {
                    // Inner spans without a class of their own keep the outer colour.
                    scopes.append(scope(forTag: tag) ?? (scopes.last ?? nil))
                }
                index = html.index(after: close)
            } else if character == "&" {
                guard let semicolon = html[index...].firstIndex(of: ";"),
                      html.distance(from: index, to: semicolon) <= 8 else {
                    buffer.append(character); index = html.index(after: index); continue
                }
                let entity = String(html[index...semicolon])
                buffer += entities[entity] ?? entity
                index = html.index(after: semicolon)
            } else {
                buffer.append(character)
                index = html.index(after: index)
            }
        }
        flush()
        return lines
    }

    private static let entities = ["&lt;": "<", "&gt;": ">", "&amp;": "&", "&quot;": "\"", "&#x27;": "'", "&#39;": "'"]

    /// `span class="hljs-title function_"` -> the first hljs class's scope.
    private static func scope(forTag tag: Substring) -> SyntaxScope? {
        guard let start = tag.range(of: "class=\"") else { return nil }
        let rest = tag[start.upperBound...]
        let classes = rest[..<(rest.firstIndex(of: "\"") ?? rest.endIndex)]
        for name in classes.split(separator: " ") where name.hasPrefix("hljs-") {
            if let scope = scopes[String(name.dropFirst(5))] { return scope }
        }
        return nil
    }

    private static let scopes: [String: SyntaxScope] = [
        "keyword": .keyword, "built_in": .type, "type": .type, "literal": .number, "number": .number,
        "operator": .keyword, "punctuation": .meta,
        "string": .string, "regexp": .string, "char": .string, "symbol": .number, "link": .string,
        "comment": .comment, "quote": .comment, "doctag": .keyword,
        "title": .function, "section": .heading, "class": .type,
        "attr": .property, "attribute": .property, "property": .property, "params": .variable,
        "variable": .variable, "template-variable": .variable, "subst": .variable,
        "tag": .tag, "name": .tag, "selector-tag": .tag, "selector-id": .function, "selector-class": .function,
        "selector-attr": .property, "selector-pseudo": .property,
        "meta": .meta, "meta-keyword": .keyword, "meta-string": .string,
        "bullet": .keyword, "code": .string, "emphasis": .heading, "strong": .heading,
        "addition": .string, "deletion": .tag,
    ]
}

/// Colours for a diff: each hunk's old side (context + removed lines) and
/// new side (context + added) are highlighted as whole pieces of code, so a
/// line inside a multi-line comment or string gets the right colour, then
/// mapped back onto the diff's lines (context and added from the new side,
/// removed from the old). Keyed by `DiffLine.id`.
nonisolated enum DiffSyntax {
    struct Side: Equatable {
        var ids: [Int] = []
        var lines: [String] = []
    }

    /// The hunks' two sides, in order (pure; tested).
    static func sides(_ document: DiffDocument) -> [(old: Side, new: Side)] {
        var hunks: [(old: Side, new: Side)] = []
        for line in document.lines {
            switch line.kind {
            case .hunk:
                hunks.append((Side(), Side()))
            case .context:
                guard !hunks.isEmpty else { continue }
                hunks[hunks.count - 1].old.lines.append(line.text)
                hunks[hunks.count - 1].old.ids.append(-1)            // context takes the new side's colours
                hunks[hunks.count - 1].new.lines.append(line.text)
                hunks[hunks.count - 1].new.ids.append(line.id)
            case .added:
                guard !hunks.isEmpty else { continue }
                hunks[hunks.count - 1].new.lines.append(line.text)
                hunks[hunks.count - 1].new.ids.append(line.id)
            case .removed:
                guard !hunks.isEmpty else { continue }
                hunks[hunks.count - 1].old.lines.append(line.text)
                hunks[hunks.count - 1].old.ids.append(line.id)
            case .note:
                continue
            }
        }
        return hunks
    }

    static func highlight(_ document: DiffDocument, language: String) async -> [Int: [SyntaxRun]] {
        var colours: [Int: [SyntaxRun]] = [:]
        for hunk in sides(document) {
            for side in [hunk.new, hunk.old] where side.ids.contains(where: { $0 >= 0 }) {
                guard !Task.isCancelled else { return colours }
                guard let lines = await SyntaxHighlighter.highlight(side.lines.joined(separator: "\n"), language: language),
                      lines.count == side.ids.count else { continue }
                for (id, runs) in zip(side.ids, lines) where id >= 0 { colours[id] = runs }
            }
        }
        return colours
    }
}
