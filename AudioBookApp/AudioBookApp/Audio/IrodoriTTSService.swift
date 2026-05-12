#if os(macOS)
import Foundation

/// Irodori TTS (mlx-audio) サーバーとの通信・ライフサイクル管理
@MainActor
final class IrodoriTTSService {
    static let shared = IrodoriTTSService()

    private var serverProcess: Process?
    private var cache: [String: URL] = [:]  // text hash -> temp WAV file URL
    private var pendingTasks: [String: Task<URL, Error>] = [:]
    private let session = URLSession.shared

    /// サーバーが応答可能か
    private(set) var isServerAvailable: Bool = false

    private var serverURL: String {
        ReadingSettings.shared.irodoriServerURL
    }

    private init() {}

    // MARK: - Server Lifecycle

    /// mlx-audio サーバーをサブプロセスとして起動（既に外部で動いていればそれを使う）
    func startServer() async throws {
        // まず既存サーバー（外部起動含む）が動いているか確認
        if await checkHealth() {
            print("[IrodoriTTS] Server already running")
            return
        }

        guard serverProcess == nil else {
            // 自身で起動したプロセスがあるが応答がない → 再起動
            stopServer()
            try await Task.sleep(for: .seconds(1))
            return try await startServer()
        }

        let venvPath = ReadingSettings.shared.irodoriVenvPath
        guard !venvPath.isEmpty else {
            throw IrodoriError.venvPathNotConfigured
        }

        let pythonPath = (venvPath as NSString).appendingPathComponent("bin/python")
        guard FileManager.default.fileExists(atPath: pythonPath) else {
            throw IrodoriError.pythonNotFound(path: pythonPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-m", "mlx_audio.server", "--port", extractPort()]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // 作業ディレクトリをユーザーのホームディレクトリに設定
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        // 環境変数: venv を完全にシミュレート
        var env = ProcessInfo.processInfo.environment
        let venvBinPath = (venvPath as NSString).appendingPathComponent("bin")
        env["VIRTUAL_ENV"] = venvPath
        env["PATH"] = venvBinPath + ":" + (env["PATH"] ?? "/usr/local/bin:/usr/bin:/bin")
        // PYTHONHOME を削除（venv 使用時は不要・競合の原因）
        env.removeValue(forKey: "PYTHONHOME")
        process.environment = env

        do {
            try process.run()
            serverProcess = process
            print("[IrodoriTTS] Server started (PID: \(process.processIdentifier))")
        } catch {
            throw IrodoriError.serverLaunchFailed(underlying: error)
        }

        // サーバーの起動を待つ (最大30秒)
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(500))
            if await checkHealth() {
                print("[IrodoriTTS] Server is ready")
                return
            }
        }
        throw IrodoriError.serverStartTimeout
    }

    /// サーバーを停止
    func stopServer() {
        cancelAll()
        if let process = serverProcess, process.isRunning {
            process.terminate()
            print("[IrodoriTTS] Server stopped")
        }
        serverProcess = nil
        isServerAvailable = false
    }

    /// モデルをウォームアップ（初回ロードをトリガー）
    func warmup() async {
        print("[IrodoriTTS] Warming up model...")
        do {
            // 短いテキストでモデルロードを事前に行う
            _ = try await requestGeneration(text: "テスト")
            print("[IrodoriTTS] Warmup complete")
        } catch {
            print("[IrodoriTTS] Warmup failed (non-fatal): \(error.localizedDescription)")
        }
    }

    /// サーバーのヘルスチェック
    func checkHealth() async -> Bool {
        guard let url = URL(string: "\(serverURL)/v1/models") else {
            isServerAvailable = false
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            let (_, response) = try await session.data(for: request)
            let available = (response as? HTTPURLResponse)?.statusCode == 200
            isServerAvailable = available
            return available
        } catch {
            isServerAvailable = false
            return false
        }
    }

    // MARK: - Audio Generation

