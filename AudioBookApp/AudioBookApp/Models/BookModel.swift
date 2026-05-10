import Foundation

struct TextBlock: Codable, Identifiable {
    let id: Int
    let text: String
    let bbox: [Double]?
    let confidence: Double
    let isVertical: Bool
    let type: String
    var audioStart: Double?
    var audioEnd: Double?

    // Markdown 固有フィールド
    let markdownType: String?    // "heading", "paragraph", "list_item", "code_block", "blockquote"
    let headingLevel: Int?       // 1-6 (見出しの場合)
    let rawMarkdown: String?     // 元の Markdown テキスト（表示用）

    /// 本文として読み上げるべきブロックかどうか（設定に基づく）
    @MainActor var isReadable: Bool {
        ReadingSettings.shared.shouldRead(block: self)
    }

    enum CodingKeys: String, CodingKey {
        case id, text, bbox, confidence, type
        case isVertical = "is_vertical"
        case audioStart = "audio_start"
        case audioEnd = "audio_end"
        case markdownType = "markdown_type"
        case headingLevel = "heading_level"
        case rawMarkdown = "raw_markdown"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        bbox = try container.decodeIfPresent([Double].self, forKey: .bbox)
        confidence = try container.decode(Double.self, forKey: .confidence)
        isVertical = try container.decode(Bool.self, forKey: .isVertical)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "本文"
        audioStart = try container.decodeIfPresent(Double.self, forKey: .audioStart)
        audioEnd = try container.decodeIfPresent(Double.self, forKey: .audioEnd)
        markdownType = try container.decodeIfPresent(String.self, forKey: .markdownType)
        headingLevel = try container.decodeIfPresent(Int.self, forKey: .headingLevel)
        rawMarkdown = try container.decodeIfPresent(String.self, forKey: .rawMarkdown)
    }

    /// プログラムから直接生成するための init（Markdown パーサー用）
    init(id: Int, text: String, bbox: [Double]? = nil, confidence: Double = 1.0,
         isVertical: Bool = false, type: String = "本文",
         audioStart: Double? = nil, audioEnd: Double? = nil,
         markdownType: String? = nil, headingLevel: Int? = nil, rawMarkdown: String? = nil) {
        self.id = id
        self.text = text
        self.bbox = bbox
        self.confidence = confidence
        self.isVertical = isVertical
        self.type = type
        self.audioStart = audioStart
        self.audioEnd = audioEnd
        self.markdownType = markdownType
        self.headingLevel = headingLevel
        self.rawMarkdown = rawMarkdown
    }
}

struct Page: Codable {
    let pageNumber: Int
    var imagePath: String?
    var audioPath: String?
    var blocks: [TextBlock]
    let contentType: String?  // "image" or "markdown"

    var isMarkdownPage: Bool {
        contentType == "markdown" || imagePath == nil
    }

    enum CodingKeys: String, CodingKey {
        case pageNumber = "page_number"
        case imagePath = "image_path"
        case audioPath = "audio_path"
        case blocks
        case contentType = "content_type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageNumber = try container.decode(Int.self, forKey: .pageNumber)
        imagePath = try container.decodeIfPresent(String.self, forKey: .imagePath)
        audioPath = try container.decodeIfPresent(String.self, forKey: .audioPath)
        blocks = try container.decode([TextBlock].self, forKey: .blocks)
        contentType = try container.decodeIfPresent(String.self, forKey: .contentType)
    }

    /// プログラムから直接生成するための init（Markdown パーサー用）
    init(pageNumber: Int, imagePath: String? = nil, audioPath: String? = nil,
         blocks: [TextBlock], contentType: String? = nil) {
        self.pageNumber = pageNumber
        self.imagePath = imagePath
        self.audioPath = audioPath
        self.blocks = blocks
        self.contentType = contentType
    }
}

struct Book: Codable {
    let title: String
    var pages: [Page]
}

/// book.json を読み込み、パスを解決する
func loadBook(from url: URL) throws -> Book {
    let data = try Data(contentsOf: url)
    var book = try JSONDecoder().decode(Book.self, from: data)
    let baseDir = url.deletingLastPathComponent()

    for i in book.pages.indices {
        if let imgPath = book.pages[i].imagePath {
            book.pages[i].imagePath = resolvePath(imgPath, base: baseDir)
        }
        if let audio = book.pages[i].audioPath {
            book.pages[i].audioPath = resolvePath(audio, base: baseDir)
        }
    }
    return book
}

private func resolvePath(_ path: String, base: URL) -> String {
    if path.hasPrefix("/") {
        // 絶対パスでも、実行環境と異なる場合がある（例: Macで生成→iPhoneで参照）。
        // ファイルが存在しなければ、ファイル名だけ取り出して base 基準で解決する。
        if FileManager.default.fileExists(atPath: path) {
            return path
        }
        // "pages/foo.jpg" のように book.json からの相対部分を復元
        let fileName = (path as NSString).lastPathComponent
        // 親ディレクトリ名も含めて解決（例: pages/foo.jpg）
        let parentDir = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let resolved = base.appendingPathComponent(parentDir).appendingPathComponent(fileName).path
        if FileManager.default.fileExists(atPath: resolved) {
            return resolved
        }
        // フォールバック: ファイル名だけで解決
        return base.appendingPathComponent(fileName).path
    }
    return base.appendingPathComponent(path).path
}
