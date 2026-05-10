import Foundation

/// Markdown ファイルを Book 構造に変換するパーサー
struct MarkdownParser {

    /// Markdown ファイルを読み込み、Book に変換する
    /// - Parameters:
    ///   - fileURL: .md ファイルの URL
    ///   - title: 本のタイトル
    /// - Returns: パース済みの Book
    static func parse(fileURL: URL, title: String) throws -> Book {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        return parse(content: content, title: title)
    }

    /// Markdown テキストを Book に変換する
    static func parse(content: String, title: String) -> Book {
        let sections = splitIntoPages(content: content)
        var pages: [Page] = []
        var blockId = 0

        for (index, section) in sections.enumerated() {
            let blocks = parseBlocks(from: section.body, heading: section.heading, startId: blockId)
            blockId += blocks.count

            let page = Page(
                pageNumber: index,
                imagePath: nil,
                audioPath: nil,
                blocks: blocks,
                contentType: "markdown"
            )
            pages.append(page)
        }

        return Book(title: title, pages: pages)
    }

    // MARK: - Page Splitting

    /// Markdown を ## 見出しで分割する
    /// - Returns: (heading, body) のタプル配列。heading は ## テキスト、body はセクション全体
    static func splitIntoPages(content: String) -> [(heading: String?, body: String)] {
        let lines = content.components(separatedBy: "\n")
        var sections: [(heading: String?, body: String)] = []
        var currentHeading: String? = nil
        var currentLines: [String] = []

        for line in lines {
            if line.hasPrefix("## ") && !line.hasPrefix("### ") {
                // 前のセクションを保存
                let body = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty || currentHeading != nil {
                    sections.append((heading: currentHeading, body: body))
                }
                // 新しいセクション開始
                currentHeading = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                currentLines = [line]
            } else {
                currentLines.append(line)
            }
        }

        // 最後のセクション
        let body = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty || currentHeading != nil {
            sections.append((heading: currentHeading, body: body))
        }

        // セクションが空の場合は全体を1ページとする
        if sections.isEmpty {
            sections.append((heading: nil, body: content.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        return sections
    }

    // MARK: - Block Parsing

    /// セクションのテキストを TextBlock 配列に変換する
    static func parseBlocks(from text: String, heading: String?, startId: Int) -> [TextBlock] {
        var blocks: [TextBlock] = []
        var id = startId
        let lines = text.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 空行はスキップ
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // 見出し（#〜######）
            if let headingMatch = parseHeading(trimmed) {
                blocks.append(TextBlock(
                    id: id,
                    text: headingMatch.text,
                    type: "タイトル本文",
                    markdownType: "heading",
                    headingLevel: headingMatch.level,
                    rawMarkdown: trimmed
                ))
                id += 1
                i += 1
                continue
            }

            // コードブロック（```）
            if trimmed.hasPrefix("```") {
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 } // ``` 閉じ行をスキップ
                let codeText = codeLines.joined(separator: "\n")
                if !codeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(TextBlock(
                        id: id,
                        text: codeText,
                        type: "コードブロック",
                        markdownType: "code_block",
                        rawMarkdown: "```\n\(codeText)\n```"
                    ))
                    id += 1
                }
                continue
            }

            // 引用（>）
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                var quoteLines: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix("> ") || l == ">" {
                        let content = l.hasPrefix("> ") ? String(l.dropFirst(2)) : ""
                        quoteLines.append(content)
                        i += 1
                    } else {
                        break
                    }
                }
                let quoteText = quoteLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !quoteText.isEmpty {
                    blocks.append(TextBlock(
                        id: id,
                        text: quoteText,
                        type: "本文",
                        markdownType: "blockquote",
                        rawMarkdown: quoteText
                    ))
                    id += 1
                }
                continue
            }

            // リスト項目（- or * or 1. 等）
            if isListItem(trimmed) {
                let listText = stripListPrefix(trimmed)
                let plainText = stripInlineMarkdown(listText)
                blocks.append(TextBlock(
                    id: id,
                    text: plainText,
                    type: "本文",
                    markdownType: "list_item",
                    rawMarkdown: listText
                ))
                id += 1
                i += 1
                continue
            }

            // 通常段落（連続する非空行をまとめる）
            var paragraphLines: [String] = []
            while i < lines.count {
                let l = lines[i].trimmingCharacters(in: .whitespaces)
                if l.isEmpty || l.hasPrefix("#") || l.hasPrefix("```") || l.hasPrefix("> ") || isListItem(l) {
                    break
                }
                paragraphLines.append(l)
                i += 1
            }
            let rawParagraph = paragraphLines.joined(separator: "\n")
            let plainParagraph = stripInlineMarkdown(rawParagraph)
            if !plainParagraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(TextBlock(
                    id: id,
                    text: plainParagraph,
                    type: "本文",
                    markdownType: "paragraph",
                    rawMarkdown: rawParagraph
                ))
                id += 1
            }
            continue
        }

        return blocks
    }

    // MARK: - Helpers

    private struct HeadingMatch {
        let level: Int
        let text: String
    }

    private static func parseHeading(_ line: String) -> HeadingMatch? {
        var level = 0
        for char in line {
            if char == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6 else { return nil }
        let rest = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        return HeadingMatch(level: level, text: rest)
    }

    private static func isListItem(_ line: String) -> Bool {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return true
        }
        // 番号付きリスト: "1. ", "2. " etc.
        let pattern = #"^\d+\.\s"#
        return line.range(of: pattern, options: .regularExpression) != nil
    }

    private static func stripListPrefix(_ line: String) -> String {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return String(line.dropFirst(2))
        }
        if let range = line.range(of: #"^\d+\.\s"#, options: .regularExpression) {
            return String(line[range.upperBound...])
        }
        return line
    }

    /// インライン Markdown 記法を除去してプレーンテキストにする（TTS 用）
    static func stripInlineMarkdown(_ text: String) -> String {
        var result = text
        // 太字+斜体 (***text*** or ___text___)
        result = result.replacingOccurrences(
            of: #"\*\*\*(.+?)\*\*\*"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"___(.+?)___"#, with: "$1", options: .regularExpression)
        // 太字 (**text** or __text__)
        result = result.replacingOccurrences(
            of: #"\*\*(.+?)\*\*"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"__(.+?)__"#, with: "$1", options: .regularExpression)
        // 斜体 (*text* or _text_)
        result = result.replacingOccurrences(
            of: #"\*(.+?)\*"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"\b_(.+?)_\b"#, with: "$1", options: .regularExpression)
        // インラインコード (`code`)
        result = result.replacingOccurrences(
            of: #"`(.+?)`"#, with: "$1", options: .regularExpression)
        // リンク [text](url)
        result = result.replacingOccurrences(
            of: #"\[(.+?)\]\(.+?\)"#, with: "$1", options: .regularExpression)
        // 画像 ![alt](url)
        result = result.replacingOccurrences(
            of: #"!\[(.+?)\]\(.+?\)"#, with: "$1", options: .regularExpression)
        return result
    }
}
