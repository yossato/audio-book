import Foundation
#if os(macOS)
import AppKit
#endif

// MARK: - Process Utility (macOS only)

#if os(macOS)
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
#endif

#if os(macOS)
// MARK: - TTS Progress

enum TTSPhase: String, Sendable {
    case starting
    case tts
    case alignment = "fa"
    case compress
    case complete
}

struct TTSProgress: Sendable {
    let phase: TTSPhase
    let page: Int
    let total: Int
    let message: String

    /// スクリプトの PROGRESS: 行をパースする
    static func parse(_ line: String) -> TTSProgress? {
        guard line.hasPrefix("PROGRESS:") else { return nil }
        let body = line.dropFirst("PROGRESS:".count)
        var dict: [String: String] = [:]
        for component in body.split(separator: ",") {
            let kv = component.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { dict[String(kv[0])] = String(kv[1]) }
        }
        guard let phaseStr = dict["phase"],
              let phase = TTSPhase(rawValue: phaseStr) else { return nil }
        return TTSProgress(
            phase: phase,
            page: Int(dict["page"] ?? "0") ?? 0,
            total: Int(dict["total"] ?? "0") ?? 0,
            message: dict["status"] ?? ""
        )
    }

    /// UI 表示用のテキスト
    var displayText: String {
        switch phase {
        case .starting: return message
        case .tts: return "音声生成中 \(page)/\(total)"
        case .alignment: return "アライメント \(page)/\(total)"
        case .compress: return "圧縮中 \(page)/\(total)"
        case .complete: return "完了"
        }
    }
}
#endif

// MARK: - LibraryManager

@MainActor
@Observable
final class LibraryManager {

    // MARK: State

    var books: [BookEntry] = []
    private(set) var libraryRoot: URL

    /// iCloud Drive フォルダが設定済みかどうか
    var hasExternalLibrary: Bool {
        #if os(macOS)
        let stored = UserDefaults.standard.string(forKey: "libraryRootPath") ?? ""
        return !stored.isEmpty
        #else
        return UserDefaults.standard.data(forKey: Self.bookmarkKey) != nil
        #endif
    }

    private var libraryJSONURL: URL {
        libraryRoot.appendingPathComponent("library.json")
    }

    #if os(iOS)
    private static let bookmarkKey = "LibraryManager.folderBookmark"
    /// security-scoped リソースがアクティブかどうか
    private var isAccessingSecurityScope = false
    #endif

    // MARK: Init

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fallback = docs.appendingPathComponent("AudioBookLibrary")

