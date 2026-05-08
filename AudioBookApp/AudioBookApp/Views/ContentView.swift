import SwiftUI

/// アプリのナビゲーションルート。
/// - `--book <path>` が渡された場合はビューアを直接表示
/// - それ以外はライブラリ画面を表示し、本を選択するとビューアへ遷移
struct ContentView: View {
    @State private var libraryManager = LibraryManager()
    @State private var selectedEntry: BookEntry?
    @State private var directBookURL: URL?  // --book 引数用

    var body: some View {
        Group {
            if let url = directBookURL {
                // --book モード: ライブラリ不使用
                ViewerView(bookURL: url)
            } else if let entry = selectedEntry {
                // ライブラリから本を開いた
                ViewerView(
                    bookURL: libraryManager.bookJSONURL(for: entry),
                    entry: entry,
                    libraryManager: libraryManager,
                    onClose: { selectedEntry = nil }
                )
            } else {
                // ライブラリ画面
                LibraryView(libraryManager: libraryManager) { entry in
                    selectedEntry = entry
                }
            }
        }
        .onAppear {
            #if os(macOS)
            loadFromCommandLine()
            #endif
        }
    }

    #if os(macOS)
    private func loadFromCommandLine() {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--book"), idx + 1 < args.count {
            directBookURL = URL(fileURLWithPath: args[idx + 1])
        }
    }
    #endif
}
