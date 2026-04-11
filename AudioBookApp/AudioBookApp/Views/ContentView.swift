import SwiftUI

struct ContentView: View {
    @State private var book: Book?
    @State private var currentPageIndex = 0
    @State private var audioManager = AudioPlayerManager()
    @State private var bookURL: URL?

    var body: some View {
        Group {
            if let book {
                viewerView(book: book)
            } else {
                welcomeView
            }
        }
        .onAppear {
            loadFromCommandLine()
        }
    }

    // MARK: - Welcome (file picker)

    private var welcomeView: some View {
        VStack(spacing: 20) {
            Text("Audio Book Viewer")
                .font(.largeTitle)
            Text("book.json を選択してください")
                .foregroundColor(.secondary)
            Button("ファイルを開く") {
                openFilePanel()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openFilePanel() {
        let panel = NSOpenPanel()
        panel.title = "book.json を選択"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            loadBook(from: url)
        }
    }

    private func loadFromCommandLine() {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--book"), idx + 1 < args.count {
            let path = args[idx + 1]
            let url = URL(fileURLWithPath: path)
            loadBook(from: url)
        }
    }

    private func loadBook(from url: URL) {
        do {
            book = try AudioBookApp_loadBook(from: url)
            bookURL = url
            currentPageIndex = 0
            loadPageAudio()
        } catch {
            print("[ERROR] Failed to load book: \(error)")
        }
    }

    // MARK: - Viewer

    private func viewerView(book: Book) -> some View {
        VStack(spacing: 0) {
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
                // 自動ページ送り
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
}

/// BookModel.swift の loadBook と名前衝突を避けるためのラッパー
func AudioBookApp_loadBook(from url: URL) throws -> Book {
    return try loadBook(from: url)
}