        #if os(macOS)
        let storedPath = UserDefaults.standard.string(forKey: "libraryRootPath")
        if let p = storedPath, !p.isEmpty {
            libraryRoot = URL(fileURLWithPath: p)
        } else {
            libraryRoot = fallback
        }
        #else
        // iOS: bookmark から復元、なければ Documents/AudioBookLibrary
        if let bookmarkData = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &stale) {
                if stale {
                    // bookmark が古い場合は再保存を試みる
                    if let fresh = try? url.bookmarkData(options: .minimalBookmark) {
                        UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
                    }
                }
                libraryRoot = url
            } else {
                libraryRoot = fallback
            }
        } else {
            libraryRoot = fallback
        }
        #endif
        try? FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        startAccessIfNeeded()
        loadLibrary()
        recoverStuckBooks()
    }

    /// アプリ終了等で処理中のまま残ったブックを ready に復帰させる
    private func recoverStuckBooks() {
        var changed = false
        for i in books.indices {
            if books[i].status == .ttsProcessing || books[i].status == .ocrProcessing || books[i].status == .importing {
                books[i].status = .ready
                changed = true
            }
        }
        if changed {
            saveLibrary()
        }
    }

    // MARK: - External Library Folder

    // MARK: - Reference Voices

    /// リファレンス音声の保存ディレクトリ
    var refVoicesDirectory: URL {
        libraryRoot.appendingPathComponent("ref_voices")
    }

    /// 保存済みリファレンス音声のファイル名一覧を返す
    func listRefVoices() -> [String] {
        let dir = refVoicesDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        return files.filter { $0.hasSuffix(".wav") }.sorted()
    }

    /// リファレンス音声ファイルをライブラリにコピーし、保存先パスを返す
    @discardableResult
    func addRefVoice(from sourceURL: URL) -> String? {
        let dir = refVoicesDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destURL = dir.appendingPathComponent(sourceURL.lastPathComponent)
        // 同名ファイルがあれば上書き
        try? FileManager.default.removeItem(at: destURL)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            print("[LibraryManager] Copied ref voice: \(sourceURL.lastPathComponent)")
            return destURL.path
        } catch {
            print("[LibraryManager] Failed to copy ref voice: \(error)")
            return nil
        }
    }

    /// リファレンス音声のファイル名からフルパスを返す
    func refVoicePath(for filename: String) -> String {
        refVoicesDirectory.appendingPathComponent(filename).path
    }

    #if os(macOS)
    /// ライブラリルートを変更する (macOS)
    func setLibraryRoot(path: String) {
        UserDefaults.standard.set(path, forKey: "libraryRootPath")
        libraryRoot = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        loadLibrary()
    }

    /// iCloud Drive のデフォルトパスを返す
    static var iCloudDrivePath: String {
        let home = NSHomeDirectory()
        return "\(home)/Library/Mobile Documents/com~apple~CloudDocs/AudioBookLibrary"
    }
    #endif

    #if os(iOS)
    /// ユーザーが選択したフォルダの URL を security-scoped bookmark として保存する
    func setExternalFolder(url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            print("[LibraryManager] Failed to access security-scoped resource")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let bookmarkData = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmarkData, forKey: Self.bookmarkKey)
            libraryRoot = url
            startAccessIfNeeded()
            loadLibrary()
        } catch {
            print("[LibraryManager] Bookmark save failed: \(error)")
        }
    }
    #endif

    /// security-scoped リソースへのアクセスを開始
    private func startAccessIfNeeded() {
        #if os(iOS)
        guard UserDefaults.standard.data(forKey: Self.bookmarkKey) != nil else { return }
        if !isAccessingSecurityScope {
            isAccessingSecurityScope = libraryRoot.startAccessingSecurityScopedResource()
        }
        #endif
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

    #if os(macOS)

    // MARK: - Batch TTS

    /// 現在実行中の TTS プロセス（キャンセル用）
    private var ttsTask: Task<Void, Never>?

    /// TTS 生成中の本の ID
    private(set) var ttsGeneratingBookId: String?

    /// TTS 進捗情報
    private(set) var ttsProgress: TTSProgress?

    /// Irodori TTS によるバッチ音声生成を開始する
    func generateBatchTTS(entry: BookEntry) {
        guard ttsTask == nil else {
            print("[LibraryManager] TTS生成は既に実行中です")
            return
        }

        let bookId = entry.id
        let bookJSONPath = bookJSONURL(for: entry).path

        ttsGeneratingBookId = bookId
        ttsProgress = TTSProgress(phase: .starting, page: 0, total: 0, message: "準備中...")
        updateBookStatus(id: bookId, status: .ttsProcessing)

        ttsTask = Task.detached { [weak self] in
            let settings = await ReadingSettings.shared
            let venvPath = await settings.irodoriVenvPath
            let serverURL = await settings.irodoriServerURL
            let refWavPath = await settings.irodoriRefWavPath

            let pythonPath = (venvPath as NSString).appendingPathComponent("bin/python")
            let scriptsDir = UserDefaults.standard.string(forKey: "scriptsDirectory")
                ?? AddBookView.defaultScriptsPath

            print("[BatchTTS] venvPath=\(venvPath)")
            print("[BatchTTS] pythonPath=\(pythonPath)")
            print("[BatchTTS] scriptsDir=\(scriptsDir)")
            print("[BatchTTS] serverURL=\(serverURL)")
            print("[BatchTTS] bookJSONPath=\(bookJSONPath)")

            // Phase 1: サーバー起動
            await MainActor.run {
                self?.ttsProgress = TTSProgress(phase: .starting, page: 0, total: 0, message: "サーバー起動中...")
            }
            do {
                try await IrodoriTTSService.shared.startServer()
                print("[BatchTTS] サーバー起動成功")
            } catch {
                print("[BatchTTS] サーバー起動失敗: \(error.localizedDescription)")
                await MainActor.run {
                    self?.ttsProgress = nil
                    self?.ttsGeneratingBookId = nil
                    self?.ttsTask = nil
                    self?.updateBookStatus(id: bookId, status: .error)
                }
                return
            }

            // Phase 2: TTS 生成
            await MainActor.run {
                self?.ttsProgress = TTSProgress(phase: .tts, page: 0, total: 0, message: "音声生成中...")
            }

            var ttsArgs = [
                "\(scriptsDir)/irodori_tts_batch.py",
                "--book", bookJSONPath,
                "--server-url", serverURL,
                "--phase", "tts",
            ]
            if !refWavPath.isEmpty {
                ttsArgs += ["--ref-wav", refWavPath]
            }
            print("[BatchTTS] TTS実行: \(pythonPath) \(ttsArgs.joined(separator: " "))")

            let ttsOK = await runProcessAsync(
                executablePath: pythonPath,
                arguments: ttsArgs,
                onOutput: { line in
                    print("[BatchTTS:stdout] \(line)")
                    if let progress = TTSProgress.parse(line) {
                        Task { @MainActor in
                            self?.ttsProgress = progress
                        }
                    }
                }
            )

            guard ttsOK else {
                print("[BatchTTS] TTS生成失敗")
                await MainActor.run {
                    self?.ttsProgress = nil
                    self?.ttsGeneratingBookId = nil
                    self?.ttsTask = nil
                    self?.updateBookStatus(id: bookId, status: .error)
                }
                await IrodoriTTSService.shared.stopServer()
                return
            }
            print("[BatchTTS] TTS生成完了")

            // Phase 3: サーバー停止 → メモリ解放
            await IrodoriTTSService.shared.stopServer()
            await MainActor.run {
                self?.ttsProgress = TTSProgress(phase: .alignment, page: 0, total: 0, message: "メモリ解放待機中...")
            }
            print("[BatchTTS] サーバー停止、メモリ解放待機...")
            try? await Task.sleep(for: .seconds(3))

            // Phase 4: Forced Alignment + 圧縮
            await MainActor.run {
                self?.ttsProgress = TTSProgress(phase: .alignment, page: 0, total: 0, message: "アライメント中...")
            }

            var faArgs = [
                "\(scriptsDir)/irodori_tts_batch.py",
                "--book", bookJSONPath,
                "--server-url", serverURL,
                "--phase", "fa-compress",
            ]
            if !refWavPath.isEmpty {
                faArgs += ["--ref-wav", refWavPath]
            }
            print("[BatchTTS] FA実行: \(pythonPath) \(faArgs.joined(separator: " "))")

            let faOK = await runProcessAsync(
                executablePath: pythonPath,
                arguments: faArgs,
                onOutput: { line in
                    print("[BatchTTS:stdout] \(line)")
                    if let progress = TTSProgress.parse(line) {
                        Task { @MainActor in
                            self?.ttsProgress = progress
                        }
                    }
                }
            )

            print("[BatchTTS] FA完了: \(faOK)")
            await MainActor.run {
                self?.ttsProgress = nil
                self?.ttsGeneratingBookId = nil
                self?.ttsTask = nil
                if faOK {
                    self?.updateBookStatus(id: bookId, status: .ready)
                } else {
                    // FA/圧縮失敗でも音声は生成済みなので ready にする
                    self?.updateBookStatus(id: bookId, status: .ready)
                }
            }
        }
    }

    /// TTS 生成をキャンセルする
    func cancelBatchTTS() {
        ttsTask?.cancel()
        ttsTask = nil
        IrodoriTTSService.shared.stopServer()
        if let bookId = ttsGeneratingBookId {
            updateBookStatus(id: bookId, status: .ready)
        }
        ttsGeneratingBookId = nil
        ttsProgress = nil
    }

    // MARK: Add Markdown Book

    /// Markdown ファイルを本として追加する
    func addMarkdownBook(
        title: String,
        sourceFile: URL,
        onComplete: @escaping @Sendable (Bool, String) -> Void
    ) {
        let bookId = UUID().uuidString
        let safeTitle = title
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let bookDir = libraryRoot.appendingPathComponent(safeTitle)
        let bookJSONPath = bookDir.appendingPathComponent("book.json")

        // ライブラリにエントリを追加
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        do {
            // 1. ディレクトリ作成
            try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)

            // 2. .md ファイルをコピー
            let destMD = bookDir.appendingPathComponent(sourceFile.lastPathComponent)
            if !FileManager.default.fileExists(atPath: destMD.path) {
                try FileManager.default.copyItem(at: sourceFile, to: destMD)
            }

            // 3. Markdown パース → Book
            let book = try MarkdownParser.parse(fileURL: sourceFile, title: title)

            // 4. book.json 書き出し
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(book)
            try data.write(to: bookJSONPath, options: .atomic)

            // 5. テキストカバー画像生成
            generateTextCover(bookId: bookId, safeTitle: safeTitle, bookDir: bookDir, title: title)

            // 6. ライブラリに追加
            let entry = BookEntry(
                id: bookId,
                title: title,
                directory: safeTitle,
                cover: "\(safeTitle)/cover.jpg",
                pageCount: book.pages.count,
                lastReadPage: 0,
                lastReadPosition: 0.0,
                status: .ready,
                createdAt: formatter.string(from: Date())
            )
            books.append(entry)
            saveLibrary()

            onComplete(true, "")
        } catch {
            onComplete(false, "Markdown 処理失敗: \(error.localizedDescription)")
        }
    }

    /// テキストベースのカバー画像を生成する（Markdown 本用）
    private func generateTextCover(bookId: String, safeTitle: String, bookDir: URL, title: String) {
        let targetSize = CGSize(width: 200, height: 280)
        let image = NSImage(size: targetSize)
        image.lockFocus()

        // 背景
        NSColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1.0).setFill()
        NSBezierPath.fill(NSRect(origin: .zero, size: targetSize))

        // アイコン
        let iconAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 48),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
        ]
        let iconStr = NSAttributedString(string: "📄", attributes: iconAttrs)
        let iconSize = iconStr.size()
        iconStr.draw(at: NSPoint(
            x: (targetSize.width - iconSize.width) / 2,
            y: targetSize.height - iconSize.height - 40
        ))

        // タイトル
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 16),
            .foregroundColor: NSColor.white,
        ]
        let titleStr = NSAttributedString(string: title, attributes: titleAttrs)
        let titleRect = NSRect(x: 12, y: 30, width: targetSize.width - 24, height: 120)
        titleStr.draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        image.unlockFocus()

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpegData = bitmapRep.representation(using: .jpeg,
                                                       properties: [.compressionFactor: 0.85]) else { return }
        let coverURL = bookDir.appendingPathComponent("cover.jpg")
        try? jpegData.write(to: coverURL)
    }

    // MARK: Delete Audio

    /// 生成済み音声ファイルを削除し、book.json から audio_path を除去する
    func deleteGeneratedAudio(entry: BookEntry) {
        let dir = bookDirectory(for: entry)

        // audio/ ディレクトリを削除
        let audioDir = dir.appendingPathComponent("audio")
        if FileManager.default.fileExists(atPath: audioDir.path) {
            try? FileManager.default.removeItem(at: audioDir)
        }

        // book.json から audio_path を除去
        let bookJsonURL = dir.appendingPathComponent("book.json")
        guard FileManager.default.fileExists(atPath: bookJsonURL.path),
              var jsonDict = try? JSONSerialization.jsonObject(
                  with: Data(contentsOf: bookJsonURL)) as? [String: Any],
              var pages = jsonDict["pages"] as? [[String: Any]] else {
            return
        }
        for i in pages.indices {
            pages[i].removeValue(forKey: "audio_path")
        }
        jsonDict["pages"] = pages
        if let data = try? JSONSerialization.data(withJSONObject: jsonDict, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: bookJsonURL)
        }
        print("[LibraryManager] Deleted generated audio for: \(entry.title)")
    }

    /// 指定ブックに生成済み音声があるかチェック
    func hasGeneratedAudio(entry: BookEntry) -> Bool {
        let audioDir = bookDirectory(for: entry).appendingPathComponent("audio")
        return FileManager.default.fileExists(atPath: audioDir.path)
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

            // 4. カバー生成 + ページ数更新（TTS はスキップ）
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

    #endif
}
