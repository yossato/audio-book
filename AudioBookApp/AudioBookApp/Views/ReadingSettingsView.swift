import SwiftUI
import UniformTypeIdentifiers

/// 読み上げ設定画面
struct ReadingSettingsView: View {
    @Bindable var settings = ReadingSettings.shared

    var body: some View {
        Form {
            #if os(macOS)
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
                    LabeledContent("リファレンス音声") {
                        HStack {
                            TextField("未設定（ランダム話者）", text: $settings.irodoriRefWavPath)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 250)
                            Button("選択...") {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = false
                                panel.canChooseFiles = true
                                panel.allowsMultipleSelection = false
                                panel.allowedContentTypes = [.wav]
                                panel.message = "話者固定用のリファレンス音声 WAV ファイルを選択"
                                if panel.runModal() == .OK, let url = panel.url {
                                    settings.irodoriRefWavPath = url.path
                                }
                            }
                            if !settings.irodoriRefWavPath.isEmpty {
                                Button("クリア") {
                                    settings.irodoriRefWavPath = ""
                                }
                            }
                        }
                    }
                    Text("mlx-audio サーバーはアプリ起動時に自動起動します。リファレンス音声を設定すると、バッチ生成時に話者を固定できます。")
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
    }
}
