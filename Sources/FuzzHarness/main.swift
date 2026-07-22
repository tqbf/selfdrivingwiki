// Build: swift build --target FuzzHarness -Xswiftc -sanitize=address
// Run:   .build/debug/FuzzHarness [seed] [iterations]
//
// Property-based fuzzer for the pure-logic parser cluster (WikiFSLinks +
// WikiFSMarkdown). NOT a swift-test target — runs as a standalone binary.
// Generates random/malformed inputs and feeds them to the parsers to hunt
// memory-safety bugs (precondition failures, force-unwraps, infinite loops,
// ASan violations, EXC_BAD_ACCESS).
//
// Uses a deterministic xorshift64 PRNG seeded from argv[1] or `time(nil)` so
// any crash is reproducible by re-passing the seed. Prints the seed, iter,
// kind, and base64-encoded input BEFORE every parser call so a trap leaves a
// forensic trail in stdout. Runs indefinitely (until Ctrl-C or iteration cap)
// and prints progress every 10 000 iterations.

import Foundation
import WikiFSTypes
import WikiFSLinks
import WikiFSMarkdown

// MARK: - PRNG

struct FuzzRNG {
    var seed: UInt64

    init(seed: UInt64) { self.seed = seed }

    mutating func next() -> UInt64 {
        var x = seed
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        seed = x
        return x
    }

    mutating func nextBool() -> Bool { next() & 1 == 0 }

    mutating func nextInt(_ n: Int) -> Int {
        precondition(n > 0, "nextInt requires n > 0")
        return Int(next() % UInt64(n))
    }

    mutating func nextRange(_ lo: Int, _ hi: Int) -> Int {
        let span = hi - lo + 1
        return lo + Int(next() % UInt64(span))
    }

    mutating func nextChar(_ set: [Character]) -> Character {
        set[nextInt(set.count)]
    }

    mutating func nextBytes(_ n: Int) -> [UInt8] {
        (0..<n).map { _ in UInt8(next() & 0xFF) }
    }
}

// MARK: - Tokens (sampled by generators; mirrors Sources/FuzzHarness/fuzz-dict.txt)

let wikiTokens = ["[[", "]]", "|", "page:", "source:", "chat:", "!", "#",
                  "\"", "@v1", "@v3", "#\"", "[[page:", "[[source:", "[[chat:",
                  "[[#", "01H", "01J", "[[X|]]", "[[|]]", "]]\n", "|alias]]"]

let mdTokens = ["# ", "## ", "### ", "**", "*", "_", "`", "```", "> ", "\n\n",
                "- [x] ", "- [ ] ", "[^id]:", "[^id]", "|---|", "  - ", "1. "]

let htmlTokens = ["<p>", "</p>", "<a href=\"", "\">", "</a>", "<strong>",
                  "</strong>", "<em>", "</em>", "<code>", "</code>", "<pre>",
                  "</pre>", "<title>", "</title>", "<script>", "</script>",
                  "<ul>", "<li>", "</li>", "</ul>", "<img src=\"", "<blockquote>",
                  "</blockquote>", "&amp;", "&#0;", "&#xFF;", "<", ">", "</", "/>"]

let specialChars: [Character] = ["[", "]", "|", "#", "\"", "@", ":", "!",
                                 "\n", "\t", " "]

let ulidAlphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

// MARK: - Input kinds

enum FuzzKind: Int, CaseIterable {
    case wikiLink, markdown, html, bareTarget, rawSpecial
}

struct FuzzInput {
    let kind: FuzzKind
    let text: String
    var base64: String { Data(text.utf8).base64EncodedString() }
}

// MARK: - Generators (simple: next() % n to pick, no closure-heavy weighted API)

func randomULID(_ r: inout FuzzRNG) -> String {
    String((0..<26).map { _ in ulidAlphabet[r.nextInt(ulidAlphabet.count)] })
}

func randomString(_ r: inout FuzzRNG, length: Int) -> String {
    var s = ""
    for _ in 0..<length {
        let c = r.nextRange(32, 126)
        s.unicodeScalars.append(Unicode.Scalar(c)!)
    }
    return s
}

