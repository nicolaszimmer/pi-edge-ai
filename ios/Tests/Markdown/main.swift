// Tests for Markdown.swift: blocks, inline maths and the LaTeX clean-up.
// Run with ios/Tests/run.sh.
import Foundation

func dump(_ blocks: [MarkdownBlock], _ depth: Int = 0) {
    let pad = String(repeating: "  ", count: depth)
    for b in blocks {
        switch b {
        case .heading(let l, let t): print("\(pad)H\(l): \(t)")
        case .paragraph(let t): print("\(pad)P: \(t.debugDescription)")
        case .math(let m): print("\(pad)MATH: \(m.debugDescription) -> \(LaTeX.prepare(m).debugDescription)")
        case .code(let lang, let t): print("\(pad)CODE[\(lang)]: \(t.debugDescription)")
        case .quote(let bs): print("\(pad)QUOTE"); dump(bs, depth + 1)
        case .list(let l):
            print("\(pad)LIST ordered=\(l.ordered) start=\(l.start)")
            for (i, item) in l.items.enumerated() { print("\(pad) item \(i)"); dump(item, depth + 2) }
        case .table(let t): print("\(pad)TABLE \(t.header) \(t.alignments) \(t.rows)")
        case .rule: print("\(pad)RULE")
        }
    }
}

var failures = 0
func check(_ cond: Bool, _ msg: String, line: Int = #line) {
    if !cond { failures += 1; print("FAIL line \(line): \(msg)") }
}
func spans(_ s: String) -> [String] { InlineMath.extract(s).spans.map { ($0.display ? "D:" : "") + $0.latex } }

let example = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let blocks = Markdown.parse(example)
if CommandLine.arguments.contains("-v") { dump(blocks) }

// Example structure
check(blocks.first == .paragraph("Gerne erkläre ich dir den **Satz des Pythagoras**! Er ist einer der bekanntesten und wichtigsten Sätze in der gesamten Mathematik, besonders in der Geometrie."), "first paragraph")
check(blocks[1] == .rule, "rule")
check(blocks[2] == .heading(level: 2, text: "📐 Was ist der Satz des Pythagoras?"), "h2")
check(blocks.contains(.heading(level: 3, text: "1. Was ist ein rechtwinkliges Dreieck?")), "h3 with number is a heading, not a list")
check(blocks.contains(.math("\\Huge a^2 + b^2 = c^2")), "display math")
check(LaTeX.prepare("\\Huge a^2 + b^2 = c^2") == "a^2 + b^2 = c^2", "Huge stripped")
let lists = blocks.compactMap { if case .list(let l) = $0 { return l } else { return nil } }
check(lists.count == 5, "five lists, got \(lists.count)")
if lists.count == 5 {
    check(!lists[0].ordered && lists[0].items.count == 2, "katheten list")
    check(lists[0].items[0] == [.paragraph("**Katheten ($a$ und $b$):** Das sind die beiden Seiten, die den rechten Winkel bilden. Sie werden oft als die \"normalen\" Beine des Dreiecks bezeichnet.")], "katheten item")
    check(lists[2].items == [[.paragraph("$a = 3$ cm")], [.paragraph("$b = 4$ cm")]], "a b list after paragraph line")
    let steps = lists[3]
    check(steps.ordered && steps.start == 1 && steps.items.count == 4, "steps list one list of 4")
    check(steps.items[0] == [.paragraph("**Setze die Werte in die Formel ein:**"), .math("3^2 + 4^2 = c^2")], "step 1 has math inside")
    check(steps.items[3] == [.paragraph("**Finde die Wurzel, um $c$ zu erhalten:**\nUm $c$ zu finden, musst du die Quadratwurzel aus 25 ziehen ($\\sqrt{25}$):"), .math("c = 5 \\text{ cm}")], "step 4")
    check(lists[4].ordered && lists[4].items.count == 2, "applications list")
}
check(blocks.contains(.paragraph("*(Ein \"Quadrat\" der Länge bedeutet, dass man die Länge mit sich selbst multipliziert, z.B. $3^2 = 3 \\times 3 = 9$)*")), "italic paragraph not a list")
check(blocks.contains(.paragraph("Die Hypotenuse ist also 5 cm lang.")), "paragraph after list")

