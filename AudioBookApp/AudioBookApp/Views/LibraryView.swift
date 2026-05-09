import SwiftUI

struct LibraryView: View {
    @Bindable var libraryManager: LibraryManager
    var onBookSelected: (BookEntry) -> Void

    #if os(macOS)
    @State private var showAddBook = false
    @State private var bookToDelete: BookEntry?
    @State private var showDeleteConfirm = false
    #else
    @State private var showFolderPicker = false
    #endif

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 20)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if libraryManager.books.isEmpty {
                    emptyStateView
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 24) {
                            ForEach(libraryManager.books) { entry in
                                BookCardView(entry: entry,
                                             coverURL: libraryManager.coverImageURL(for: entry))
                                    .onTapGesture {
                                        if entry.status == .ready || entry.status == .error {
                                            onBookSelected(entry)
                                        }
                                    }
                                    #if os(macOS)
                                    .overlay(alignment: .bottom) {
                                        if libraryManager.ttsGeneratingBookId == entry.id,
                                           let progress = libraryManager.ttsProgress {
                                            Text(progress.displayText)
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(.ultraThinMaterial)
                                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                                .padding(.bottom, 4)
                                        }
                                    }
                                    .contextMenu {
                                        if entry.status == .ready || entry.status == .error {
                                            Button {
                                                libraryManager.generateBatchTTS(entry: entry)
                                            } label: {
                                                Label("Irodori TTSで音声を生成", systemImage: "waveform")
                                            }
                                        }
                                        if libraryManager.ttsGeneratingBookId == entry.id {
                                            Button(role: .destructive) {
                                                libraryManager.cancelBatchTTS()
                                            } label: {
                                                Label("TTS生成をキャンセル", systemImage: "xmark.circle")
                                            }
                                        }
                                        Button(role: .destructive) {
                                            bookToDelete = entry
                                            showDeleteConfirm = true
                                        } label: {
                                            Label("削除", systemImage: "trash")
                                        }
                                    }
                                    #endif
                            }
                        }
                        .padding(24)
                    }
                }
            }
            .navigationTitle("ライブラリ")
            #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showAddBook = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("本を追加")
                }
            }
            #else
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showFolderPicker = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .help("ライブラリフォルダを選択")
                }
            }
            .fileImporter(
                isPresented: $showFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        libraryManager.setExternalFolder(url: url)
                    }
                case .failure(let error):
                    print("[LibraryView] Folder picker error: \(error)")
                }
            }
            #endif
        }
        #if os(macOS)
        .sheet(isPresented: $showAddBook) {
            AddBookView(libraryManager: libraryManager)
        }
        .confirmationDialog(
            "「\(bookToDelete?.title ?? "")」を削除しますか？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                if let entry = bookToDelete {
                    libraryManager.deleteBook(entry)
                }
                bookToDelete = nil
            }
            Button("キャンセル", role: .cancel) {
                bookToDelete = nil
            }
        } message: {
            Text("この操作は取り消せません。音声・OCRデータも含めてすべて削除されます。")
        }
        .frame(minWidth: 600, minHeight: 400)
        #endif
    }

    // MARK: - Empty state

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("ライブラリに本がありません")
                .font(.title2)
            #if os(macOS)
            Text("「+」ボタンで本を追加してください")
                .foregroundStyle(.secondary)
            Button("本を追加") {
                showAddBook = true
            }
            .buttonStyle(.borderedProminent)
            #else
            Text("右上のフォルダボタンから\niCloud Driveのライブラリを選択してください")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("フォルダを選択") {
                showFolderPicker = true
            }
            .buttonStyle(.borderedProminent)
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