func randomUnicode(_ r: inout FuzzRNG, length: Int) -> String {
    var s = ""
    while s.count < length {
        let code = r.nextRange(0, 0x10FFFF)
        if code >= 0xD800 && code <= 0xDFFF { continue }
        if let sc = Unicode.Scalar(code) { s.unicodeScalars.append(sc) }
    }
    return s
}

func veryLong(_ r: inout FuzzRNG, chars: [Character]) -> String {
    let n = r.nextRange(10_000, 20_000)
    return String((0..<n).map { _ in chars[r.nextInt(chars.count)] })
}

// --- wiki-link generators ---

func genWikiLink(_ r: inout FuzzRNG) -> String {
    let pick = r.nextInt(9)
    switch pick {
    case 0: return wellFormedWiki(&r)
    case 1: return malformedWiki(&r)
    case 2: return nestedWiki(&r)
    case 3: return pipeBombWiki(&r)
    case 4: return unicodeWiki(&r)
    case 5: return veryLongWiki(&r)
    case 6: return tokenSoup(&r, tokens: wikiTokens)
    case 7: return ""
    default: return String(specialChars[r.nextInt(specialChars.count)])
    }
}

func wellFormedWiki(_ r: inout FuzzRNG) -> String {
    let ulid = randomULID(&r)
    let kinds = ["page", "source", "chat"]
    let kind = kinds[r.nextInt(kinds.count)]
    let titles = ["Home", "C# Guide", "آرامی", "🦀 Rust Notes", "Page With Spaces"]
    let title = titles[r.nextInt(titles.count)]
    switch r.nextInt(8) {
    case 0: return "[[\(kind):\(ulid)|\(title)]]"
    case 1: return "[[\(kind):\(title)]]"
    case 2: return "[[\(kind):\(ulid)]]"
    case 3: return "[[\(title)|\(title) alias]]"
    case 4: return "![[source:\(ulid)|embed]]"
    case 5: return "[[\(kind):\(title)#\(title)]]"
    case 6: return "[[\(kind):\(ulid)@v\(r.nextRange(1, 9))]]"
    default: return "[[\(kind):\(title)#\"\(title)\"@v3]]"
    }
}

func malformedWiki(_ r: inout FuzzRNG) -> String {
    let fragments = ["[[unclosed", "unopened]]", "[[ ]]", "[[ ]| ]]", "[[|]]",
                     "[[X|]]", "[[source:]]", "[[page:   ]]", "[[chat:]]",
                     "[[}", "[[}]]", "[[X][Y]]", "[[X] ]", "[[ X", "X]]", "[[X",
                     "[[\n]]", "[[\t]]", "[[\u{0}]]", "[[\u{1B}X]]"]
    return fragments[r.nextInt(fragments.count)]
}

func nestedWiki(_ r: inout FuzzRNG) -> String {
    let inner = wellFormedWiki(&r)
    let outer = wellFormedWiki(&r)
    let pick = r.nextInt(4)
    switch pick {
    case 0: return "text \(inner) more \(outer) end"
    case 1: return "[[a \(inner) c]]"
    case 2: return "[[\(inner)|\(outer)]]"
    default: return "\(inner)\(outer)\(inner)"
    }
}

func pipeBombWiki(_ r: inout FuzzRNG) -> String {
    let n = r.nextRange(3, 40)
    let pipes = String(repeating: "|", count: n)
    let pick = r.nextInt(5)
    switch pick {
    case 0: return "[[\(pipes)]]"
    case 1: return "[[X\(pipes)Y]]"
    case 2: return "[[X\(pipes)]]"
    case 3: return "[[\(pipes)Y]]"
    default: return "[[|\(pipes)|]]X"
    }
}

func unicodeWiki(_ r: inout FuzzRNG) -> String {
    let kind = ["page:", "source:", "chat:"][r.nextInt(3)]
    let length = r.nextRange(1, 30)
    return "[[\(kind)\(randomULID(&r))|\(randomUnicode(&r, length: length))]]"
}

func veryLongWiki(_ r: inout FuzzRNG) -> String {
    let chars: [Character] = ["a", "b", "c", " ", "|", "#", "[", "]", "1"]
    return "[[\(veryLong(&r, chars: chars))]]"
}

func tokenSoup(_ r: inout FuzzRNG, tokens: [String]) -> String {
    let n = r.nextRange(1, 60)
    var s = ""
    for _ in 0..<n { s += tokens[r.nextInt(tokens.count)] }
    return s
}

