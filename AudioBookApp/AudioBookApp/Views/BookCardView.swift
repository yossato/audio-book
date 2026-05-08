import SwiftUI

struct BookCardView: View {
    let entry: BookEntry
    let coverURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // カバー画像
            coverImageView
                .frame(width: 160, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(radius: 4)
                .overlay(statusOverlay, alignment: .topTrailing)

            // タイトル
            Text(entry.title)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(2)
                .frame(width: 160, alignment: .leading)

            // 進捗・ページ情報
            progressLabel
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)
        }
        .opacity(isInteractable ? 1.0 : 0.6)
    }

    // MARK: - Cover Image

    @ViewBuilder
    private var coverImageView: some View {
        if let url = coverURL,
           let image = loadPlatformImage(contentsOf: url) {
            swiftUIImage(from: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.2))
                .overlay(
                    Image(systemName: "book.closed")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                )
        }
    }

    // MARK: - Status Overlay

    @ViewBuilder
    private var statusOverlay: some View {
        switch entry.status {
        case .ready:
            EmptyView()
        case .importing, .ocrProcessing, .ttsProcessing:
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.7)
                .padding(6)
                .background(.regularMaterial, in: Circle())
                .padding(6)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .padding(8)
                .background(.regularMaterial, in: Circle())
                .padding(6)
        }
    }

    // MARK: - Progress Label

    private var progressLabel: some View {
        Group {
            switch entry.status {
            case .ready:
                if entry.pageCount > 0 {
                    if entry.lastReadPage > 0 {
                        Text("\(entry.lastReadPage + 1) / \(entry.pageCount) P")
                    } else {
                        Text("\(entry.pageCount) P")
                    }
                } else {
                    Text("既読なし")
                }
            case .importing:
                Text("画像コピー中...")
            case .ocrProcessing:
                Text("OCR 処理中...")
            case .ttsProcessing:
                Text("音声生成中...")
            case .error:
                Text("処理エラー")
                    .foregroundStyle(.red)
            }
        }
    }

    private var isInteractable: Bool {
        entry.status == .ready
    }
}
