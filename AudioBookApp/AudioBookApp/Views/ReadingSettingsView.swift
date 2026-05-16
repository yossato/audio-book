import SwiftUI
import UniformTypeIdentifiers

/// 読み上げ設定画面
struct ReadingSettingsView: View {
    @Bindable var settings = ReadingSettings.shared
    var libraryManager: LibraryManager? = nil
    @State private var refVoices: [String] = []

    var body: some View {
        Form {
            #if os(macOS)
            if let libraryManager {
                Section("ライブラリ") {
                    LabeledContent("保存先") {
                        HStack {
                            Text(libraryManager.libraryRoot.path)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 300, alignment: .leading)
                            Button("変更...") {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = true
                                panel.canChooseFiles = false
                                panel.allowsMultipleSelection = false
                                panel.message = "ライブラリフォルダを選択"
                                if panel.runModal() == .OK, let url = panel.url {
                                    libraryManager.setLibraryRoot(path: url.path)
                                }
                            }
                        }
                    }
                    Button("iCloud Drive に設定") {
                        libraryManager.setLibraryRoot(path: LibraryManager.iCloudDrivePath)
                    }
                    .disabled(libraryManager.libraryRoot.path == LibraryManager.iCloudDrivePath)
                }
            }

            Section("TTS エンジン") {
                Picker("音声エンジン", selection: $settings.ttsEngine) {
                    ForEach(TTSEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .pickerStyle(.radioGroup)

                if settings.ttsEngine == .irodori {
                    LabeledContent("サーバー URL") {
                        TextField("http://localhost:8000", text: $settings.irodoriServerURL)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 250)
                    }
                    LabeledContent("Python venv パス") {
                        HStack {
                            TextField("/path/to/mlx-impl/.venv", text: $settings.irodoriVenvPath)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 250)
                            Button("選択...") {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = true
                                panel.canChooseFiles = false
                                panel.allowsMultipleSelection = false
                                panel.message = "mlx-audio がインストールされた .venv フォルダを選択"
                                if panel.runModal() == .OK, let url = panel.url {
                                    settings.irodoriVenvPath = url.path
                                }
                            }
                        }
                    }
                    if let libraryManager {
                        refVoicePicker(libraryManager: libraryManager)
                    } else {
                        LabeledContent("リファレンス音声") {
                            Text(settings.irodoriRefWavPath.isEmpty ? "未設定" : (settings.irodoriRefWavPath as NSString).lastPathComponent)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("リファレンス音声を設定すると、バッチ生成時に話者を固定できます。サーバーはバッチ音声生成時のみ起動します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            #endif

            Section("再生音声") {
                Toggle("生成済み音声を使用", isOn: $settings.usePreGeneratedAudio)
                Text("オフにすると、Irodori TTS で事前生成した音声がある場合でもシステム音声（Say コマンド）で再生します")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("読み飛ばすブロックの種類") {
                ForEach(ReadingSettings.allTypes, id: \.self) { type in
                    let isSkipped = settings.skippedTypes.contains(type)
                    Toggle(
                        ReadingSettings.typeDisplayNames[type] ?? type,
                        isOn: Binding(
                            get: { isSkipped },
                            set: { newValue in
                                if newValue {
                                    settings.skippedTypes.insert(type)
                                } else {
                                    settings.skippedTypes.remove(type)
                                }
                            }
                        )
                    )
                }
            }

            Section("エラー検出") {
                Toggle("OCR エラーパターンを読み飛ばす", isOn: $settings.skipOCRErrors)
                Text("同一文字の連続（例: 0,,0000000）や記号のみのブロックをスキップします")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 500)
        #endif
        .onAppear {
            refVoices = libraryManager?.listRefVoices() ?? []
        }
    }

    // MARK: - Reference Voice Picker

    #if os(macOS)
    @ViewBuilder
    private func refVoicePicker(libraryManager: LibraryManager) -> some View {
        LabeledContent("リファレンス音声") {
            HStack {
                Picker("", selection: Binding(
                    get: {
                        if settings.irodoriRefWavPath.isEmpty { return "" }
                        return (settings.irodoriRefWavPath as NSString).lastPathComponent
                    },
                    set: { filename in
                        if filename.isEmpty {
                            settings.irodoriRefWavPath = ""
                        } else {
                            settings.irodoriRefWavPath = libraryManager.refVoicePath(for: filename)
                        }
                    }
                )) {
                    Text("未設定（ランダム話者）").tag("")
                    if !refVoices.isEmpty {
                        Divider()
                        ForEach(refVoices, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                }
                .frame(width: 200)

                Button("追加...") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.canChooseFiles = true
                    panel.allowsMultipleSelection = true
                    panel.allowedContentTypes = [.wav, .mpeg4Audio, .mp3, .aiff]
                    panel.message = "リファレンス音声ファイルを選択（WAV 推奨）"
                    if panel.runModal() == .OK {
                        for url in panel.urls {
                            if let path = libraryManager.addRefVoice(from: url) {
                                // 最後に追加したものを選択
                                settings.irodoriRefWavPath = path
                            }
                        }
                        refVoices = libraryManager.listRefVoices()
                    }
                }
            }
        }
    }
    #endif
}
