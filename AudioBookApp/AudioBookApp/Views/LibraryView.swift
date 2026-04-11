import SwiftUI

struct LibraryView: View {
    @Bindable var libraryManager: LibraryManager
    var onBookSelected: (BookEntry) -> Void

    @State private var showAddBook = false
    @State private var bookToDelete: BookEntry?
    @State private var showDeleteConfirm = false

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
                                        if entry.status == .ready {
                                            onBookSelected(entry)
                                        }
                                    }
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            bookToDelete = entry
                                            showDeleteConfirm = true
                                        } label: {
                                            Label("削除", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        .padding(24)
                    }
                }
            }
            .navigationTitle("ライブラリ")
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
        }
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
    }

    // MARK: - Empty state

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("ライブラリに本がありません")
                .font(.title2)
            Text("「+」ボタンで本を追加してください")
                .foregroundStyle(.secondary)
            Button("本を追加") {
                showAddBook = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
