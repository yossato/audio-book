import SwiftUI

/// Markdown ページのリッチテキスト表示ビュー
struct PageMarkdownView: View {
    let blocks: [TextBlock]
    let activeBlockId: Int
    var initialScrollBlockId: Int?
    var onBlockTapped: ((TextBlock) -> Void)?
    var onBackgroundTapped: (() -> Void)?

    @State private var hasScrolledToInitial = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(blocks) { block in
                        markdownBlockView(block: block)
                            .id(block.id)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                            .background(
                                block.id == activeBlockId
                                    ? Color.yellow.opacity(0.3)
                                    : Color.clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard block.isReadable else { return }
                                onBlockTapped?(block)
                            }
                    }
                }
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onBackgroundTapped?()
                        }
                )
            }
            .onAppear {
                // 前回の読書位置にスクロール
                if !hasScrolledToInitial, let blockId = initialScrollBlockId, blockId > 0 {
                    hasScrolledToInitial = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        proxy.scrollTo(blockId, anchor: .top)
                    }
                }
            }
            .onChange(of: activeBlockId) { _, newId in
                guard newId >= 0 else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(newId, anchor: .center)
                }
            }
        }
        #if canImport(AppKit)
        .background(Color(nsColor: .textBackgroundColor))
        #else
        .background(Color(uiColor: .systemBackground))
        #endif
    }

    // MARK: - Block Rendering

    @ViewBuilder
    private func markdownBlockView(block: TextBlock) -> some View {
        switch block.markdownType {
        case "heading":
            headingView(block: block)
        case "code_block":
            codeBlockView(block: block)
        case "blockquote":
            blockquoteView(block: block)
        case "list_item":
            listItemView(block: block)
        case "image":
            imageView(block: block)
        case "mermaid":
            MermaidView(code: block.text)
        case "table":
            tableView(block: block)
        case "hr":
            Divider()
                .padding(.vertical, 4)
        default:
            paragraphView(block: block)
        }
    }

    private func headingView(block: TextBlock) -> some View {
        let level = block.headingLevel ?? 2
        let fontSize: CGFloat = switch level {
        case 1: 28
        case 2: 24
        case 3: 20
        case 4: 18
        default: 16
        }
        return Text(block.text)
            .font(.system(size: fontSize, weight: .bold))
            .padding(.top, level <= 2 ? 8 : 4)
    }

    private func paragraphView(block: TextBlock) -> some View {
        Group {
            if let rawMd = block.rawMarkdown,
               let attributed = try? AttributedString(markdown: rawMd) {
                Text(attributed)
                    .font(.body)
            } else {
                Text(block.text)
                    .font(.body)
            }
        }
        .lineSpacing(4)
    }

    private func codeBlockView(block: TextBlock) -> some View {
        Text(block.text)
            .font(.system(.body, design: .monospaced))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func blockquoteView(block: TextBlock) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.gray.opacity(0.4))
                .frame(width: 4)
            Text(block.text)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 8)
    }

    private func listItemView(block: TextBlock) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(.body)
                .foregroundStyle(.secondary)
            Group {
                if let rawMd = block.rawMarkdown,
                   let attributed = try? AttributedString(markdown: rawMd) {
                    Text(attributed)
                        .font(.body)
                } else {
                    Text(block.text)
                        .font(.body)
                }
            }
            .lineSpacing(4)
        }
        .padding(.leading, 12)
    }

    private func imageView(block: TextBlock) -> some View {
        Group {
            if let path = block.imagePath, let img = loadImage(from: path) {
                img
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .cornerRadius(4)
            } else {
                // 画像が見つからない場合は alt テキストを表示
                Text(block.text.isEmpty ? "画像" : block.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(Color.gray.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    @ViewBuilder
    private func tableView(block: TextBlock) -> some View {
        let rows = parseTableRows(block.rawMarkdown ?? "")
        if rows.isEmpty {
            Text(block.text).font(.body)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Group {
                                if let attr = try? AttributedString(markdown: cell) {
                                    Text(attr)
                                        .font(rowIndex == 0 ? .system(.body, weight: .bold) : .body)
                                } else {
                                    Text(cell)
                                        .font(rowIndex == 0 ? .system(.body, weight: .bold) : .body)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(rowIndex == 0
                                ? Color.gray.opacity(0.15)
                                : (rowIndex % 2 == 0 ? Color.gray.opacity(0.05) : Color.clear))
                        }
                    }
                    if rowIndex < rows.count - 1 {
                        Divider()
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    /// Markdown テーブルのraw文字列からデータ行を解析する
    private func parseTableRows(_ raw: String) -> [[String]] {
        raw.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard line.hasPrefix("|") else { return false }
                // セパレータ行（|---|---| など）を除外
                let content = line
                    .replacingOccurrences(of: "|", with: "")
                    .replacingOccurrences(of: "-", with: "")
                    .replacingOccurrences(of: ":", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return !content.isEmpty
            }
            .map { line in
                line.components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
            .filter { !$0.isEmpty }
    }

    /// ファイルパスから Image を読み込む（macOS / iOS 共通）
    private func loadImage(from path: String) -> Image? {
        #if canImport(AppKit)
        guard let nsImg = NSImage(contentsOfFile: path) else { return nil }
        return Image(nsImage: nsImg)
        #else
        guard let uiImg = UIImage(contentsOfFile: path) else { return nil }
        return Image(uiImage: uiImg)
        #endif
    }
}
