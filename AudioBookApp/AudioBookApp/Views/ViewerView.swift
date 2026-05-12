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
    @State private var isFullscreen = false

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
            #if os(macOS)
            IrodoriTTSService.shared.clearCache()
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
            // タイトルバー（全画面時は非表示）
            if !isFullscreen {
                titleBar(book: book)
                Divider()
            }

            // ページコンテンツ
            #if os(iOS)
            TabView(selection: $currentPageIndex) {
                ForEach(Array(book.pages.enumerated()), id: \.offset) { index, page in
                    ZoomableContainer(pageIndex: currentPageIndex) {
                        pageContent(page: page, book: book)
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onChange(of: currentPageIndex) { oldValue, newValue in
                guard oldValue != newValue else { return }
                audioManager.stop()
                loadPageAudio()
                saveReadingPosition()
            }
            #else
            pageContent(page: book.pages[currentPageIndex], book: book)
            #endif

            // プレイヤーコントロール（全画面時は非表示）
            if !isFullscreen {
                Divider()
                PlayerControlsView(
                    audioManager: audioManager,
                    pageIndex: currentPageIndex,
                    totalPages: book.pages.count,
                    onPrevPage: { goToPage(currentPageIndex - 1) },
                    onNextPage: { goToPage(currentPageIndex + 1) },
                    onPageChange: { goToPage($0) }
                )
            }
        }
        #if os(macOS)
        .frame(minWidth: 800, minHeight: 600)
        #endif
        #if os(iOS)
        .statusBarHidden(isFullscreen)
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

    // MARK: - Title Bar

    private func titleBar(book: Book) -> some View {
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
                    loadPageAudio()
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
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
    }

    // MARK: - Page Content

    @ViewBuilder
    private func pageContent(page: Page, book: Book) -> some View {
        if page.isMarkdownPage {
            PageMarkdownView(
                blocks: page.blocks,
                activeBlockId: audioManager.activeBlockId,
                onBlockTapped: { block in
                    audioManager.seekToBlock(block)
                },
                onBackgroundTapped: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isFullscreen.toggle()
                    }
                }
            )
        } else {
            PageImageView(
                imagePath: page.imagePath ?? "",
                blocks: page.blocks,
                activeBlockId: audioManager.activeBlockId,
                onBlockTapped: { block in
                    audioManager.seekToBlock(block)
                },
                onBackgroundTapped: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isFullscreen.toggle()
                    }
                }
            )
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
