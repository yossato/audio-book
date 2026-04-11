import SwiftUI

/// ビューア画面。
/// `entry` を渡した場合は LibraryManager に読書位置を保存する。
/// `--book` コマンドライン引数からも利用できるよう、URL 直接指定も受け付ける。
struct ViewerView: View {
    let bookURL: URL
    var entry: BookEntry? = nil
    var libraryManager: LibraryManager? = nil
    var onClose: (() -> Void)? = nil

    @State private var book: Book?
    @State private var currentPageIndex = 0
    @State private var audioManager = AudioPlayerManager()

    var body: some View {
        Group {
            if let book {
                viewerContent(book: book)
            } else {
                ProgressView("読み込み中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            loadContent()
        }
        .onDisappear {
            saveReadingPosition()
            audioManager.stop()
        }
    }

    // MARK: - Load

    private func loadContent() {
        do {
            book = try loadBook(from: bookURL)
            // 前回の読書位置を復元
            if let entry {
                let page = min(entry.lastReadPage, (book?.pages.count ?? 1) - 1)
                currentPageIndex = max(0, page)
            }
            loadPageAudio()
        } catch {
            print("[ViewerView] book.json 読み込み失敗: \(error)")
        }
    }

    // MARK: - Viewer Content

    private func viewerContent(book: Book) -> some View {
        VStack(spacing: 0) {
            // タイトルバー（ライブラリから開いた場合のみ「戻る」を表示）
            if onClose != nil {
                HStack {
                    Button {
                        onClose?()
                    } label: {
                        Label("ライブラリ", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Text(book.title)
                        .fontWeight(.semibold)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)

                Divider()
            }

            // ページ画像 + バウンディングボックス
            let page = book.pages[currentPageIndex]
            PageImageView(
                imagePath: page.imagePath,
                blocks: page.blocks,
                activeBlockId: audioManager.activeBlockId,
                onBlockTapped: { block in
                    audioManager.seekToBlock(block)
                }
            )

            Divider()

            // 再生コントロール
            PlayerControlsView(
                audioManager: audioManager,
                pageIndex: currentPageIndex,
                totalPages: book.pages.count,
                onPrevPage: { goToPage(currentPageIndex - 1) },
                onNextPage: { goToPage(currentPageIndex + 1) }
            )
        }
        .frame(minWidth: 800, minHeight: 600)
        .onAppear {
            audioManager.onPlaybackFinished = {
                if currentPageIndex < (self.book?.pages.count ?? 0) - 1 {
                    goToPage(currentPageIndex + 1)
                    audioManager.play()
                }
            }
        }
    }

    // MARK: - Page Navigation

    private func goToPage(_ index: Int) {
        guard let book, index >= 0, index < book.pages.count else { return }
        audioManager.stop()
        currentPageIndex = index
        loadPageAudio()
        saveReadingPosition()
    }

    private func loadPageAudio() {
        guard let book else { return }
        let page = book.pages[currentPageIndex]
        if let audioPath = page.audioPath {
            let url = URL(fileURLWithPath: audioPath)
            audioManager.loadAudio(url: url, blocks: page.blocks)
            audioManager.updateNowPlaying(
                title: book.title,
                pageInfo: "ページ \(currentPageIndex + 1) / \(book.pages.count)"
            )
        }
    }

    // MARK: - Reading Position

    private func saveReadingPosition() {
        guard let entry, let libraryManager else { return }
        libraryManager.updateReadingPosition(
            bookId: entry.id,
            page: currentPageIndex,
            position: audioManager.currentTime
        )
    }
}
