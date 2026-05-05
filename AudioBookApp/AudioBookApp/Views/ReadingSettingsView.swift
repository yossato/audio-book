import SwiftUI

/// 読み上げ設定画面
struct ReadingSettingsView: View {
    @Bindable var settings = ReadingSettings.shared

    var body: some View {
        Form {
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
        .frame(minWidth: 350, minHeight: 400)
    }
}
