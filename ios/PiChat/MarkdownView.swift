import SwiftMath
import SwiftUI
import UIKit

// Draws an answer from its Markdown (see Markdown.swift): headings, lists,
// quotes, code, tables and rules in the app's type, and LaTeX maths typeset by
// SwiftMath, inline in the sentence or centred on its own line.

/// An answer as it should look.
struct MarkdownView: View {
    let text: String

    var body: some View {
        BlocksView(blocks: Markdown.parse(text), depth: 0)
    }
}

// MARK: - Blocks

private struct BlocksView: View {
    let blocks: [MarkdownBlock]
    /// How deep in lists these blocks are, for the bullet.
    let depth: Int
    var spacing: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                BlockView(block: block, depth: depth, isFirst: index == 0)
            }
        }
    }
}

private struct BlockView: View {
    let block: MarkdownBlock
    let depth: Int
    let isFirst: Bool

    var body: some View {
        switch block {
        case .heading(let level, let text):
            RichText(text, style: .heading(level))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, isFirst ? 0 : 6)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            RichText(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .math(let latex):
            DisplayMath(latex: latex)
        case .code(let language, let code):
            CodeBlock(language: language, code: code)
        case .quote(let blocks):
            BlocksView(blocks: blocks, depth: depth, spacing: 10)
                .padding(.leading, 15)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.lineStrong)
                        .frame(width: 3)
                }
        case .list(let list):
            ListBlock(list: list, depth: depth)
        case .table(let table):
            TableBlock(table: table)
        case .rule:
            Theme.line
                .frame(height: 1)
                .padding(.vertical, 4)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Text with maths

/// A paragraph, heading or table cell: inline Markdown, with its maths drawn
/// where it stands in the sentence.
private struct RichText: View {
    enum Style: Equatable {
        case body
        case heading(Int)
        case cell(header: Bool)
    }

    let source: String
    let style: Style
    @Environment(\.colorScheme) private var colorScheme
    /// Dynamic Type: 100 at the default size. The fonts scale by themselves,
    /// the maths images need telling.
    @ScaledMetric(relativeTo: .body) private var percent: CGFloat = 100

    init(_ source: String, style: Style = .body) {
        self.source = source
        self.style = style
    }

    var body: some View {
        let rendered = InlineMarkdown.render(
            source,
            size: size,
            weight: weight,
            mathSize: size * percent / 100 * 1.08,
            dark: colorScheme == .dark
        )
        rendered.text
            .font(Theme.sans(size, weight))
            .tracking(style == .heading(1) ? -0.3 : 0)
            .foregroundStyle(Theme.text)
            .lineSpacing(style == .body ? 3 : 1)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(rendered.spoken.map { Text($0) } ?? rendered.text)
    }

    private var size: CGFloat {
        switch style {
        case .body: 16
        case .heading(1): 22
        case .heading(2): 19
        case .heading(3): 17
        case .heading: 16
        case .cell: 14
        }
    }

    private var weight: Theme.Weight {
        switch style {
        case .body, .cell(header: false): .regular
        case .heading, .cell(header: true): .semibold
        }
    }
}

/// Turns one line of inline Markdown into a SwiftUI Text.
@MainActor
enum InlineMarkdown {
    struct Rendered {
        let text: Text
        /// What VoiceOver reads when there is maths: the text with its LaTeX.
        let spoken: String?
    }

    static func render(_ source: String, size: CGFloat, weight: Theme.Weight, mathSize: CGFloat, dark: Bool) -> Rendered {
        let (marked, spans) = InlineMath.extract(source)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let attributed = (try? AttributedString(markdown: marked, options: options)) ?? AttributedString(marked)

        var result: Text?
        var pending = AttributedString()
        var spoken = ""

        func append(_ piece: Text) {
            if let soFar = result {
                result = Text("\(soFar)\(piece)")
            } else {
                result = piece
            }
        }
        func flush() {
            guard !pending.characters.isEmpty else { return }
            append(Text(pending))
            pending = AttributedString()
        }

        for run in attributed.runs {
            let attributes = styled(run.attributes, size: size, weight: weight)
            var buffer = ""
            for ch in attributed[run.range].characters {
                if let i = InlineMath.index(of: ch), i < spans.count {
                    if !buffer.isEmpty {
                        pending += AttributedString(buffer, attributes: attributes)
                        buffer = ""
                    }
                    flush()
                    append(math(spans[i], size: mathSize, dark: dark))
                    spoken += spans[i].latex
                } else {
                    buffer.append(ch)
                    spoken.append(ch)
                }
            }
            if !buffer.isEmpty { pending += AttributedString(buffer, attributes: attributes) }
        }
        flush()
        return Rendered(text: result ?? Text(""), spoken: spans.isEmpty ? nil : spoken)
    }

    /// Code in JetBrains Mono on a light fill, bold in the font's own semibold,
    /// so neither depends on SwiftUI finding a matching face.
    private static func styled(_ attributes: AttributeContainer, size: CGFloat, weight: Theme.Weight) -> AttributeContainer {
        typealias Intent = AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute
        typealias FontKey = AttributeScopes.SwiftUIAttributes.FontAttribute
        typealias Background = AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute

        var attributes = attributes
        guard let intent = attributes[Intent.self] else { return attributes }
        if intent.contains(.code) {
            attributes[FontKey.self] = Theme.mono(size * 0.9)
            attributes[Background.self] = Theme.surface2
        } else if intent.contains(.stronglyEmphasized) {
            attributes[FontKey.self] = Theme.sans(size, weight == .regular ? .semibold : .bold)
            attributes[Intent.self] = intent.subtracting(.stronglyEmphasized)
        }
        return attributes
    }

