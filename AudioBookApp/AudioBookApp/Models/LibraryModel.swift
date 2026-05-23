import Foundation

// MARK: - BookStatus

enum BookStatus: String, Codable {
    case importing
    case ocrProcessing = "ocr_processing"
    case ttsProcessing = "tts_processing"
    case ready
    case error
}

// MARK: - BookEntry

struct BookEntry: Codable, Identifiable {
    var id: String
    var title: String
    var directory: String       // library root からの相対パス
    var cover: String?          // library root からの相対パス
    var pageCount: Int
    var lastReadPage: Int
    var lastReadPosition: Double
    var lastReadBlockId: Int
    var isMarkdown: Bool
    var status: BookStatus
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, title, directory, cover
        case pageCount = "page_count"
        case lastReadPage = "last_read_page"
        case lastReadPosition = "last_read_position"
        case lastReadBlockId = "last_read_block_id"
        case isMarkdown = "is_markdown"
        case status
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        directory = try container.decode(String.self, forKey: .directory)
        cover = try container.decodeIfPresent(String.self, forKey: .cover)
        pageCount = try container.decode(Int.self, forKey: .pageCount)
        lastReadPage = try container.decode(Int.self, forKey: .lastReadPage)
        lastReadPosition = try container.decode(Double.self, forKey: .lastReadPosition)
        lastReadBlockId = try container.decodeIfPresent(Int.self, forKey: .lastReadBlockId) ?? 0
        isMarkdown = try container.decodeIfPresent(Bool.self, forKey: .isMarkdown) ?? false
        status = try container.decode(BookStatus.self, forKey: .status)
        createdAt = try container.decode(String.self, forKey: .createdAt)
    }

    init(id: String, title: String, directory: String, cover: String?,
         pageCount: Int, lastReadPage: Int, lastReadPosition: Double,
         lastReadBlockId: Int = 0, isMarkdown: Bool = false,
         status: BookStatus, createdAt: String) {
        self.id = id
        self.title = title
        self.directory = directory
        self.cover = cover
        self.pageCount = pageCount
        self.lastReadPage = lastReadPage
        self.lastReadPosition = lastReadPosition
        self.lastReadBlockId = lastReadBlockId
        self.isMarkdown = isMarkdown
        self.status = status
        self.createdAt = createdAt
    }
}

// MARK: - LibraryData

struct LibraryData: Codable {
    var books: [BookEntry]

    init(books: [BookEntry] = []) {
        self.books = books
    }
}
