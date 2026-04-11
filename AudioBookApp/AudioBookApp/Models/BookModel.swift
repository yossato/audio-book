import Foundation

struct TextBlock: Codable, Identifiable {
    let id: Int
    let text: String
    let bbox: [Double]
    let confidence: Double
    let isVertical: Bool
    var audioStart: Double?
    var audioEnd: Double?

    enum CodingKeys: String, CodingKey {
        case id, text, bbox, confidence
        case isVertical = "is_vertical"
        case audioStart = "audio_start"
        case audioEnd = "audio_end"
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
