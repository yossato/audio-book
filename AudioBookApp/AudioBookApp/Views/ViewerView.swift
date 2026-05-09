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
    @State private var showSettings = false

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
            #if os(macOS)
            startIrodoriServerIfNeeded()
            #endif
        }
        .onDisappear {
            saveReadingPosition()
            audioManager.stop()
            #if os(macOS)
            IrodoriTTSService.shared.clearCache()
            // バッチTTS実行中はサーバーを停止しない
            if libraryManager?.ttsGeneratingBookId == nil {
                IrodoriTTSService.shared.stopServer()
            }
            #endif
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
            HStack {
                if onClose != nil {
                    Button {
                        onClose?()
                    } label: {
                        Label("ライブラリ", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                Text(book.title)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                #if os(macOS)
                .popover(isPresented: $showSettings) {
                    ReadingSettingsView()
                        .frame(width: 480, height: 550)
                }
                #endif
                .onChange(of: showSettings) { _, isShowing in
                    if !isShowing {
                        #if os(macOS)
                        startIrodoriServerIfNeeded()
                        #endif
                        loadPageAudio()
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

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
                onNextPage: { goToPage(currentPageIndex + 1) },
                onPageChange: { goToPage($0) }
            )
        }
        #if os(macOS)
        .frame(minWidth: 800, minHeight: 600)
        #endif
        #if os(iOS)
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                ReadingSettingsView()
                    .navigationTitle("設定")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完了") { showSettings = false }
                        }
                    }
            }
        }
        #endif
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
        let url = page.audioPath.map { URL(fileURLWithPath: $0) }
        audioManager.loadAudio(url: url, blocks: page.blocks)
        audioManager.updateNowPlaying(
            title: book.title,
            pageInfo: "ページ \(currentPageIndex + 1) / \(book.pages.count)"
        )

        #if os(macOS)
        // Irodori TTS: 次ページの先読み生成
        if ReadingSettings.shared.ttsEngine == .irodori {
            pregenerateNextPage()
        }
        #endif
    }

    #if os(macOS)
    /// 次ページのチャンクを先行生成する
    private func pregenerateNextPage() {
        guard let book else { return }
        let nextIndex = currentPageIndex + 1
        guard nextIndex < book.pages.count else { return }
        let nextPage = book.pages[nextIndex]
        if let audioPath = nextPage.audioPath,
           FileManager.default.fileExists(atPath: audioPath) { return }
        let readableBlocks = nextPage.blocks.filter { ReadingSettings.shared.shouldRead(block: $0) }
        let chunks = IrodoriChunkBuilder.buildChunks(from: readableBlocks)
        Task {
            await IrodoriTTSService.shared.pregenerate(chunks: chunks)
        }
    }

    // MARK: - Irodori Server

    private func startIrodoriServerIfNeeded() {
        guard ReadingSettings.shared.ttsEngine == .irodori else { return }
        Task {
            do {
                try await IrodoriTTSService.shared.startServer()
                await IrodoriTTSService.shared.warmup()
                let chunks = audioManager.irodoriChunksForPregeneration
                await IrodoriTTSService.shared.pregenerate(chunks: chunks)
            } catch {
                print("[ViewerView] Irodori サーバー起動失敗: \(error)")
            }
        }
    }
    #endif

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
