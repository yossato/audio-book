import SwiftUI

/// Markdown ページのリッチテキスト表示ビュー
struct PageMarkdownView: View {
    let blocks: [TextBlock]
    let activeBlockId: Int
    var onBlockTapped: ((TextBlock) -> Void)?
    var onBackgroundTapped: (() -> Void)?

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
}
