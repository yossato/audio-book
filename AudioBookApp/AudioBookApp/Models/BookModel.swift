import Foundation

struct TextBlock: Codable, Identifiable {
    let id: Int
    let text: String
    let bbox: [Double]
    let confidence: Double
    let isVertical: Bool
    let type: String
    var audioStart: Double?
    var audioEnd: Double?

    /// 本文として読み上げるべきブロックかどうか
    var isReadable: Bool {
        type == "本文" || type == "タイトル本文"
    }

    enum CodingKeys: String, CodingKey {
        case id, text, bbox, confidence, type
        case isVertical = "is_vertical"
        case audioStart = "audio_start"
        case audioEnd = "audio_end"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        bbox = try container.decode([Double].self, forKey: .bbox)
        confidence = try container.decode(Double.self, forKey: .confidence)
        isVertical = try container.decode(Bool.self, forKey: .isVertical)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "本文"
        audioStart = try container.decodeIfPresent(Double.self, forKey: .audioStart)
        audioEnd = try container.decodeIfPresent(Double.self, forKey: .audioEnd)
    }
}

struct Page: Codable {
    let pageNumber: Int
    var imagePath: String
    var audioPath: String?
    var blocks: [TextBlock]

    enum CodingKeys: String, CodingKey {
        case pageNumber = "page_number"
        case imagePath = "image_path"
        case audioPath = "audio_path"
        case blocks
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
        book.pages[i].imagePath = resolvePath(book.pages[i].imagePath, base: baseDir)
        if let audio = book.pages[i].audioPath {
            book.pages[i].audioPath = resolvePath(audio, base: baseDir)
        }
    }
    return book
}

private func resolvePath(_ path: String, base: URL) -> String {
    if path.hasPrefix("/") {
        return path
    }
    return base.appendingPathComponent(path).path
}