// Inline maths
check(spans("**Katheten ($a$ und $b$):**") == ["a", "b"], "katheten spans")
check(InlineMath.extract("**Katheten ($a$ und $b$):**").text == "**Katheten (\u{E000} und \u{E001}):**", "placeholders")
check(spans("($\\text{90}^\\circ$)") == ["\\text{90}^\\circ"], "degree")
check(spans("costs $5 and $10 today") == [], "prices stay text")
check(spans("from $5 to $10") == [], "prices 2")
check(spans("$x$5") == [], "digit after closing")
check(spans("use `$HOME` and $x$") == ["x"], "code span untouched")
check(spans("\\(a+b\\) and \\[c\\]") == ["a+b", "D:c"], "paren and bracket")
check(spans("then $$x^2$$ inline") == ["D:x^2"], "inline display")
check(spans("escaped \\$5 and $y$") == ["y"], "escaped dollar")
check(spans("$ \\frac{1}{2} $") == ["\\frac{1}{2}"], "padded but LaTeX")
check(spans("$ 5 $") == [], "padded plain")
check(spans("a $b\nc$ d") == [], "no line break inside $")
check(spans("$\\$5$") == ["\\$5"], "escaped dollar inside")
check(spans("Der Preis: 5$ und 10$.") == [], "trailing dollar signs")

