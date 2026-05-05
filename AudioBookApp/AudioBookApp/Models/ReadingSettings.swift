import Foundation

/// 読み上げ設定を管理する。設定は UserDefaults に永続化される。
@Observable @MainActor
final class ReadingSettings {
    static let shared = ReadingSettings()

    /// TYPE 別のスキップ設定（true = 読み飛ばす）
    var skippedTypes: Set<String> {
        didSet { save() }
    }

    /// OCR エラーパターンを読み飛ばすかどうか
    var skipOCRErrors: Bool {
        didSet { save() }
    }

    /// ndlocr-lite で使用される全 TYPE 一覧
    static let allTypes = ["本文", "タイトル本文", "割注", "キャプション", "広告文字",
                           "柱", "ノンブル", "ルビ", "図版", "組織図", "数式", "表組"]

    /// TYPE の日本語表示名
    static let typeDisplayNames: [String: String] = [
        "本文": "本文",
        "タイトル本文": "タイトル・見出し",
        "割注": "割注（注釈）",
        "キャプション": "キャプション（図表説明）",
        "広告文字": "広告文字",
        "柱": "柱（ヘッダー/フッター）",
        "ノンブル": "ノンブル（ページ番号）",
        "ルビ": "ルビ",
        "図版": "図版",
        "組織図": "組織図",
        "数式": "数式",
        "表組": "表組",
    ]

    private let skippedTypesKey = "ReadingSettings.skippedTypes"
    private let skipOCRErrorsKey = "ReadingSettings.skipOCRErrors"

    private init() {
        if let saved = UserDefaults.standard.stringArray(forKey: skippedTypesKey) {
            skippedTypes = Set(saved)
        } else {
            // デフォルト: 割注とキャプションを読み飛ばす
            skippedTypes = ["割注", "キャプション", "柱", "ノンブル", "ルビ", "図版", "広告文字"]
        }
        skipOCRErrors = UserDefaults.standard.object(forKey: skipOCRErrorsKey) as? Bool ?? true
    }

    private func save() {
        UserDefaults.standard.set(Array(skippedTypes), forKey: skippedTypesKey)
        UserDefaults.standard.set(skipOCRErrors, forKey: skipOCRErrorsKey)
    }

    /// ブロックを読み上げるべきかどうか判定する
    func shouldRead(block: TextBlock) -> Bool {
        // TYPE によるスキップ
        if skippedTypes.contains(block.type) {
            return false
        }
        // OCR エラーパターンによるスキップ
        if skipOCRErrors && isOCRError(text: block.text) {
            return false
        }
        return true
    }

    /// OCR エラーパターンの判定
    private func isOCRError(text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }

        // 同一文字が5回以上連続するパターン（例: 0,,0000000）
        let chars = Array(trimmed)
        var maxRepeat = 1
        var currentRepeat = 1
        for i in 1..<chars.count {
            if chars[i] == chars[i - 1] {
                currentRepeat += 1
                maxRepeat = max(maxRepeat, currentRepeat)
            } else {
                currentRepeat = 1
            }
        }
        if maxRepeat >= 5 {
            return true
        }

        // 句読点・記号のみで構成される短いテキスト
        let symbolSet = CharacterSet.punctuationCharacters
            .union(.symbols)
            .union(CharacterSet(charactersIn: "0123456789,，.。、"))
        if trimmed.count <= 3 && trimmed.unicodeScalars.allSatisfy({ symbolSet.contains($0) }) {
            return true
        }

        return false
    }
}