// --- markdown generators ---

func genMarkdown(_ r: inout FuzzRNG) -> String {
    let pick = r.nextInt(7)
    switch pick {
    case 0: return mixedMarkdown(&r)
    case 1: return footnoteMarkdown(&r)
    case 2: return deeplyNestedMarkdown(&r)
    case 3: return tokenSoup(&r, tokens: mdTokens)
    case 4: return veryLongMarkdown(&r)
    case 5: return ""
    default: return String(specialChars[r.nextInt(specialChars.count)])
    }
}

func mixedMarkdown(_ r: inout FuzzRNG) -> String {
    var s = ""
    let n = r.nextRange(1, 20)
    for _ in 0..<n {
        let pick = r.nextInt(9)
        switch pick {
        case 0: s += "# Header \(r.nextRange(1, 99))\n\n"
        case 1: s += "This is **bold** and *italic* and `code`.\n\n"
        case 2: s += "```\ncode block\n```\n\n"
        case 3: s += "- [x] task\n- [ ] task\n"
        case 4: s += "> quoted text\n> more\n\n"
        case 5: s += "[^id]: footnote body \(r.nextRange(1, 99))\n"
        case 6: s += "[^id]\n"
        case 7: s += wellFormedWiki(&r) + " in markdown\n"
        default: s += "| col1 | col2 |\n|---|---|\n| a | b |\n\n"
        }
    }
    return s
}

func footnoteMarkdown(_ r: inout FuzzRNG) -> String {
    var s = ""
    let nRefs = r.nextRange(0, 5)
    for i in 0..<nRefs {
        s += "Body[^id\(i)] text[^id\(i)].\n\n"
    }
    for i in 0..<nRefs {
        s += "[^id\(i)]: footnote \(i) body"
        if r.nextBool() { s += " with [^other] ref" }
        s += "\n"
    }
    return s
}

func deeplyNestedMarkdown(_ r: inout FuzzRNG) -> String {
    let depth = r.nextRange(20, 80)
    let pick = r.nextInt(3)
    switch pick {
    case 0: return String(repeating: ">", count: depth) + " nested\n"
    case 1: return String(repeating: "  ", count: depth) + "- leaf\n"
    default: return String(repeating: "*", count: depth) + "ital*"
    }
}

func veryLongMarkdown(_ r: inout FuzzRNG) -> String {
    let chars: [Character] = ["a", "b", " ", "#", "*", "`", "\n", "[", "]", "-", "|"]
    return veryLong(&r, chars: chars)
}

// --- HTML generators ---

func genHtml(_ r: inout FuzzRNG) -> String {
    let pick = r.nextInt(6)
    switch pick {
    case 0: return wellFormedHtml(&r)
    case 1: return malformedHtml(&r)
    case 2: return deeplyNestedHtml(&r)
    case 3: return tokenSoup(&r, tokens: htmlTokens)
    case 4: return veryLongHtml(&r)
    default: return ""
    }
}

func wellFormedHtml(_ r: inout FuzzRNG) -> String {
    var s = ""
    let n = r.nextRange(1, 15)
    for _ in 0..<n {
        let pick = r.nextInt(11)
        switch pick {
        case 0: s += "<p>paragraph \(r.nextRange(1, 99))</p>"
        case 1: s += "<a href=\"https://ex.com/\(r.nextRange(1, 999))\">link</a>"
        case 2: s += "<strong>bold</strong>"
        case 3: s += "<em>italic</em>"
        case 4: s += "<code>inline</code>"
        case 5: s += "<pre><code>block multi</code></pre>"
        case 6: let h = r.nextRange(1, 6); s += "<h\(h)>heading</h\(h)>"
        case 7: s += "<ul><li>item 1</li><li>item 2</li></ul>"
        case 8: s += "<blockquote>quote</blockquote>"
        case 9: s += "<img src=\"img.png\" alt=\"alt\">"
        default: s += "<title>Document Title \(r.nextRange(1, 99))</title>"
        }
    }
    return s
}