    /// テキストから音声を生成し、WAV ファイルの URL を返す
    func generateAudio(text: String) async throws -> URL {
        let key = cacheKey(for: text)

        // キャッシュ確認
        if let cached = cache[key], FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }

        // 既に生成中のタスクがあればそれを待つ
        if let pending = pendingTasks[key] {
            return try await pending.value
        }

        let task = Task<URL, Error> {
            let wavURL = try await requestGeneration(text: text)
            await MainActor.run {
                self.cache[key] = wavURL
                self.pendingTasks.removeValue(forKey: key)
            }
            return wavURL
        }
        pendingTasks[key] = task
        return try await task.value
    }

    /// 複数チャンクを先読み生成 (逐次実行 - サーバーは同時処理できないため)
    func pregenerate(chunks: [IrodoriChunk]) async {
        for chunk in chunks {
            let key = cacheKey(for: chunk.text)
            if cache[key] != nil { continue }
            if pendingTasks[key] != nil { continue }

            do {
                let wavURL = try await requestGeneration(text: chunk.text)
                cache[key] = wavURL
                print("[IrodoriTTS] Pregenerated chunk: \(chunk.text.prefix(20))...")
            } catch {
                print("[IrodoriTTS] Pregenerate failed: \(error.localizedDescription)")
                break  // サーバーに問題があれば残りはスキップ
            }
        }
    }

    /// 全ての保留中タスクをキャンセル
    func cancelAll() {
        for (_, task) in pendingTasks {
            task.cancel()
        }
        pendingTasks.removeAll()
    }

    /// キャッシュをクリア (temp ファイルも削除)
    func clearCache() {
        for (_, url) in cache {
            try? FileManager.default.removeItem(at: url)
        }
        cache.removeAll()
    }

    // MARK: - Private

    private func requestGeneration(text: String) async throws -> URL {
        guard let url = URL(string: "\(serverURL)/v1/audio/speech") else {
            throw IrodoriError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180  // 初回はモデルロードで時間がかかる

        let refWavPath = ReadingSettings.shared.irodoriRefWavPath
        let voice = refWavPath.isEmpty ? "no-ref" : refWavPath
        let body: [String: Any] = [
            "model": "mlx-community/Irodori-TTS-500M-v2-fp16",
            "input": text,
            "voice": voice,
            "response_format": "wav",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw IrodoriError.generationFailed(statusCode: statusCode, message: responseBody)
        }

        // WAV データを temp ファイルに保存
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("irodori_cache", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let fileName = "\(cacheKey(for: text)).wav"
        let fileURL = tempDir.appendingPathComponent(fileName)
        try data.write(to: fileURL)

        return fileURL
    }

    private func cacheKey(for text: String) -> String {
        // シンプルなハッシュキー
        let hash = text.utf8.reduce(into: UInt64(5381)) { result, byte in
            result = result &* 33 &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }

    private func extractPort() -> String {
        // serverURL からポート番号を抽出
        guard let url = URL(string: serverURL),
              let port = url.port else {
            return "8000"
        }
        return String(port)
    }
}

// MARK: - Error Types

enum IrodoriError: LocalizedError {
    case venvPathNotConfigured
    case pythonNotFound(path: String)
    case serverLaunchFailed(underlying: Error)
    case serverStartTimeout
    case invalidURL
    case generationFailed(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .venvPathNotConfigured:
            return "Irodori TTS: Python venv パスが設定されていません"
        case .pythonNotFound(let path):
            return "Irodori TTS: Python が見つかりません: \(path)"
        case .serverLaunchFailed(let err):
            return "Irodori TTS: サーバー起動失敗: \(err.localizedDescription)"
        case .serverStartTimeout:
            return "Irodori TTS: サーバー起動タイムアウト (30秒)"
        case .invalidURL:
            return "Irodori TTS: 無効なサーバー URL"
        case .generationFailed(let code, let msg):
            return "Irodori TTS: 生成失敗 (HTTP \(code)): \(msg)"
        }
    }
}
#endif
