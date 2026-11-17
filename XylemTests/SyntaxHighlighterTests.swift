//
//  SyntaxHighlighterTests.swift
//  XylemTests
//
//  highlight.js output parsed without losing a character (HighlightSwift's
//  HTML route trimmed leading/trailing lines and the first indent), the
//  language from a file name, long-line cutting, the diff's two sides and
//  a real run through the bundled engine.
//

import Testing
import Foundation

struct SyntaxHighlighterTests {

    private func text(_ lines: [[SyntaxRun]]) -> String {
        lines.map { $0.map(\.text).joined() }.joined(separator: "\n")
    }

    /// A big input frees the JS machine afterwards (its heap stayed at
    /// hundreds of MB); the next request loads it again and still works.
    @Test func bigInputsKeepWorkingAfterTheEngineIsFreed() async throws {
        let big = (0..<4000).map { "let value\($0) = \($0) // comment" }.joined(separator: "\n")
        #expect(big.utf8.count > 100_000)
        let first = try #require(await SyntaxHighlighter.highlight(big, language: "swift"))
        let second = try #require(await SyntaxHighlighter.highlight(big, language: "swift"))
        #expect(first.count == 4000)
        #expect(first == second)
        let small = try #require(await SyntaxHighlighter.highlight("let a = 1", language: "swift"))
        #expect(small.first?.first?.scope == .keyword)
    }

    @Test func htmlParsingIsLosslessAndScoped() {
        let html = "\n\n    <span class=\"hljs-keyword\">if</span> a &lt; b &amp;&amp; c &gt; &quot;x&quot; &#x27;y&#x27; {\n  <span class=\"hljs-comment\">// one\ntwo</span>\n}\n"
        let lines = HighlightHTML.lines(html)
        #expect(text(lines) == "\n\n    if a < b && c > \"x\" 'y' {\n  // one\ntwo\n}\n")
        #expect(lines.count == 7)
        #expect(lines[2].first { $0.text == "if" }?.scope == .keyword)
        // A multi-line comment keeps its colour on both lines.
        #expect(lines[3].last?.scope == .comment && lines[4].first?.scope == .comment)
        // Nested spans: the inner class wins, a class-less inner span keeps the outer one.
        let nested = HighlightHTML.lines("<span class=\"hljs-string\">a<span class=\"hljs-subst\">b</span><span>c</span></span>")
        #expect(nested[0].map(\.scope) == [.string, .variable, .string])
        // A stray "&" is text, not an entity.
        #expect(text(HighlightHTML.lines("a & b;")) == "a & b;")
    }

    @Test func languageFromFileName() {
        #expect(SyntaxHighlighter.language(forFile: "/x/src/app.tsx") == "typescript")
        #expect(SyntaxHighlighter.language(forFile: "/x/Api/InvoiceController.PHP") == "php")
        #expect(SyntaxHighlighter.language(forFile: "/x/Dockerfile.dev") == "dockerfile")
        #expect(SyntaxHighlighter.language(forFile: "/x/Makefile") == "makefile")
        #expect(SyntaxHighlighter.language(forFile: "/x/notes.unknownext") == nil)
    }

    @Test func longLinesAreCutLikeThePlainPreview() {
        let long = [SyntaxRun(text: String(repeating: "a", count: 1500), scope: .string),
                    SyntaxRun(text: String(repeating: "b", count: 1500), scope: nil)]
        let cut = SyntaxHighlighter.clip(long)
        #expect(cut.map(\.text).joined().count == SyntaxHighlighter.maxLineLength + 1)
        #expect(cut.last?.text == "…")
        #expect(SyntaxHighlighter.clip([SyntaxRun(text: "short", scope: nil)]).count == 1)
    }

    @Test func diffSidesFollowEachHunk() {
        let document = UnifiedDiffParser.parse("""
        @@ -1,3 +1,3 @@
         keep
        -old
        +new
        @@ -10,2 +10,2 @@
        -gone
         tail
        """)
        let sides = DiffSyntax.sides(document)
        #expect(sides.count == 2)
        #expect(sides[0].old.lines == ["keep", "old"] && sides[0].new.lines == ["keep", "new"])
        #expect(sides[1].old.lines == ["gone", "tail"] && sides[1].new.lines == ["tail"])
        // Context lines are coloured from the new side only.
        #expect(sides[0].old.ids.first == -1)
    }

    /// The bundled highlight.js, end to end: TypeScript, PHP, Python; blank
    /// edges and indentation survive; an unknown language is left plain.
    @Test func realEngineKeepsEveryLine() async throws {
        let code = "\n\n    const total: number = 42 // answer\nfunction run() {\n  return `v${total}`\n}\n\n"
        let lines = try #require(await SyntaxHighlighter.highlight(code, language: "typescript"))
        #expect(text(lines) == code)
        #expect(lines.count == code.split(separator: "\n", omittingEmptySubsequences: false).count)
        #expect(lines[2].contains { $0.text == "const" && $0.scope == .keyword })
        #expect(lines[2].contains { $0.scope == .comment })
        let php = try #require(await SyntaxHighlighter.highlight("<?php\nclass A { public function b() {} }", language: "php"))
        #expect(php[1].contains { $0.text == "class" && $0.scope == .keyword })
        let python = try #require(await SyntaxHighlighter.highlight("def f():\n    return 'x'", language: "python"))
        #expect(python[1].contains { $0.scope == .string })
        #expect(await SyntaxHighlighter.highlight("x", language: "no-such-language") == nil)
    }

    @Test func diffColoursComeFromTheRightSide() async {
        let document = UnifiedDiffParser.parse("@@ -1,2 +1,2 @@\n /* start\n-old line */\n+new line */")
        let colours = await DiffSyntax.highlight(document, language: "javascript")
        // Both removed and added lines sit inside the comment opened by the context line.
        for line in document.lines where line.kind == .added || line.kind == .removed {
            #expect(colours[line.id]?.allSatisfy { $0.scope == .comment } == true)
        }
    }

    @Test func tenThousandLineFileIsHighlighted() async throws {
        let code = String(repeating: "export function f(a: number): string {\n  return `v${a}` // c\n}\n", count: 3400)
        #expect(code.utf8.count < SyntaxHighlighter.maxBytes)
        let start = Date()
        let lines = try #require(await SyntaxHighlighter.highlight(code, language: "typescript"))
        #expect(lines.count == code.split(separator: "\n", omittingEmptySubsequences: false).count)
        // Generous bound for a Debug test run; Release measured ~0.5 s.
        #expect(Date().timeIntervalSince(start) < 10)
    }
}