func malformedHtml(_ r: inout FuzzRNG) -> String {
    let fragments = ["<p>unclosed", "</p> lone", "<a href=\"missing-close",
                     "<strong>", "<", ">", "</", "<>", "<p><div></p></div>",
                     "<script>", "&amp;", "&#0;", "&#xFFFFFFFF;", "&",
                     "<a href=>", "<div class=", "<x<!--",
                     "<!-- unclosed comment", "<p>\u{0}</p>", "<!DOCTYPE"]
    return fragments[r.nextInt(fragments.count)]
}

func deeplyNestedHtml(_ r: inout FuzzRNG) -> String {
    let depth = r.nextRange(20, 100)
    var s = ""
    for _ in 0..<depth { s += "<div>" }
    s += "deep"
    for _ in 0..<depth { s += "</div>" }
    return s
}

func veryLongHtml(_ r: inout FuzzRNG) -> String {
    let chars: [Character] = ["a", "<", ">", "/", "p", " ", "\"", "=", "&", "1"]
    return veryLong(&r, chars: chars)
}

// --- bare target generators ---

func genBareTarget(_ r: inout FuzzRNG) -> String {
    let pick = r.nextInt(14)
    switch pick {
    case 0: return randomULID(&r)
    case 1: return randomString(&r, length: r.nextRange(0, 30))
    case 2: return "#" + randomString(&r, length: r.nextRange(0, 20))
    case 3: return randomString(&r, length: 15) + "#\"quote\""
    case 4: return randomString(&r, length: 15) + "@v\(r.nextRange(1, 9))"
    case 5: return "@v"
    case 6: return "@x3"
    case 7: return "page:"
    case 8: return "source:"
    case 9: return "chat:"
    case 10: return "page:" + randomULID(&r)
    case 11: return "source:" + randomString(&r, length: 15) + "#\"" + randomString(&r, length: 10) + "\""
    case 12: return veryLongBare(&r)
    default: return ""
    }
}

func veryLongBare(_ r: inout FuzzRNG) -> String {
    let chars: [Character] = ["a", "b", " ", "#", "@", "v", "1", "p", "g", "e"]
    return veryLong(&r, chars: chars)
}

// --- raw special char generators ---

func genRawSpecial(_ r: inout FuzzRNG) -> String {
    let pick = r.nextInt(15)
    switch pick {
    case 0: return ""
    case 1: return " "
    case 2: return "\t"
    case 3: return "\n"
    case 4: return "\r"
    case 5: return "\u{2028}"
    case 6: return "\u{0}"
    case 7: return String(repeating: "\u{0}", count: r.nextRange(1, 100))
    case 8: return String(repeating: "[", count: r.nextRange(1, 1000))
    case 9: return String(repeating: "]", count: r.nextRange(1, 1000))
    case 10: return String(repeating: "|", count: r.nextRange(1, 1000))
    case 11: return String(repeating: "#", count: r.nextRange(1, 1000))
    case 12: return String(repeating: "\"", count: r.nextRange(1, 1000))
    case 13: return String(specialChars[r.nextInt(specialChars.count)])
    default: return veryLongBare(&r)
    }
}

// MARK: - Dispatch: feed each input to the appropriate parsers

func logLine(_ input: FuzzInput, _ iter: Int, _ seed: UInt64, _ parser: String) {
    let line = "seed=\(seed) iter=\(iter) kind=\(input.kind) parser=\(parser) b64=\(input.base64)\n"
    FileHandle.standardOutput.write(Data(line.utf8))
}

func runParser(_ input: FuzzInput, _ iter: Int, _ seed: UInt64, _ name: String,
               _ body: () throws -> Void) {
    logLine(input, iter, seed, name)
    do { try body() }
    catch { /* expected — fuzzer feeds malformed input; throwing is fine */ }
}