    /// The formula as an image on the text's baseline, or its LaTeX when the
    /// typesetter cannot read it.
    private static func math(_ span: InlineMath.Span, size: CGFloat, dark: Bool) -> Text {
        if let math = MathRenderer.render(span.latex, display: span.display, size: size, dark: dark) {
            return Text(Image(uiImage: math.image)).baselineOffset(-math.baseline)
        }
        return Text(span.latex)
            .font(Theme.mono(size * 0.8))
            .foregroundStyle(Theme.text2)
    }
}

// MARK: - Display maths

private struct DisplayMath: View {
    let latex: String
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 19

    var body: some View {
        if let math = MathRenderer.render(latex, display: true, size: size, dark: colorScheme == .dark) {
            // Centred when it fits, scrolled sideways when it does not.
            ViewThatFits(in: .horizontal) {
                Image(uiImage: math.image)
                ScrollView(.horizontal, showsIndicators: false) {
                    Image(uiImage: math.image)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .contextMenu {
                Button("Copy LaTeX", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = latex
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text(latex))
        } else {
            // Not readable yet (still arriving) or not LaTeX the typesetter knows.
            Text(latex)
                .font(Theme.mono(13))
                .foregroundStyle(Theme.text2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.code, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Typesets LaTeX with SwiftMath into images, kept in a cache so a streaming
/// answer does not typeset the same formula again with every new word.
@MainActor
enum MathRenderer {
    struct Rendered {
        let image: UIImage
        /// Distance from the image's bottom edge up to the formula's baseline.
        let baseline: CGFloat
    }

    private final class Entry {
        let value: Rendered?
        init(_ value: Rendered?) { self.value = value }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 400
        return cache
    }()

    private static let inset: CGFloat = 1

    static func render(_ latex: String, display: Bool, size: CGFloat, dark: Bool) -> Rendered? {
        let key = "\(display ? "D" : "T")|\(size)|\(dark ? 1 : 0)|\(latex)" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let rendered = typeset(latex, display: display, size: size, color: Theme.mathInk(dark: dark))
        cache.setObject(Entry(rendered), forKey: key)
        return rendered
    }

    private static func typeset(_ latex: String, display: Bool, size fontSize: CGFloat, color: UIColor) -> Rendered? {
        let label = MTMathUILabel()
        label.displayErrorInline = false
        label.font = MTFontManager().latinModernFont(withSize: fontSize)
        label.fontSize = fontSize
        label.labelMode = display ? .display : .text
        label.textColor = color
        label.contentInsets = MTEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        label.latex = LaTeX.prepare(latex)
        guard label.error == nil, label.mathList != nil else { return nil }

        let fitted = label.intrinsicContentSize
        guard fitted.width.isFinite, fitted.height.isFinite, fitted.width > 0, fitted.height > 0 else { return nil }
        // A point to spare, so the label never decides to wrap the formula.
        let size = CGSize(width: ceil(fitted.width) + 1, height: ceil(fitted.height))
        label.frame = CGRect(origin: .zero, size: size)
        label.setNeedsLayout()
        label.layoutIfNeeded()
        guard let display = label.displayList, display.width > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            // SwiftMath draws in Core Graphics' coordinates, y going up.
            let cg = context.cgContext
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
            display.draw(cg)
        }

        // Where the label put the baseline (it centres the formula vertically).
        let height = max(display.ascent + display.descent, label.fontSize / 2)
        let baseline = (size.height - 2 * inset - height) / 2 + display.descent + inset
        return Rendered(image: image, baseline: baseline)
    }
}

// MARK: - Lists

private struct ListBlock: View {
    let list: MarkdownList
    let depth: Int

    var body: some View {
        // The widest marker keeps every item's text on one left edge.
        let widest = list.ordered ? "\(list.start + max(0, list.items.count - 1))." : bullet
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(widest)
                        .hidden()
                        .overlay(alignment: .trailing) {
                            Text(list.ordered ? "\(list.start + index)." : bullet)
                                .foregroundStyle(list.ordered ? Theme.text : Theme.text3)
                        }
                        .font(Theme.lead)
                        .monospacedDigit()
                        .accessibilityHidden(true)
                    BlocksView(blocks: item, depth: depth + 1, spacing: 8)
                }
            }
        }
        .padding(.leading, depth == 0 ? 2 : 0)
    }

    private var bullet: String {
        switch depth {
        case 0: "•"
        case 1: "◦"
        default: "▪"
        }
    }
}

// MARK: - Code

private struct CodeBlock: View {
    let language: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(language.isEmpty ? "code" : language)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.text3)
                Spacer(minLength: 8)
                Button {
                    UIPasteboard.general.string = code
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 13))
                }
                .buttonStyle(.ds(.ghost, height: 32, iconOnly: true))
                .accessibilityLabel("Copy the code")
            }
            .padding(.leading, 12)
            .padding(.trailing, 2)
            Theme.line.frame(height: 1)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(Theme.mono(13))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(Theme.code, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }
}

// MARK: - Tables

private struct TableBlock: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                        TableCell(text: cell, header: true, alignment: table.alignments[column])
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    Theme.line
                        .frame(height: 1)
                        .gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            TableCell(text: cell, header: false, alignment: table.alignments[column])
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
            .padding(1)
        }
    }
}

private struct TableCell: View {
    let text: String
    let header: Bool
    let alignment: MarkdownTable.Alignment

    var body: some View {
        RichText(text, style: .cell(header: header))
            .multilineTextAlignment(textAlignment)
            // Long cells wrap instead of making the table endlessly wide.
            .frame(width: text.count > 28 ? 220 : nil, alignment: frameAlignment)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
            .background(header ? Theme.surface2 : Color.clear)
    }

    private var frameAlignment: Alignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private var textAlignment: TextAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
