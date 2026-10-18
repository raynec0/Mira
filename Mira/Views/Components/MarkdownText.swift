import SwiftUI
import UIKit

enum MDBlock {
    case paragraph(String)
    case heading(Int, String)
    case bullet(String, Int)
    case numbered(String, String)
    case quote(String)
    case code(String, String)
    case table([[String]])
    case rule
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var paragraph: [String] = []
        var inCode = false
        var codeLang = ""
        var codeLines: [String] = []
        var tableRows: [[String]] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }
        func flushTable() {
            if !tableRows.isEmpty {
                blocks.append(.table(tableRows))
                tableRows = []
            }
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeLang, codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCode = false
                } else {
                    flushParagraph()
                    flushTable()
                    inCode = true
                    codeLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if inCode {
                codeLines.append(line)
                continue
            }
            if trimmed.count > 1, trimmed.hasPrefix("|"), trimmed.hasSuffix("|") {
                flushParagraph()
                let cells = trimmed.dropFirst().dropLast().components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                let isSeparator = cells.allSatisfy { cell in
                    !cell.isEmpty && cell.allSatisfy { ch in ch == "-" || ch == ":" || ch == " " }
                }
                if !isSeparator { tableRows.append(cells) }
                continue
            } else {
                flushTable()
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix { $0 == "#" }.count
                let rest = trimmed.dropFirst(level)
                if level <= 6, rest.hasPrefix(" ") {
                    flushParagraph()
                    blocks.append(.heading(level, rest.trimmingCharacters(in: .whitespaces)))
                    continue
                }
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                let indent = (line.count - line.drop(while: { $0 == " " }).count) / 2
                blocks.append(.bullet(String(trimmed.dropFirst(2)), min(indent, 4)))
                continue
            }
            if let n = numbered(trimmed) {
                flushParagraph()
                blocks.append(.numbered(n.0, n.1))
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                continue
            }
            paragraph.append(line)
        }
        if inCode { blocks.append(.code(codeLang, codeLines.joined(separator: "\n"))) }
        flushParagraph()
        flushTable()
        return blocks
    }

    static func numbered(_ s: String) -> (String, String)? {
        let digits = s.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = s.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") || rest.hasPrefix("、") else { return nil }
        let body = rest.hasPrefix("、") ? rest.dropFirst(1) : rest.dropFirst(2)
        return (String(digits), String(body))
    }

    static func inline(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }
}

struct MarkdownText: View {
    let text: String
    var isUser = false

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MDBlock) -> some View {
        switch block {
        case .paragraph(let s):
            Text(MarkdownParser.inline(s)).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let s):
            Text(MarkdownParser.inline(s))
                .font(level <= 1 ? Font.title3.bold() : (level == 2 ? Font.headline : Font.subheadline.bold()))
                .padding(.top, 2)
        case .bullet(let s, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(indent > 0 ? "◦" : "•")
                Text(MarkdownParser.inline(s)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .numbered(let n, let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(n).").monospacedDigit()
                Text(MarkdownParser.inline(s)).fixedSize(horizontal: false, vertical: true)
            }
        case .quote(let s):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.5)).frame(width: 3)
                Text(MarkdownParser.inline(s)).italic().opacity(0.85)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let lang, let code):
            CodeBlockView(language: lang, code: code, onDark: isUser)
        case .table(let rows):
            TableBlockView(rows: rows)
        case .rule:
            Divider().opacity(0.6)
        }
    }
}

struct CodeBlockView: View {
    let language: String
    let code: String
    var onDark = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(language.isEmpty ? "代码" : language).font(.caption2.weight(.semibold)).opacity(0.7)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.caption)
                }
                .buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(onDark ? 0.22 : 0.07)))
    }
}

struct TableBlockView: View {
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(MarkdownParser.inline(cell))
                                .font(index == 0 ? Font.subheadline.bold() : Font.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 220, alignment: .leading)
                        }
                    }
                    if index == 0 {
                        Divider().gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}