func fuzzOne(_ input: FuzzInput, _ iter: Int, _ seed: UInt64, _ r: inout FuzzRNG,
             _ linter: MarkdownLinter?) {
    let text = input.text
    switch input.kind {
    case .wikiLink:
        runParser(input, iter, seed, "WikiLinkParser.parse") { _ = WikiLinkParser.parse(text) }
        runParser(input, iter, seed, "WikiLinkParser.classify") { _ = WikiLinkParser.classify(text) }
        runParser(input, iter, seed, "WikiLinkParser.splitFragment") { _ = WikiLinkParser.splitFragment(text) }
        runParser(input, iter, seed, "WikiLinkParser.splitVersionPin") { _ = WikiLinkParser.splitVersionPin(text) }
        runParser(input, iter, seed, "WikiLinkParser.isCanonicalULID") { _ = WikiLinkParser.isCanonicalULID(text) }
        runParser(input, iter, seed, "WikiLinkParser.isEmptyPrefix") { _ = WikiLinkParser.isEmptyPrefix(text) }
        runParser(input, iter, seed, "WikiText.normalized") { _ = WikiText.normalized(text) }
        fuzzScanner(input, iter, seed, r: &r)
        fuzzResolver(input, iter, seed, r: &r)
        fuzzRewriter(input, iter, seed, r: &r)
        fuzzDroppedLinkFormatter(input, iter, seed, r: &r)

    case .markdown:
        runParser(input, iter, seed, "WikiLinkParser.parse(md)") { _ = WikiLinkParser.parse(text) }
        runParser(input, iter, seed, "WikiText.normalized(md)") { _ = WikiText.normalized(text) }
        runParser(input, iter, seed, "WikiFootnoteMarkdown.rendered") { _ = WikiFootnoteMarkdown.rendered(text) }
        runParser(input, iter, seed, "WikiFootnoteMarkdown.footnoteAnchorID") {
            _ = WikiFootnoteMarkdown.footnoteAnchorID(for: String(text.prefix(40)))
        }
        if let linter {
            runParser(input, iter, seed, "MarkdownLinter.lint") { _ = linter.lint(markdown: text) }
            runParser(input, iter, seed, "MarkdownLinter.fix") { _ = linter.fix(markdown: text) }
        }

    case .html:
        runParser(input, iter, seed, "HTMLToMarkdown.convert") { _ = HTMLToMarkdown.convert(text) }
        runParser(input, iter, seed, "HTMLToMarkdown.markdown(from:)") { _ = HTMLToMarkdown.markdown(from: text) }
        runParser(input, iter, seed, "HTMLToMarkdown.titleOnly") { _ = HTMLToMarkdown.titleOnly(from: text) }
        runParser(input, iter, seed, "HTMLToMarkdown.scopedTokens+render") {
            let tokens = HTMLToMarkdown.scopedTokens(for: text)
            _ = HTMLToMarkdown.markdown(fromScopedTokens: tokens)
        }

    case .bareTarget:
        runParser(input, iter, seed, "WikiLinkParser.classify(bare)") { _ = WikiLinkParser.classify(text) }
        runParser(input, iter, seed, "WikiLinkParser.splitFragment(bare)") { _ = WikiLinkParser.splitFragment(text) }
        runParser(input, iter, seed, "WikiLinkParser.splitVersionPin(bare)") { _ = WikiLinkParser.splitVersionPin(text) }
        runParser(input, iter, seed, "WikiLinkParser.isCanonicalULID(bare)") { _ = WikiLinkParser.isCanonicalULID(text) }
        runParser(input, iter, seed, "WikiLinkParser.isEmptyPrefix(bare)") { _ = WikiLinkParser.isEmptyPrefix(text) }
        runParser(input, iter, seed, "WikiText.normalized(bare)") { _ = WikiText.normalized(text) }
        runParser(input, iter, seed, "WikiLinkResolver.candidateSplits") { _ = WikiLinkResolver.candidateSplits(of: text) }
        fuzzResolver(input, iter, seed, r: &r)

    case .rawSpecial:
        runParser(input, iter, seed, "WikiText.normalized(raw)") { _ = WikiText.normalized(text) }
        runParser(input, iter, seed, "WikiLinkParser.parse(raw)") { _ = WikiLinkParser.parse(text) }
        runParser(input, iter, seed, "HTMLToMarkdown.convert(raw)") { _ = HTMLToMarkdown.convert(text) }
        runParser(input, iter, seed, "WikiFootnoteMarkdown.rendered(raw)") { _ = WikiFootnoteMarkdown.rendered(text) }
        runParser(input, iter, seed, "WikiFootnoteMarkdown.footnoteAnchorID(raw)") {
            _ = WikiFootnoteMarkdown.footnoteAnchorID(for: String(text.prefix(40)))
        }
    }
}

func fuzzScanner(_ input: FuzzInput, _ iter: Int, _ seed: UInt64, r: inout FuzzRNG) {
    let text = input.text
    let caret = text.isEmpty ? 0 : r.nextRange(0, text.count)
    runParser(input, iter, seed, "WikiLinkPrefixScanner.openLink") {
        _ = WikiLinkPrefixScanner.openLink(at: caret, in: text)
    }
}

