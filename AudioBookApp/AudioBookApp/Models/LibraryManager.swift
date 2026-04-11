import Foundation
import AppKit

// MARK: - グローバルユーティリティ

/// Python スクリプトを非同期実行し、終了コード 0 なら true を返す。
/// `onOutput` は任意スレッドから呼ばれる。
func runProcessAsync(
    executablePath: String,
    arguments: [String],
    onOutput: @escaping @Sendable (String) -> Void
) async -> Bool {
    await withCheckedContinuation { continuation in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let emitLines: @Sendable (Data) -> Void = { data in
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { onOutput(trimmed) }
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            emitLines(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            emitLines(handle.availableData)
        }

        process.terminationHandler = { p in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            continuation.resume(returning: p.terminationStatus == 0)
        }

        do {
            try process.run()
        } catch {
            onOutput("[ERROR] プロセス起動失敗: \(error.localizedDescription)")
            continuation.resume(returning: false)
        }
    }
}

// MARK: - LibraryManager

@MainActor
@Observable
final class LibraryManager {

    // MARK: State

    var books: [BookEntry] = []
    let libraryRoot: URL

    private var libraryJSONURL: URL {
        libraryRoot.appendingPathComponent("library.json")
    }

    // MARK: Init

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let storedPath = UserDefaults.standard.string(forKey: "libraryRootPath")
        if let p = storedPath, !p.isEmpty {
            libraryRoot = URL(fileURLWithPath: p)
        } else {
            libraryRoot = docs.appendingPathComponent("AudioBookLibrary")
        }
        try? FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        loadLibrary()
    }

    // MARK: Persistence

    func loadLibrary() {
        guard FileManager.default.fileExists(atPath: libraryJSONURL.path) else { return }
        do {
            let data = try Data(contentsOf: libraryJSONURL)
            let decoded = try JSONDecoder().decode(LibraryData.self, from: data)
            books = decoded.books
        } catch {
            print("[LibraryManager] library.json 読み込み失敗: \(error)")
        }
    }

    func saveLibrary() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(LibraryData(books: books))
            try data.write(to: libraryJSONURL, options: .atomic)
        } catch {
            print("[LibraryManager] library.json 保存失敗: \(error)")
        }
    }

    // MARK: URL Helpers

    func bookDirectory(for entry: BookEntry) -> URL {
        libraryRoot.appendingPathComponent(entry.directory)
    }

    func bookJSONURL(for entry: BookEntry) -> URL {
        bookDirectory(for: entry).appendingPathComponent("book.json")
    }

    func coverImageURL(for entry: BookEntry) -> URL? {
        guard let cover = entry.cover else { return nil }
        return libraryRoot.appendingPathComponent(cover)
    }

    // MARK: Reading Position

    func updateReadingPosition(bookId: String, page: Int, position: Double) {
        guard let idx = books.firstIndex(where: { $0.id == bookId }) else { return }
        books[idx].lastReadPage = page
        books[idx].lastReadPosition = position
        saveLibrary()
    }

    // MARK: Delete

    func deleteBook(_ entry: BookEntry) {
        let dir = bookDirectory(for: entry)
        try? FileManager.default.removeItem(at: dir)
        books.removeAll { $0.id == entry.id }
        saveLibrary()
    }

    // MARK: Update Status (helper)

    private func updateBookStatus(id: String, status: BookStatus) {
        guard let idx = books.firstIndex(where: { $0.id == id }) else { return }
        books[idx].status = status
        saveLibrary()
    }

    // MARK: Add Book

    /// 本を追加する。ディレクトリ作成→画像コピー→OCR→TTS→カバー生成の順に実行。
    /// `onProgress` / `onComplete` は任意スレッドから呼ばれるため、
    /// 呼び出し元で `Task { @MainActor in ... }` でラップすること。
    func addBook(
        title: String,
        sourceImagesDirectory: URL,
        pythonExecutable: String,
        scriptsDirectory: String,
        onProgress: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable (Bool, String) -> Void
    ) {
        let bookId = UUID().uuidString
        let safeTitle = title
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let bookDir = libraryRoot.appendingPathComponent(safeTitle)
        let pagesDir = bookDir.appendingPathComponent("pages")
        let bookJSONPath = bookDir.appendingPathComponent("book.json")

        // ライブラリに「インポート中」エントリを追加
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let entry = BookEntry(
            id: bookId,
            title: title,
            directory: safeTitle,
            cover: nil,
            pageCount: 0,
            lastReadPage: 0,
            lastReadPosition: 0.0,
            status: .importing,
            createdAt: formatter.string(from: Date())
        )
        books.append(entry)
        saveLibrary()

        // 以降の処理はバックグラウンドタスクで実行
        Task.detached { [weak self,
                         bookId, safeTitle, bookDir, pagesDir, bookJSONPath,
                         pythonExecutable, scriptsDirectory,
                         sourceImagesDirectory] in

            // 1. ディレクトリ作成
            do {
                try FileManager.default.createDirectory(at: pagesDir, withIntermediateDirectories: true)
            } catch {
                await MainActor.run { self?.updateBookStatus(id: bookId, status: .error); self?.saveLibrary() }
                onComplete(false, "ディレクトリ作成失敗: \(error.localizedDescription)")
                return
            }

            // 2. 画像コピー
            onProgress("画像をコピー中...")
            do {
                let exts = Set(["jpg", "jpeg", "png", "tiff", "tif"])
                let all = try FileManager.default.contentsOfDirectory(
                    at: sourceImagesDirectory, includingPropertiesForKeys: nil)
                let images = all
                    .filter { exts.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                for src in images {
                    let dst = pagesDir.appendingPathComponent(src.lastPathComponent)
                    if !FileManager.default.fileExists(atPath: dst.path) {
                        try FileManager.default.copyItem(at: src, to: dst)
                    }
                }
            } catch {
                await MainActor.run { self?.updateBookStatus(id: bookId, status: .error); self?.saveLibrary() }
                onComplete(false, "画像コピー失敗: \(error.localizedDescription)")
                return
            }

            // 3. OCR
            await MainActor.run { self?.updateBookStatus(id: bookId, status: .ocrProcessing) }
            onProgress("OCR 処理中...")
            let ocrScript = "\(scriptsDirectory)/ocr_process.py"
            let ocrOK = await runProcessAsync(
                executablePath: pythonExecutable,
                arguments: [ocrScript,
                            "--input", pagesDir.path,
                            "--output", bookJSONPath.path,
                            "--title", title],
                onOutput: onProgress
            )
            guard ocrOK else {
                await MainActor.run { self?.updateBookStatus(id: bookId, status: .error); self?.saveLibrary() }
                onComplete(false, "OCR 処理に失敗しました")
                return
            }

            // 4. TTS
            await MainActor.run { self?.updateBookStatus(id: bookId, status: .ttsProcessing) }
            onProgress("TTS 音声生成中...")
            let ttsScript = "\(scriptsDirectory)/tts_process.py"
            let ttsOK = await runProcessAsync(
                executablePath: pythonExecutable,
                arguments: [ttsScript, "--book", bookJSONPath.path],
                onOutput: onProgress
            )
            guard ttsOK else {
                await MainActor.run { self?.updateBookStatus(id: bookId, status: .error); self?.saveLibrary() }
                onComplete(false, "TTS 処理に失敗しました")
                return
            }

            // 5. カバー生成 + ページ数更新
            await MainActor.run {
                guard let self else { return }
                self.generateCover(bookId: bookId, safeTitle: safeTitle,
                                   bookDir: bookDir, pagesDir: pagesDir)
                if let data = try? Data(contentsOf: bookJSONPath),
                   let book = try? JSONDecoder().decode(Book.self, from: data),
                   let idx = self.books.firstIndex(where: { $0.id == bookId }) {
                    self.books[idx].pageCount = book.pages.count
                    self.books[idx].status = .ready
                    self.saveLibrary()
                }
            }

            onComplete(true, "")
        }
    }

    // MARK: Cover Generation

    private func generateCover(bookId: String, safeTitle: String, bookDir: URL, pagesDir: URL) {
        let exts = Set(["jpg", "jpeg", "png"])
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: pagesDir, includingPropertiesForKeys: nil) else { return }
        let firstImage = contents
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
        guard let src = firstImage, let nsImage = NSImage(contentsOf: src) else { return }

        let targetSize = CGSize(width: 200, height: 280)
        let resized = NSImage(size: targetSize)
        resized.lockFocus()
        nsImage.draw(in: NSRect(origin: .zero, size: targetSize),
                     from: NSRect(origin: .zero, size: nsImage.size),
                     operation: .copy, fraction: 1.0)
        resized.unlockFocus()

        guard let cgImage = resized.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpegData = bitmapRep.representation(using: .jpeg,
                                                       properties: [.compressionFactor: 0.85]) else { return }
        let coverURL = bookDir.appendingPathComponent("cover.jpg")
        try? jpegData.write(to: coverURL)

        if let idx = books.firstIndex(where: { $0.id == bookId }) {
            books[idx].cover = "\(safeTitle)/cover.jpg"
        }
    }
}
