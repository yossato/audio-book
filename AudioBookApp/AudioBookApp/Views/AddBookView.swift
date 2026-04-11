import SwiftUI

struct AddBookView: View {
    var libraryManager: LibraryManager
    @Environment(\.dismiss) private var dismiss

    // MARK: - 入力
    @State private var title = ""
    @State private var selectedDirectory: URL?

    // Python 設定（UserDefaults で永続化）
    @AppStorage("pythonExecutable") private var pythonExecutable = Self.defaultPythonPath
    @AppStorage("scriptsDirectory") private var scriptsDirectory = Self.defaultScriptsPath

    // MARK: - 処理状態
    @State private var isProcessing = false
    @State private var progressMessage = ""
    @State private var errorMessage = ""
    @State private var showAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
            HStack {
                Text("本を追加")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("キャンセル") { dismiss() }
                    .disabled(isProcessing)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // 画像フォルダ選択
                    sectionHeader("画像フォルダ")
                    HStack {
                        Text(selectedDirectory?.path ?? "未選択")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(selectedDirectory == nil ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("選択...") {
                            selectDirectory()
                        }
                        .disabled(isProcessing)
                    }

                    // タイトル
                    sectionHeader("タイトル")
                    TextField("本のタイトル", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isProcessing)

                    // 詳細設定（折りたたみ可能）
                    DisclosureGroup("詳細設定", isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionHeader("Python 実行ファイル")
                            HStack {
                                TextField("/path/to/python3", text: $pythonExecutable)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(isProcessing)
                                Button("選択...") { pickFile(title: "Python を選択",
                                                            binding: $pythonExecutable) }
                                    .disabled(isProcessing)
                            }

                            sectionHeader("スクリプトディレクトリ")
                            HStack {
                                TextField("/path/to/scripts", text: $scriptsDirectory)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(isProcessing)
                                Button("選択...") { pickScriptsDir() }
                                    .disabled(isProcessing)
                            }
                        }
                        .padding(.top, 8)
                    }

                    // 進捗表示
                    if isProcessing || !progressMessage.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                if isProcessing {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                }
                                Text(progressMessage.isEmpty ? "処理中..." : progressMessage)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                    }

                    // エラー表示
                    if !errorMessage.isEmpty {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
                .padding()
            }

            Divider()

            // フッター
            HStack {
                Spacer()
                Button("追加") {
                    startProcessing()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing || title.isEmpty || selectedDirectory == nil)
            }
            .padding()
        }
        .frame(width: 500, height: 420)
    }

    // MARK: - UI Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(.primary)
    }

    // MARK: - File Picker

    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.title = "画像フォルダを選択"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            selectedDirectory = url
            if title.isEmpty {
                title = url.lastPathComponent
            }
        }
    }

    private func pickFile(title: String, binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }

    private func pickScriptsDir() {
        let panel = NSOpenPanel()
        panel.title = "スクリプトディレクトリを選択"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            scriptsDirectory = url.path
        }
    }

    // MARK: - Processing

    private func startProcessing() {
        guard let dir = selectedDirectory else { return }
        errorMessage = ""
        progressMessage = ""
        isProcessing = true

        libraryManager.addBook(
            title: title,
            sourceImagesDirectory: dir,
            pythonExecutable: pythonExecutable,
            scriptsDirectory: scriptsDirectory,
            onProgress: { msg in
                Task { @MainActor in
                    self.progressMessage = msg
                }
            },
            onComplete: { success, errMsg in
                Task { @MainActor in
                    self.isProcessing = false
                    if success {
                        self.dismiss()
                    } else {
                        self.errorMessage = errMsg
                    }
                }
            }
        )
    }

    // MARK: - Defaults

    static var defaultPythonPath: String {
        let candidates = [
            "\(NSHomeDirectory())/Projects/audio-book/venv/bin/python3",
            "\(NSHomeDirectory())/Projects/audio-book/venv/bin/python",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/usr/bin/python3"
    }

    static var defaultScriptsPath: String {
        return "\(NSHomeDirectory())/Projects/audio-book/scripts"
    }
}
