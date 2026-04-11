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
    var status: BookStatus
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, title, directory, cover
        case pageCount = "page_count"
        case lastReadPage = "last_read_page"
        case lastReadPosition = "last_read_position"
        case status
        case createdAt = "created_at"
    }
}

// MARK: - LibraryData

struct LibraryData: Codable {
    var books: [BookEntry]

    init(books: [BookEntry] = []) {
        self.books = books
    }
}