func fuzzResolver(_ input: FuzzInput, _ iter: Int, _ seed: UInt64, r: inout FuzzRNG) {
    let text = input.text
    runParser(input, iter, seed, "WikiLinkResolver.resolvedSplit") {
        let isKnown: (String) throws -> Bool = { _ in r.nextBool() }
        _ = try WikiLinkResolver.resolvedSplit(of: text, isKnown: isKnown)
    }
}

func fuzzRewriter(_ input: FuzzInput, _ iter: Int, _ seed: UInt64, r: inout FuzzRNG) {
    let text = input.text
    runParser(input, iter, seed, "WikiLinkRewriter.canonicalize") {
        let resolve: (String) throws -> PageID? = { s in
            if s.isEmpty || r.nextInt(4) == 0 { return nil }
            return PageID(rawValue: randomULID(&r))
        }
        _ = try WikiLinkRewriter.canonicalize(
            in: text, resolvePage: resolve, resolveSource: resolve, resolveChat: resolve)
    }
}

func fuzzDroppedLinkFormatter(_ input: FuzzInput, _ iter: Int, _ seed: UInt64, r: inout FuzzRNG) {
    let text = input.text
    let kinds = ParsedLink.LinkType.allCases
    let count = r.nextRange(0, 5)
    var items: [DroppedLinkFormatter.Item] = []
    for _ in 0..<count {
        let kind = kinds[r.nextInt(kinds.count)]
        let depth = r.nextRange(0, 3)
        let display: String? = r.nextBool() ? text : nil
        items.append(DroppedLinkFormatter.Item(
            depth: depth, linkType: kind, id: randomULID(&r), displayName: display))
    }
    runParser(input, iter, seed, "DroppedLinkFormatter.link") {
        let kind = kinds[r.nextInt(kinds.count)]
        _ = DroppedLinkFormatter.link(for: kind, id: text, displayName: text)
    }
    runParser(input, iter, seed, "DroppedLinkFormatter.markdownList(for:)") {
        _ = DroppedLinkFormatter.markdownList(for: items)
    }
    runParser(input, iter, seed, "DroppedLinkFormatter.markdownList(forTuples:)") {
        let tuples = items.map { ($0.depth, $0.linkType, $0.id, $0.displayName) }
        _ = DroppedLinkFormatter.markdownList(forTuples: tuples)
    }
}

// MARK: - Driver

func runFuzz() {
    let args = Array(CommandLine.arguments.dropFirst())
    let seed: UInt64 = args.first.flatMap { UInt64($0) } ?? UInt64(Date().timeIntervalSince1970)

    let maxIters: Int
    if args.count >= 2, let n = Int(args[1]) { maxIters = n } else { maxIters = Int.max }

    let linter: MarkdownLinter? = MarkdownLinter.shared
    if linter == nil {
        FileHandle.standardOutput.write(Data(
            "FuzzHarness: MarkdownLinter.shared is nil — lint/fix targets skipped\n".utf8))
    }

    FileHandle.standardOutput.write(Data(
        "FuzzHarness seed=\(seed) maxIters=\(maxIters == Int.max ? "unbounded" : "\(maxIters)")\n".utf8))

    var r = FuzzRNG(seed: seed)
    var i = 0
    while i < maxIters {
        let kind = FuzzKind.allCases[r.nextInt(FuzzKind.allCases.count)]
        let text: String
        switch kind {
        case .wikiLink:   text = genWikiLink(&r)
        case .markdown:   text = genMarkdown(&r)
        case .html:       text = genHtml(&r)
        case .bareTarget: text = genBareTarget(&r)
        case .rawSpecial: text = genRawSpecial(&r)
        }
        let input = FuzzInput(kind: kind, text: text)
        fuzzOne(input, i, seed, &r, linter)

        if i > 0 && i % 10_000 == 0 {
            FileHandle.standardOutput.write(Data("progress iter=\(i)\n".utf8))
        }
        i &+= 1
    }

    FileHandle.standardOutput.write(Data(
        "FuzzHarness: completed \(i) iterations, seed=\(seed)\n".utf8))
}

runFuzz()
