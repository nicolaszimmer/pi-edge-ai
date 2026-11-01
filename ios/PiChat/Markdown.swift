import Foundation

// Reads the Markdown that language models write into blocks the chat can draw:
// headings, paragraphs, lists, quotes, code, tables, rules and LaTeX maths
// ($…$ and \(…\) inline, $$…$$ and \[…\] on their own lines). It is forgiving
// on purpose: answers arrive token by token, so every half-written state has
// to read sensibly too. Plain Foundation, so it can be tested without a phone.

indirect enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// Display maths, the LaTeX without its delimiters.
    case math(String)
    case code(language: String, text: String)
    case quote([MarkdownBlock])
    case list(MarkdownList)
    case table(MarkdownTable)
    case rule
}

struct MarkdownList: Equatable {
    var ordered: Bool
    var start: Int
    var items: [[MarkdownBlock]]
}

struct MarkdownTable: Equatable {
    enum Alignment: Equatable { case leading, center, trailing }

    var header: [String]
    var alignments: [Alignment]
    var rows: [[String]]
}

enum Markdown {
    static func parse(_ text: String) -> [MarkdownBlock] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return blocks(normalized.components(separatedBy: "\n").map(Line.init))
    }

    // MARK: Lines

    struct Line {
        /// Columns of leading white space, a tab counting as four.
        let indent: Int
        /// The line after its leading white space.
        let content: String

        init(_ raw: String) {
            var columns = 0
            var start = raw.startIndex
            for ch in raw {
                if ch == " " { columns += 1 } else if ch == "\t" { columns += 4 - columns % 4 } else { break }
                start = raw.index(after: start)
            }
            indent = columns
            content = String(raw[start...])
        }

        var isBlank: Bool { content.allSatisfy(\.isWhitespace) }
        var trimmed: String { content.trimmingCharacters(in: .whitespaces) }

        /// The line with up to `columns` columns of its indentation taken off.
        func dedented(by columns: Int) -> String {
            String(repeating: " ", count: max(0, indent - columns)) + content
        }
    }

    // MARK: Blocks

    /// How deep quotes and lists may nest. Deeper markers are read as text, so
    /// a line of a thousand ">" cannot recurse a thousand times.
    static let maxDepth = 12

    static func blocks(_ lines: [Line], depth: Int = 0) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var i = 0
        while i < lines.count {
            if lines[i].isBlank {
                i += 1
                continue
            }
            let (block, next) = readBlock(lines, i, depth: depth)
            result.append(block)
            i = max(next, i + 1)
        }
        return result
    }

    /// The block that starts at line `i`, and the line after it. The readers
    /// are tried in order (one at a time, not as a chain of ??, which makes
    /// the compiler take minutes).
    private static func readBlock(_ lines: [Line], _ i: Int, depth: Int) -> (MarkdownBlock, Int) {
        let readers: [([Line], Int) -> (MarkdownBlock, Int)?] = [
            fence, displayMath, mathEnvironment, heading, rule, table,
        ]
        for read in readers {
            if let found = read(lines, i) { return found }
        }
        if depth < maxDepth {
            if let found = quote(lines, i, depth: depth) { return found }
            if let found = list(lines, i, depth: depth) { return found }
        }
        return paragraph(lines, i)
    }

    /// Whether line `i` begins a block that ends the paragraph before it.
    private static func interrupts(_ lines: [Line], _ i: Int) -> Bool {
        let line = lines[i]
        let t = line.trimmed
        if isFence(line) || isRule(line) || isTableStart(lines, i) { return true }
        if t.hasPrefix("$$") || t.hasPrefix("\\[") { return true }
        if line.indent < 4 && t.hasPrefix(">") { return true }
        if environmentName(t) != nil || headingLevel(line) != nil { return true }
        // As in CommonMark, only a list that starts at 1 interrupts a paragraph,
        // so a line like "2024. war ein gutes Jahr" stays in its paragraph.
        guard let m = marker(line) else { return false }
        return !m.ordered || m.number == 1
    }

    // ```swift … ``` and ~~~ … ~~~. Runs to the end while it is still open.
    private static func fence(_ lines: [Line], _ i: Int) -> (MarkdownBlock, Int)? {
        let line = lines[i]
        guard isFence(line), let ch = line.content.first else { return nil }
        let run = line.content.prefix { $0 == ch }.count
        let info = line.content.dropFirst(run).trimmingCharacters(in: .whitespaces)
        let language = info.split(separator: " ").first.map(String.init) ?? ""
        var body: [String] = []
        var j = i + 1
        while j < lines.count {
            let t = lines[j].trimmed
            if lines[j].indent < 4, t.count >= run, t.allSatisfy({ $0 == ch }) {
                return (.code(language: language, text: body.joined(separator: "\n")), j + 1)
            }
            body.append(lines[j].dedented(by: line.indent))
            j += 1
        }
        return (.code(language: language, text: body.joined(separator: "\n")), j)
    }

    private static func isFence(_ line: Line) -> Bool {
        guard line.indent < 4, let ch = line.content.first, ch == "`" || ch == "~" else { return false }
        let run = line.content.prefix { $0 == ch }.count
        guard run >= 3 else { return false }
        return ch == "~" || !line.content.dropFirst(run).contains("`")
    }

    // $$…$$ or \[…\], on one line or across several.
    private static func displayMath(_ lines: [Line], _ i: Int) -> (MarkdownBlock, Int)? {
        let t = lines[i].trimmed
        let close: String
        if t.hasPrefix("$$") { close = "$$" } else if t.hasPrefix("\\[") { close = "\\]" } else { return nil }
        let rest = t.dropFirst(2)
        if let end = rest.range(of: close) {
            // "$$a$$ and so $$b$$" is a sentence: leave it to the paragraph.
            guard rest[end.upperBound...].allSatisfy(\.isWhitespace) else { return nil }
            let latex = rest[..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            return latex.isEmpty ? nil : (.math(latex), i + 1)
        }
        var parts = [String(rest)]
        var j = i + 1
        while j < lines.count {
            let c = lines[j].trimmed
            if let end = c.range(of: close) {
                parts.append(String(c[..<end.lowerBound]))
                return (.math(joinedMath(parts)), j + 1)
            }
            parts.append(c)
            j += 1
        }
        // Still being written.
        return (.math(joinedMath(parts)), j)
    }

    private static func joinedMath(_ parts: [String]) -> String {
        parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Display environments written without $$ around them.
    private static let displayEnvironments: Set<String> = [
        "equation", "align", "alignat", "flalign", "gather", "multline", "eqnarray",
        "aligned", "gathered", "split", "cases", "array",
        "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix",
    ]

    private static func environmentName(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix("\\begin{"), let close = trimmed.firstIndex(of: "}") else { return nil }
        let name = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 7)..<close])
        let bare = name.hasSuffix("*") ? String(name.dropLast()) : name
        return displayEnvironments.contains(bare) ? name : nil
    }

    // \begin{align} … \end{align}
    private static func mathEnvironment(_ lines: [Line], _ i: Int) -> (MarkdownBlock, Int)? {
        guard let name = environmentName(lines[i].trimmed) else { return nil }
        let end = "\\end{\(name)}"
        var parts: [String] = []
        var j = i
        while j < lines.count {
            let c = lines[j].trimmed
            if let r = c.range(of: end) {
                parts.append(String(c[..<r.upperBound]))
                return (.math(joinedMath(parts)), j + 1)
            }
            parts.append(c)
            j += 1
        }
        return (.math(joinedMath(parts)), j)
    }

    private static func headingLevel(_ line: Line) -> Int? {
        guard line.indent < 4 else { return nil }
        let hashes = line.content.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let after = line.content.dropFirst(hashes)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        return hashes
    }

    private static func heading(_ lines: [Line], _ i: Int) -> (MarkdownBlock, Int)? {
        guard let level = headingLevel(lines[i]) else { return nil }
        var text = lines[i].content.dropFirst(level).trimmingCharacters(in: .whitespaces)
        // "## Title ##"
        if let closing = text.range(of: #"\s+#+$"#, options: .regularExpression) {
            text = String(text[..<closing.lowerBound])
        } else if text.allSatisfy({ $0 == "#" }) {
            text = ""
        }
        return (.heading(level: level, text: text), i + 1)
    }

    /// ---, ***, ___ (spaces between allowed).
    private static func isRule(_ line: Line) -> Bool {
        guard line.indent < 4 else { return false }
        let marks = line.content.filter { !$0.isWhitespace }
        guard marks.count >= 3, let ch = marks.first, "-*_".contains(ch) else { return false }
        return marks.allSatisfy { $0 == ch }
    }

    private static func rule(_ lines: [Line], _ i: Int) -> (MarkdownBlock, Int)? {
        isRule(lines[i]) ? (.rule, i + 1) : nil
    }

    // MARK: Tables

    private static func isTableStart(_ lines: [Line], _ i: Int) -> Bool {
        guard i + 1 < lines.count, lines[i].content.contains("|") else { return false }
        return delimiterRow(lines[i + 1]) != nil
    }

    /// |:---|:---:|---:|
    private static func delimiterRow(_ line: Line) -> [MarkdownTable.Alignment]? {
        let t = line.trimmed
        guard t.contains("-"), t.allSatisfy({ "|:- \t".contains($0) }) else { return nil }
        let cells = cells(t)
        guard !cells.isEmpty, t.contains("|") || cells.count > 1 else { return nil }
        var alignments: [MarkdownTable.Alignment] = []
        for cell in cells {
            guard cell.contains("-") else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments
    }

    private static func table(_ lines: [Line], _ i: Int) -> (MarkdownBlock, Int)? {
        guard isTableStart(lines, i), let alignments = delimiterRow(lines[i + 1]) else { return nil }
        let header = cells(lines[i].trimmed)
        let columns = max(header.count, alignments.count)
        func padded(_ row: [String]) -> [String] {
            Array((row + Array(repeating: "", count: max(0, columns - row.count))).prefix(columns))
        }
        var rows: [[String]] = []
        var j = i + 2
        while j < lines.count, !lines[j].isBlank, lines[j].content.contains("|") {
            rows.append(padded(cells(lines[j].trimmed)))
            j += 1
        }
        let table = MarkdownTable(
            header: padded(header),
            alignments: Array((alignments + Array(repeating: .leading, count: columns)).prefix(columns)),
            rows: rows
        )
        return (.table(table), j)
    }

    /// Splits a table row on its pipes, but not on \| or pipes inside `code`
    /// or maths ($|x|$ is an absolute value, not a new cell). Prices stay text.
    static func cells(_ row: String) -> [String] {
        let (marked, spans) = InlineMath.extract(row.trimmingCharacters(in: .whitespaces))
        var t = Substring(marked)
        if t.hasPrefix("|") { t = t.dropFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t = t.dropLast() }
        let chars = Array(t)
        var cells: [String] = []
        var cell = ""
        /// The length of the backtick run that opened the code span we are in, or 0.
        var codeRun = 0
        var k = 0
        while k < chars.count {
            let ch = chars[k]
            if ch == "\\", k + 1 < chars.count {
                // \| is a pipe in the cell (maths is set aside, so its \| stays).
                if chars[k + 1] != "|" { cell.append(ch) }
                cell.append(chars[k + 1])
                k += 2
            } else if ch == "`" {
                // ``a|b`` is one code span: runs pair up by length, as in InlineMath.
                var n = 0
                while k + n < chars.count, chars[k + n] == "`" { n += 1 }
                if codeRun == 0 {
                    if hasBacktickRun(chars, from: k + n, length: n) { codeRun = n }
                } else if n == codeRun {
                    codeRun = 0
                }
                cell.append(contentsOf: chars[k..<k + n])
                k += n
            } else if ch == "|" && codeRun == 0 {
                cells.append(cell)
                cell = ""
                k += 1
            } else if let i = InlineMath.index(of: ch), i < spans.count {
                // The maths goes back as written: the cell is read again when drawn.
                let latex = spans[i].latex
                cell += spans[i].display ? "$$\(latex)$$" : "$\(latex)$"
                k += 1
            } else {
                cell.append(ch)
                k += 1
            }
        }
        cells.append(cell)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func hasBacktickRun(_ chars: [Character], from start: Int, length: Int) -> Bool {
        var j = start
        while j < chars.count {
            guard chars[j] == "`" else {
                j += 1
                continue
            }
            var n = 0
            while j + n < chars.count, chars[j + n] == "`" { n += 1 }
            if n == length { return true }
            j += n
        }
        return false
    }

    // MARK: Quotes

    private static func quote(_ lines: [Line], _ i: Int, depth: Int) -> (MarkdownBlock, Int)? {
        guard lines[i].indent < 4, lines[i].content.hasPrefix(">") else { return nil }
        var inner: [Line] = []
        var j = i
        while j < lines.count, lines[j].indent < 4, lines[j].content.hasPrefix(">") {
            var rest = lines[j].content.dropFirst()
            if rest.first == " " { rest = rest.dropFirst() }
            inner.append(Line(String(rest)))
            j += 1
        }
        return (.quote(blocks(inner, depth: depth + 1)), j)
    }

    // MARK: Lists

    struct Marker: Equatable {
        var ordered: Bool
        var number: Int
        /// Where the item's own text starts, counted from the line's start.
        var contentIndent: Int
        /// The text after the marker.
        var text: String
    }

    /// "- item", "* item", "+ item", "1. item", "1) item".
    static func marker(_ line: Line) -> Marker? {
        guard !isRule(line) else { return nil }
        let c = line.content
        var ordered = false
        var number = 1
        var markerLength: Int
        if let first = c.first, "-*+".contains(first) {
            markerLength = 1
        } else {
            let digits = c.prefix { $0.isASCII && $0.isNumber }
            guard (1...9).contains(digits.count) else { return nil }
            let after = c.dropFirst(digits.count).first
            guard after == "." || after == ")" else { return nil }
            ordered = true
            number = Int(digits) ?? 1
            markerLength = digits.count + 1
        }
        let rest = c.dropFirst(markerLength)
        if rest.isEmpty {
            return Marker(ordered: ordered, number: number, contentIndent: line.indent + markerLength + 1, text: "")
        }
        guard rest.first == " " || rest.first == "\t" else { return nil }
        let spaces = rest.prefix { $0 == " " || $0 == "\t" }.count
        let text = String(rest.dropFirst(spaces))
        if text.isEmpty {
            return Marker(ordered: ordered, number: number, contentIndent: line.indent + markerLength + 1, text: "")
        }
        // Five or more spaces would be indented code: the item starts after one.
        let gap = spaces > 4 ? 1 : spaces
        let shown = spaces > 4 ? String(repeating: " ", count: spaces - 1) + text : text
        return Marker(ordered: ordered, number: number, contentIndent: line.indent + markerLength + gap, text: shown)
    }

    private static func list(_ lines: [Line], _ i: Int, depth: Int) -> (MarkdownBlock, Int)? {
        guard let first = marker(lines[i]) else { return nil }
        let base = lines[i].indent
        var items: [[Line]] = []
        var current: [Line] = [Line(first.text)]
        var contentIndent = first.contentIndent
        var previousBlank = false
        var j = i + 1

        while j < lines.count {
            let line = lines[j]
            if line.isBlank {
                // Does the list go on after the blank lines?
                var k = j
                while k < lines.count, lines[k].isBlank { k += 1 }
                guard k < lines.count else { break }
                let next = lines[k]
                let continues = next.indent > base
                let nextItem = next.indent <= base && marker(next)?.ordered == first.ordered
                guard continues || nextItem else { break }
                if continues { current.append(contentsOf: Array(repeating: Line(""), count: k - j)) }
                previousBlank = true
                j = k
                continue
            }
            if line.indent > base {
                // Inside the item: its next paragraph, its maths, a nested list.
                current.append(Line(line.dedented(by: min(line.indent, contentIndent))))
            } else if let m = marker(line) {
                guard m.ordered == first.ordered else { break }
                items.append(current)
                current = [Line(m.text)]
                contentIndent = m.contentIndent
            } else if !previousBlank && !interrupts(lines, j) {
                // A lazy continuation line of the item's paragraph.
                current.append(Line(line.content))
            } else {
                break
            }
            previousBlank = false
            j += 1
        }
        items.append(current)
        let list = MarkdownList(ordered: first.ordered, start: first.number, items: items.map { blocks($0, depth: depth + 1) })
        return (.list(list), j)
    }

    // MARK: Paragraphs

    /// Line breaks inside a paragraph are kept: models use them on purpose.
    private static func paragraph(_ lines: [Line], _ i: Int) -> (MarkdownBlock, Int) {
        var parts = [lines[i].trimmed]
        var j = i + 1
        while j < lines.count, !lines[j].isBlank, !interrupts(lines, j) {
            parts.append(lines[j].trimmed)
            j += 1
        }
        return (.paragraph(parts.joined(separator: "\n")), j)
    }
}

// MARK: - Inline maths

/// Finds the maths in a line of text. Each piece is swapped for one character
/// from Unicode's private use area, so the Markdown reader cannot take the `_`,
/// `*` and `\` of LaTeX for formatting. Bold or italic around maths still works.
enum InlineMath {
    struct Span: Equatable {
        let latex: String
        /// Written with $$ or \[ in the middle of a sentence.
        let display: Bool
    }

    private static let base: UInt32 = 0xE000
    private static let capacity: UInt32 = 0x1000

    static func placeholder(_ index: Int) -> Character {
        Character(Unicode.Scalar(base + UInt32(index))!)
    }

    /// The span a placeholder character stands for.
    static func index(of ch: Character) -> Int? {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1,
              scalar.value >= base, scalar.value < base + capacity else { return nil }
        return Int(scalar.value - base)
    }

    static func extract(_ text: String) -> (text: String, spans: [Span]) {
        let chars = Array(text)
        var out = ""
        var spans: [Span] = []
        var i = 0

        func add(_ latex: [Character], display: Bool) -> Bool {
            let source = String(latex).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty, spans.count < Int(capacity) else { return false }
            out.append(placeholder(spans.count))
            spans.append(Span(latex: source, display: display))
            return true
        }

        while i < chars.count {
            let c = chars[i]

            // `code` stays as written.
            if c == "`" {
                let run = count(chars, from: i, of: "`")
                if let end = closingBackticks(chars, from: i + run, run: run) {
                    out.append(contentsOf: chars[i..<end + run])
                    i = end + run
                } else {
                    out.append(contentsOf: chars[i..<i + run])
                    i += run
                }
                continue
            }

            if c == "\\", i + 1 < chars.count {
                let d = chars[i + 1]
                if d == "(" || d == "[" {
                    let close: [Character] = d == "(" ? ["\\", ")"] : ["\\", "]"]
                    if let end = find(close, in: chars, from: i + 2),
                       add(Array(chars[i + 2..<end]), display: d == "[") {
                        i = end + 2
                        continue
                    }
                }
                // Any other escape, \$ included, is left for Markdown.
                out.append(c)
                out.append(d)
                i += 2
                continue
            }

            if c == "$" {
                if i + 1 < chars.count, chars[i + 1] == "$" {
                    if let end = find(["$", "$"], in: chars, from: i + 2),
                       add(Array(chars[i + 2..<end]), display: true) {
                        i = end + 2
                    } else {
                        out.append("$$")
                        i += 2
                    }
                    continue
                }
                if let end = closingDollar(chars, from: i + 1),
                   add(Array(chars[i + 1..<end]), display: false) {
                    i = end + 1
                    continue
                }
            }

            // Drop any private-use characters the model wrote, so they cannot
            // pass for a placeholder.
            if index(of: c) == nil { out.append(c) }
            i += 1
        }
        return (out, spans)
    }

    /// The closing $ of inline maths opened just before `start`, following
    /// Pandoc's rules so that prices ("$5 and $10") stay text: no space just
    /// inside the dollars unless the inside is clearly LaTeX, no digit just
    /// after the closing one, and no line break.
    private static func closingDollar(_ chars: [Character], from start: Int) -> Int? {
        guard start < chars.count, chars[start] != "$", !chars[start].isNewline else { return nil }
        var j = start
        while j < chars.count {
            let ch = chars[j]
            if ch.isNewline { return nil }
            if ch == "\\" {
                j += 2
                continue
            }
            if ch == "$" {
                let inside = chars[start..<j]
                let padded = chars[start].isWhitespace || chars[j - 1].isWhitespace
                if padded && !inside.contains(where: { "\\^_{}=".contains($0) }) { return nil }
                if j + 1 < chars.count, chars[j + 1].isNumber { return nil }
                return j
            }
            j += 1
        }
        return nil
    }

    private static func count(_ chars: [Character], from i: Int, of ch: Character) -> Int {
        var n = 0
        while i + n < chars.count, chars[i + n] == ch { n += 1 }
        return n
    }

    private static func closingBackticks(_ chars: [Character], from start: Int, run: Int) -> Int? {
        var j = start
        while j < chars.count {
            if chars[j] == "`" {
                let n = count(chars, from: j, of: "`")
                if n == run { return j }
                j += n
            } else {
                j += 1
            }
        }
        return nil
    }

    private static func find(_ needle: [Character], in chars: [Character], from start: Int) -> Int? {
        guard needle.count <= chars.count else { return nil }
        var j = start
        while j + needle.count <= chars.count {
            if chars[j] == "\\" && needle.first != "\\" {
                j += 2
                continue
            }
            if Array(chars[j..<j + needle.count]) == needle { return j }
            j += 1
        }
        return nil
    }
}

// MARK: - LaTeX clean-up

/// Rewrites LaTeX that models write but the typesetter (SwiftMath 1.7) does
/// not know into LaTeX it does, without changing what the formula says.
enum LaTeX {
    static func prepare(_ latex: String) -> String {
        var s = latex

        // Environments: numbered display forms become their inline relatives.
        // alignat and array carry a column argument the typesetter cannot read.
        s = s.replacingOccurrences(of: #"\\begin\{(alignat\*?)\}\s*\{[^}]*\}"#, with: "\\\\begin{$1}", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\begin\{array\}\s*\{[^}]*\}"#, with: "\\\\begin{matrix}", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\end{array}", with: "\\end{matrix}")
        s = renameEnvironment(s, ["equation", "equation*", "displaymath"], to: nil)
        s = renameEnvironment(s, ["align", "align*", "flalign", "flalign*", "alignat", "alignat*"], to: "aligned")
        s = renameEnvironment(s, ["gather*", "gathered", "multline", "multline*"], to: "gather")
        s = renameEnvironment(s, ["eqnarray*"], to: "eqnarray")
        s = renameEnvironment(s, ["smallmatrix"], to: "matrix")
        s = renameEnvironment(s, ["dcases", "dcases*", "cases*"], to: "cases")

        // Commands that only change size or numbering: dropped.
        s = s.replacingOccurrences(
            of: #"\\(tiny|scriptsize|footnotesize|small|normalsize|large|Large|LARGE|huge|Huge|nonumber|notag|middle|hline|displaybreak|allowbreak)(?![A-Za-z])\s*"#,
            with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\(tag\*?|label|vspace\*?)\s*\{[^}]*\}"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\hspace\*?\s*\{[^}]*\}"#, with: "\\\\quad ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\(big|Big|bigg|Bigg)[lrm]?(?![A-Za-z])\s*"#, with: "", options: .regularExpression)
        // Row breaks with extra space: \\[4pt]
        s = s.replacingOccurrences(of: #"\\\\\s*\[[^\]]*\]"#, with: "\\\\\\\\", options: .regularExpression)

        // Same thing, another name.
        for (from, to) in renames {
            s = s.replacingOccurrences(of: "\\\\" + from + "(?![A-Za-z])", with: to, options: .regularExpression)
        }
        // The medium space \: is called \> here.
        s = s.replacingOccurrences(of: "\\:", with: "\\>")
        // \boxed{x}, \cancel{x}: keep what is inside.
        s = s.replacingOccurrences(of: #"\\(boxed|cancel|bcancel|xcancel)(?![A-Za-z])\s*"#, with: "", options: .regularExpression)
        // \pmod{n} → (mod n)
        s = s.replacingOccurrences(of: #"\\pmod\s*\{([^}]*)\}"#, with: "\\\\ (\\\\mathrm{mod}\\\\ $1)", options: .regularExpression)
        // \overset{a}{b}, \stackrel{a}{b} → b with a above as a script.
        s = replaceTwoArguments(s, commands: ["overset", "stackrel"]) { a, b in "{\(b)}^{\(a)}" }
        s = replaceTwoArguments(s, commands: ["underset"]) { a, b in "{\(b)}_{\(a)}" }
        // \xrightarrow{f} → an arrow with f above.
        s = s.replacingOccurrences(of: #"\\xrightarrow\s*\{([^}]*)\}"#, with: "\\\\rightarrow^{$1}", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\xleftarrow\s*\{([^}]*)\}"#, with: "\\\\leftarrow^{$1}", options: .regularExpression)

        // Unicode the math font has but the reader would skip, and primes,
        // which it does not read either: f'(x), f''(x), f′(x).
        var out = ""
        var primes = 0
        func flushPrimes() {
            guard primes > 0 else { return }
            out += "^{" + String(repeating: "\\prime", count: primes) + "}"
            primes = 0
        }
        for ch in s {
            switch ch {
            case "'", "′":
                primes += 1
            case "″":
                primes += 2
            default:
                flushPrimes()
                if let replacement = unicode[ch] { out += replacement } else { out.append(ch) }
            }
        }
        flushPrimes()
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let renames: [(String, String)] = [
        ("dfrac", "\\\\frac"), ("tfrac", "\\\\frac"), ("cfrac", "\\\\frac"), ("sfrac", "\\\\frac"),
        ("dbinom", "\\\\binom"), ("tbinom", "\\\\binom"),
        ("operatorname\\*?", "\\\\mathrm"), ("mathscr", "\\\\mathcal"),
        ("textnormal", "\\\\textrm"), ("textup", "\\\\textrm"), ("emph", "\\\\textit"),
        ("mbox", "\\\\text"), ("hbox", "\\\\text"), ("textcolor", "\\\\color"),
        ("boldsymbol", "\\\\bm"), ("pmb", "\\\\bm"),
        ("implies", "\\\\Rightarrow"), ("impliedby", "\\\\Leftarrow"),
        ("dots", "\\\\ldots"), ("dotsc", "\\\\ldots"), ("dotso", "\\\\ldots"),
        ("dotsb", "\\\\cdots"), ("dotsm", "\\\\cdots"), ("dotsi", "\\\\cdots"),
        ("lvert", "|"), ("rvert", "|"), ("lVert", "\\\\Vert"), ("rVert", "\\\\Vert"),
        ("lt", "<"), ("gt", ">"), ("leqslant", "\\\\leq"), ("geqslant", "\\\\geq"),
        ("cdotp", "\\\\cdot"), ("textdegree", "^{\\\\circ}"),
        ("overrightarrow", "\\\\vec"), ("underbrace", "\\\\underline"), ("overbrace", "\\\\overline"),
        ("bmod", "\\\\ \\\\mathrm{mod}\\\\ "), ("mod", "\\\\ \\\\mathrm{mod}\\\\ "),
        ("measuredangle", "\\\\angle"), ("land", "\\\\wedge"), ("lor", "\\\\vee"),
        ("textbackslash", "\\\\backslash"),
        ("R", "\\\\mathbb{R}"), ("N", "\\\\mathbb{N}"), ("Z", "\\\\mathbb{Z}"),
        ("Q", "\\\\mathbb{Q}"), ("C", "\\\\mathbb{C}"),
    ]

    /// Symbols written as Unicode, as LaTeX the typesetter knows. Letters with
    /// accents (ä, é, ß …) and Cyrillic it reads itself.
    private static let unicode: [Character: String] = [
        "×": "\\times ", "·": "\\cdot ", "⋅": "\\cdot ", "∙": "\\cdot ", "÷": "\\div ",
        "±": "\\pm ", "∓": "\\mp ", "−": "-", "–": "-", "≤": "\\leq ", "≥": "\\geq ",
        "≠": "\\neq ", "≈": "\\approx ", "≡": "\\equiv ", "≅": "\\cong ", "∼": "\\sim ",
        "∝": "\\propto ", "∞": "\\infty ", "→": "\\rightarrow ", "←": "\\leftarrow ",
        "↔": "\\leftrightarrow ", "⇒": "\\Rightarrow ", "⇐": "\\Leftarrow ", "⇔": "\\Leftrightarrow ",
        "↦": "\\mapsto ", "∑": "\\sum ", "∏": "\\prod ", "∫": "\\int ", "∮": "\\oint ",
        "∂": "\\partial ", "∇": "\\nabla ", "√": "\\sqrt ", "∈": "\\in ", "∉": "\\notin ",
        "∋": "\\ni ", "⊂": "\\subset ", "⊆": "\\subseteq ", "⊃": "\\supset ", "⊇": "\\supseteq ",
        "∪": "\\cup ", "∩": "\\cap ", "∅": "\\emptyset ", "∀": "\\forall ", "∃": "\\exists ",
        "¬": "\\neg ", "∧": "\\wedge ", "∨": "\\vee ", "⊥": "\\perp ", "∥": "\\parallel ",
        "∠": "\\angle ", "△": "\\triangle ", "°": "^{\\circ}", "…": "\\ldots ",
        "⋯": "\\cdots ", "ℝ": "\\mathbb{R}", "ℕ": "\\mathbb{N}", "ℤ": "\\mathbb{Z}",
        "ℚ": "\\mathbb{Q}", "ℂ": "\\mathbb{C}", "²": "^{2}", "³": "^{3}", "¹": "^{1}",
        "½": "\\frac{1}{2}", "¼": "\\frac{1}{4}", "¾": "\\frac{3}{4}", "ℓ": "\\ell ",
        "α": "\\alpha ", "β": "\\beta ", "γ": "\\gamma ", "δ": "\\delta ", "ε": "\\varepsilon ",
        "ζ": "\\zeta ", "η": "\\eta ", "θ": "\\theta ", "ι": "\\iota ", "κ": "\\kappa ",
        "λ": "\\lambda ", "μ": "\\mu ", "ν": "\\nu ", "ξ": "\\xi ", "π": "\\pi ", "ρ": "\\rho ",
        "σ": "\\sigma ", "τ": "\\tau ", "υ": "\\upsilon ", "φ": "\\varphi ", "χ": "\\chi ",
        "ψ": "\\psi ", "ω": "\\omega ", "Γ": "\\Gamma ", "Δ": "\\Delta ", "Θ": "\\Theta ",
        "Λ": "\\Lambda ", "Ξ": "\\Xi ", "Π": "\\Pi ", "Σ": "\\Sigma ", "Φ": "\\Phi ",
        "Ψ": "\\Psi ", "Ω": "\\Omega ", "\u{00A0}": " ",
    ]

    private static func renameEnvironment(_ s: String, _ names: [String], to replacement: String?) -> String {
        var s = s
        for name in names {
            s = s.replacingOccurrences(of: "\\begin{\(name)}", with: replacement.map { "\\begin{\($0)}" } ?? "")
            s = s.replacingOccurrences(of: "\\end{\(name)}", with: replacement.map { "\\end{\($0)}" } ?? "")
        }
        return s
    }

    /// Rewrites \command{a}{b}, with nested braces in a and b.
    private static func replaceTwoArguments(_ s: String, commands: [String], _ make: (String, String) -> String) -> String {
        var s = s
        for command in commands {
            let token = "\\\(command)"
            var offset = 0
            while let from = s.index(s.startIndex, offsetBy: offset, limitedBy: s.endIndex),
                  let r = s.range(of: token, range: from..<s.endIndex) {
                let start = s.distance(from: s.startIndex, to: r.lowerBound)
                // Not the start of a longer name.
                if r.upperBound < s.endIndex, s[r.upperBound].isLetter {
                    offset = start + token.count
                    continue
                }
                guard let (a, afterA) = group(in: s, from: r.upperBound),
                      let (b, afterB) = group(in: s, from: afterA) else {
                    offset = start + token.count
                    continue
                }
                s.replaceSubrange(r.lowerBound..<afterB, with: make(a, b))
                // Look again from here, for one written inside a or b.
                offset = start
            }
        }
        return s
    }

    /// The contents of the {group} starting at `index` (after spaces), and where it ends.
    private static func group(in s: String, from index: String.Index) -> (String, String.Index)? {
        var i = index
        while i < s.endIndex, s[i] == " " { i = s.index(after: i) }
        guard i < s.endIndex, s[i] == "{" else { return nil }
        var depth = 0
        var j = i
        while j < s.endIndex {
            if s[j] == "\\" {
                j = s.index(after: j)
                if j < s.endIndex { j = s.index(after: j) }
                continue
            }
            if s[j] == "{" { depth += 1 }
            if s[j] == "}" {
                depth -= 1
                if depth == 0 {
                    return (String(s[s.index(after: i)..<j]), s.index(after: j))
                }
            }
            j = s.index(after: j)
        }
        return nil
    }
}