// LaTeX clean-up
check(LaTeX.prepare("\\dfrac{a}{b}") == "\\frac{a}{b}", "dfrac: \(LaTeX.prepare("\\dfrac{a}{b}"))")
check(LaTeX.prepare("\\ddots \\dots \\ldots") == "\\ddots \\ldots \\ldots", "dots: \(LaTeX.prepare("\\ddots \\dots \\ldots"))")
check(LaTeX.prepare("90°") == "90^{\\circ}", "degree sign")
check(LaTeX.prepare("a × b ≤ c") == "a \\times  b \\leq  c", "unicode: \(LaTeX.prepare("a × b ≤ c"))")
check(LaTeX.prepare("f'(x) + f''(x)") == "f^{\\prime}(x) + f^{\\prime\\prime}(x)", "primes: \(LaTeX.prepare("f'(x) + f''(x)"))")
check(LaTeX.prepare("\\begin{align*} a &= b \\\\ c &= d \\end{align*}") == "\\begin{aligned} a &= b \\\\ c &= d \\end{aligned}", "align")
check(LaTeX.prepare("\\begin{equation} x = 1 \\end{equation}") == "x = 1", "equation")
check(LaTeX.prepare("\\begin{array}{cc} 1 & 2 \\end{array}") == "\\begin{matrix} 1 & 2 \\end{matrix}", "array: \(LaTeX.prepare("\\begin{array}{cc} 1 & 2 \\end{array}"))")
check(LaTeX.prepare("\\begin{alignat}{2} a &= b \\end{alignat}") == "\\begin{aligned} a &= b \\end{aligned}", "alignat: \(LaTeX.prepare("\\begin{alignat}{2} a &= b \\end{alignat}"))")
check(LaTeX.prepare("\\boxed{x=2}") == "{x=2}", "boxed")
check(LaTeX.prepare("\\operatorname{sgn}(x)") == "\\mathrm{sgn}(x)", "operatorname")
check(LaTeX.prepare("\\overset{!}{=}") == "{=}^{!}", "overset: \(LaTeX.prepare("\\overset{!}{=}"))")
check(LaTeX.prepare("\\overset{a}{\\overset{b}{c}}") == "{{c}^{b}}^{a}", "nested overset: \(LaTeX.prepare("\\overset{a}{\\overset{b}{c}}"))")
check(LaTeX.prepare("x \\in \\R, \\Re z") == "x \\in \\mathbb{R}, \\Re z", "R: \(LaTeX.prepare("x \\in \\R, \\Re z"))")
check(LaTeX.prepare("a \\pmod{5}") == "a \\ (\\mathrm{mod}\\ 5)", "pmod: \(LaTeX.prepare("a \\pmod{5}"))")
check(LaTeX.prepare("\\left( \\bigl( x \\bigr) \\right)") == "\\left( ( x ) \\right)", "big: \(LaTeX.prepare("\\left( \\bigl( x \\bigr) \\right)"))")
check(LaTeX.prepare("\\bigcup_i A_i") == "\\bigcup_i A_i", "bigcup kept")
check(LaTeX.prepare("a \\\\[4pt] b") == "a \\\\ b", "row break spacing: \(LaTeX.prepare("a \\\\[4pt] b"))")
check(LaTeX.prepare("x \\tag{1}") == "x", "tag")
check(LaTeX.prepare("a \\implies b") == "a \\Rightarrow b", "implies")
check(LaTeX.prepare("a \\xrightarrow{f} b") == "a \\rightarrow^{f} b", "xrightarrow")
check(LaTeX.prepare("a\\:b") == "a\\>b", "colon space")
check(LaTeX.prepare("\\text{Fläche} = 5 \\text{ cm}") == "\\text{Fläche} = 5 \\text{ cm}", "umlaut and text spaces kept")

// Blocks: other forms
func p(_ s: String) -> [MarkdownBlock] { Markdown.parse(s) }
check(p("```swift\nlet x = 1\n```\nafter") == [.code(language: "swift", text: "let x = 1"), .paragraph("after")], "fence")
check(p("```\nopen") == [.code(language: "", text: "open")], "open fence while streaming")
check(p("$$\na^2\n= b\n$$\ntext") == [.math("a^2\n= b"), .paragraph("text")], "multi-line $$")
check(p("\\[\nx\n\\]") == [.math("x")], "bracket display")
check(p("$$\na^2") == [.math("a^2")], "open $$ while streaming")
check(p("\\begin{align}\na &= b\n\\end{align}") == [.math("\\begin{align}\na &= b\n\\end{align}")], "bare align")
check(p("| a | b |\n|:--|--:|\n| $|x|$ | 2 |\n| $5 | $10 |") == [.table(MarkdownTable(header: ["a", "b"], alignments: [.leading, .trailing], rows: [["$|x|$", "2"], ["$5", "$10"]]))], "table: \(p("| a | b |\n|:--|--:|\n| $|x|$ | 2 |\n| $5 | $10 |"))")
check(p("Text\n| a |\n|---|\n| 1 |") == [.paragraph("Text"), .table(MarkdownTable(header: ["a"], alignments: [.leading], rows: [["1"]]))], "table after paragraph")
check(p("Text\n---") == [.paragraph("Text"), .rule], "rule after text")
check(p("> quote\n> more\n\nafter") == [.quote([.paragraph("quote\nmore")]), .paragraph("after")], "quote")
check(p("- a\n  - b\n  - c\n- d") == [.list(MarkdownList(ordered: false, start: 1, items: [[.paragraph("a"), .list(MarkdownList(ordered: false, start: 1, items: [[.paragraph("b")], [.paragraph("c")]]))], [.paragraph("d")]]))], "nested: \(p("- a\n  - b\n  - c\n- d"))")
check(p("1. a\n   - b\n2. c") == [.list(MarkdownList(ordered: true, start: 1, items: [[.paragraph("a"), .list(MarkdownList(ordered: false, start: 1, items: [[.paragraph("b")]]))], [.paragraph("c")]]))], "ordered with nested bullets")
check(p("1. a\n\n2. b\n\n3. c") == [.list(MarkdownList(ordered: true, start: 1, items: [[.paragraph("a")], [.paragraph("b")], [.paragraph("c")]]))], "loose list")
check(p("3. three\n4. four") == [.list(MarkdownList(ordered: true, start: 3, items: [[.paragraph("three")], [.paragraph("four")]]))], "start number")
check(p("- a\nlazy\n\nnext") == [.list(MarkdownList(ordered: false, start: 1, items: [[.paragraph("a\nlazy")]])), .paragraph("next")], "lazy continuation")
check(p("- a\n1. b") == [.list(MarkdownList(ordered: false, start: 1, items: [[.paragraph("a")]])), .list(MarkdownList(ordered: true, start: 1, items: [[.paragraph("b")]]))], "kind change")
check(p("**bold** start") == [.paragraph("**bold** start")], "bold is not a list")
check(p("* * *") == [.rule], "star rule")
check(p("#hashtag") == [.paragraph("#hashtag")], "not a heading")
check(p("## Title ##") == [.heading(level: 2, text: "Title")], "closing hashes")
check(p("-") == [.list(MarkdownList(ordered: false, start: 1, items: [[]]))], "lone dash while streaming")
check(p("") == [], "empty")
check(p("a\r\nb") == [.paragraph("a\nb")], "CRLF")
check(p("\tcode-ish tab line") == [.paragraph("code-ish tab line")], "tab indent")

// Review round 2
check(Markdown.cells("| ``a|b`` | c |") == ["``a|b``", "c"], "double backtick span: \(Markdown.cells("| ``a|b`` | c |"))")
check(Markdown.cells("| $\\|v\\|$ | x |") == ["$\\|v\\|$", "x"], "norm in cell: \(Markdown.cells("| $\\|v\\|$ | x |"))")
check(Markdown.cells("| a \\| b | c |") == ["a | b", "c"], "escaped pipe")
check(Markdown.cells("| `x | y |") == ["`x", "y"], "unclosed backtick does not swallow the row")
check(p("Im Jahr\n2024. war ein gutes Jahr") == [.paragraph("Im Jahr\n2024. war ein gutes Jahr")], "only 1. interrupts")
check(p("Schritte:\n1. a\n2. b") == [.paragraph("Schritte:"), .list(MarkdownList(ordered: true, start: 1, items: [[.paragraph("a")], [.paragraph("b")]]))], "1. interrupts")
check(p("Text\n- a") == [.paragraph("Text"), .list(MarkdownList(ordered: false, start: 1, items: [[.paragraph("a")]]))], "bullet interrupts")
let t0 = Date()
let deepQuote = Markdown.parse(String(repeating: ">", count: 100_000) + " deep")
let deepList = Markdown.parse((0..<200).map { String(repeating: "  ", count: $0) + "- level \($0)" }.joined(separator: "\n"))
check(Date().timeIntervalSince(t0) < 5, "deep nesting fast: \(Date().timeIntervalSince(t0))s")
func depthOf(_ blocks: [MarkdownBlock]) -> Int {
    blocks.map { b -> Int in
        switch b {
        case .quote(let bs): return 1 + depthOf(bs)
        case .list(let l): return 1 + (l.items.map(depthOf).max() ?? 0)
        default: return 0
        }
    }.max() ?? 0
}
check(depthOf(deepQuote) == Markdown.maxDepth, "quote depth capped: \(depthOf(deepQuote))")
check(depthOf(deepList) <= Markdown.maxDepth, "list depth capped: \(depthOf(deepList))")
// Review round 3
check(LaTeX.prepare("a \\pmod{b^{2}}") == "a \\ (\\mathrm{mod}\\ b^{2})", "pmod nested: \(LaTeX.prepare("a \\pmod{b^{2}}"))")
check(LaTeX.prepare("\\xrightarrow{f^{-1}}") == "\\rightarrow^{f^{-1}}", "xrightarrow nested: \(LaTeX.prepare("\\xrightarrow{f^{-1}}"))")
check(LaTeX.prepare("\\pmodx") == "\\pmodx", "longer name untouched")
check(p("| a |\n|---|\n| 1 | 2 | 3 |\n| |") == [.table(MarkdownTable(header: ["a"], alignments: [.leading], rows: [["1"], [""]]))], "ragged rows cut to the header: \(p("| a |\n|---|\n| 1 | 2 | 3 |\n| |"))")
check(p("| a | b | c |\n|---|\n| 1 |") == [.table(MarkdownTable(header: ["a", "b", "c"], alignments: [.leading, .leading, .leading], rows: [["1", "", ""]]))], "short delimiter row padded")

// Every prefix of the answer, as it arrives token by token: no hang, no crash.
let started = Date()
let chars = Array(example)
for n in 0...chars.count {
    for b in Markdown.parse(String(chars[0..<n])) {
        if case .paragraph(let t) = b { _ = InlineMath.extract(t) }
        if case .math(let m) = b { _ = LaTeX.prepare(m) }
    }
}
for e in ["$", "$$", "\\[", "\\(", "`", "```", "|", "|-", "| a |\n|-", "1.", "1)", "-", "*", "> ", "#",
          "\\begin{align}", "$\\", "\\", "$a\\", "\\overset{", "\\overset{a}{", "\\pmod{", "**$x", "~~~"] {
    _ = Markdown.parse(e)
    _ = InlineMath.extract(e)
    _ = LaTeX.prepare(e)
}
print(String(format: "Streaming: %d prefixes parsed in %.2f s", chars.count + 1, Date().timeIntervalSince(started)))

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
