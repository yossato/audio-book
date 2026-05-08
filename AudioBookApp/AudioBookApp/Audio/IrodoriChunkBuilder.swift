#if os(macOS)
import Foundation

/// Irodori TTS 用のチャンク（複数の SpeechGroup を結合して 60〜200 文字にまとめたもの）
struct IrodoriChunk {
    let text: String
    let blockRanges: [IrodoriBlockRange]  // sorted ascending by charOffset
}

/// チャンク内でのブロック位置情報
struct IrodoriBlockRange {
    let charOffset: Int   // チャンク内での文字オフセット (Character count)
    let blockId: Int
}

/// テキストブロックを Irodori TTS に適したチャンクサイズに結合する
enum IrodoriChunkBuilder {

    /// 最小チャンクサイズ (文字数) - これより短いと RTF が悪化する
    static let minChunkSize = 60
    /// 最大チャンクサイズ (文字数) - これ以上長いと生成時間が長くなりすぎる
    static let maxChunkSize = 200

    /// ブロック列からチャンクを構築する
    /// - Parameter blocks: 読み上げ対象のテキストブロック (フィルタ済み)
    /// - Returns: Irodori TTS 用チャンク列
    static func buildChunks(from blocks: [TextBlock]) -> [IrodoriChunk] {
        let sentenceEnders: Set<Character> = ["。", "！", "？"]
        var chunks: [IrodoriChunk] = []

        // まず句読点単位のセグメントに分割
        var segments: [(text: String, blockRanges: [IrodoriBlockRange])] = []
        var currentText = ""
        var currentCharCount = 0
        var currentBlockRanges: [IrodoriBlockRange] = []

        for block in blocks {
            let processed = preprocessBlockText(block.text)
            guard !processed.isEmpty else { continue }

            var blockStarted = false
            for char in processed {
                if !blockStarted {
                    currentBlockRanges.append(IrodoriBlockRange(charOffset: currentCharCount, blockId: block.id))
                    blockStarted = true
                }
                currentText.append(char)
                currentCharCount += 1
                if sentenceEnders.contains(char) {
                    if !currentText.isEmpty {
                        segments.append((text: currentText, blockRanges: currentBlockRanges))
                    }
                    currentText = ""
                    currentCharCount = 0
                    currentBlockRanges = []
                    blockStarted = false
                }
            }
        }
        // 残りのテキスト
        if !currentText.isEmpty {
            segments.append((text: currentText, blockRanges: currentBlockRanges))
        }

        // セグメントを結合してチャンクにする
        var chunkText = ""
        var chunkCharCount = 0
        var chunkBlockRanges: [IrodoriBlockRange] = []

        for segment in segments {
            // このセグメントを追加すると maxChunkSize を超える場合、現在のチャンクを確定
            if chunkCharCount > 0 && chunkCharCount + segment.text.count > maxChunkSize {
                chunks.append(IrodoriChunk(text: chunkText, blockRanges: chunkBlockRanges))
                chunkText = ""
                chunkCharCount = 0
                chunkBlockRanges = []
            }

            // セグメントの blockRanges をチャンク内オフセットに調整して追加
            for range in segment.blockRanges {
                chunkBlockRanges.append(IrodoriBlockRange(
                    charOffset: chunkCharCount + range.charOffset,
                    blockId: range.blockId
                ))
            }
            chunkText += segment.text
            chunkCharCount += segment.text.count

            // minChunkSize に達して句読点で終わっていればチャンクを確定
            if chunkCharCount >= minChunkSize && chunkText.last.map({ sentenceEnders.contains($0) }) == true {
                chunks.append(IrodoriChunk(text: chunkText, blockRanges: chunkBlockRanges))
                chunkText = ""
                chunkCharCount = 0
                chunkBlockRanges = []
            }
        }

        // 残りのテキストをチャンクに
        if !chunkText.isEmpty {
            chunks.append(IrodoriChunk(text: chunkText, blockRanges: chunkBlockRanges))
        }

        return chunks
    }

    /// ブロックテキストの前処理（改行除去、トリム）
    private static func preprocessBlockText(_ text: String) -> String {
        var result = ""
        for char in text where char != "\n" && char != "\r" {
            result.append(char)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
#endif
