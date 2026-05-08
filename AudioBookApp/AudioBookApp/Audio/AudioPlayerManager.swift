import AVFoundation
import MediaPlayer

@MainActor
@Observable
final class AudioPlayerManager: NSObject {
    // MARK: - Observable State

    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    var playbackRate: Float = 1.0
    var activeBlockId: Int = -1

    /// 再生完了時に呼ばれるコールバック
    var onPlaybackFinished: (@MainActor () -> Void)?

    // MARK: - WAV mode

    private var player: AVAudioPlayer?
    private var wavBlocks: [TextBlock] = []

    // MARK: - Speech synthesis mode

    private var synthesizer: AVSpeechSynthesizer?
    private var isSpeechMode = false
    private var speechBlocks: [TextBlock] = []
    private var speechUtterances: [AVSpeechUtterance] = []
    private var utteranceBlockIds: [Int] = []
    private var currentUtteranceIndex = 0
    private var speechGroups: [SpeechGroup] = []
    private var groupStartOffset: Int = 0

    // MARK: - Irodori TTS mode (macOS only)

    #if os(macOS)
    private var isIrodoriMode = false
    private var irodoriChunks: [IrodoriChunk] = []
    private var irodoriBlocks: [TextBlock] = []
    private var currentIrodoriChunkIndex = 0
    private var irodoriChunkPlayer: AVAudioPlayer?
    /// チャンク先頭からの累積時間オフセット (duration slider 用)
    private var irodoriCumulativeTime: Double = 0
    /// 現在のチャンクの再生開始累積時間
    private var irodoriChunkStartTime: Double = 0
    /// 先読み用にチャンクを公開
    var irodoriChunksForPregeneration: [IrodoriChunk] { irodoriChunks }
    private var irodoriPlayTask: Task<Void, Never>?
    #endif
    /// Irodori 音声生成中フラグ
    var isIrodoriGenerating = false

    /// Irodori モードかどうか (iOS では常に false)
    private var isCurrentlyIrodoriMode: Bool {
        #if os(macOS)
        return isIrodoriMode
        #else
        return false
        #endif
    }

    private struct BlockRange {
        let startCharIndex: Int  // UTF-16 offset within group.text
        let blockId: Int
    }

    private struct SpeechGroup {
        let text: String
        let blockRanges: [BlockRange]  // sorted ascending by startCharIndex
    }

    // MARK: - Shared timer

    private var timer: Timer?

    override init() {
        super.init()
        setupRemoteCommands()
    }

    // MARK: - Load

    /// url が nil またはファイルが存在しない場合は AVSpeechSynthesizer モードで動作する
    /// TTS エンジンが irodori の場合は Irodori TTS モードで動作する
    func loadAudio(url: URL?, blocks: [TextBlock]) {
        stop()

        if let url, FileManager.default.fileExists(atPath: url.path) {
            // ----- WAV モード -----
            isSpeechMode = false
            #if os(macOS)
            isIrodoriMode = false
            #endif
            wavBlocks = blocks
            do {
                player = try AVAudioPlayer(contentsOf: url)
                player?.delegate = self
                player?.enableRate = true
                player?.prepareToPlay()
                duration = player?.duration ?? 0
                currentTime = 0
                activeBlockId = -1
            } catch {
                print("[AudioPlayerManager] WAV ロード失敗: \(error)")
            }
        } else if loadIrodoriIfNeeded(blocks: blocks) {
            // Irodori モードでロード済み
        } else {
            // ----- 音声合成モード (say) -----
            isSpeechMode = true
            #if os(macOS)
            isIrodoriMode = false
            #endif
            speechBlocks = blocks.filter { $0.isReadable }
            speechGroups = buildSpeechGroups(from: speechBlocks)
            speechUtterances = []
            utteranceBlockIds = []
            currentUtteranceIndex = 0
            currentTime = 0
            activeBlockId = -1
            duration = estimateSpeechDuration(blocks: speechBlocks, rate: playbackRate)
            synthesizer = AVSpeechSynthesizer()
            synthesizer?.delegate = self
        }
    }

    /// Irodori TTS モードでのロード (macOS でエンジンが irodori の場合のみ)
    private func loadIrodoriIfNeeded(blocks: [TextBlock]) -> Bool {
        #if os(macOS)
        guard ReadingSettings.shared.ttsEngine == .irodori else { return false }
        isSpeechMode = false
        isIrodoriMode = true
        irodoriBlocks = blocks.filter { $0.isReadable }
        irodoriChunks = IrodoriChunkBuilder.buildChunks(from: irodoriBlocks)
        currentIrodoriChunkIndex = 0
        irodoriCumulativeTime = 0
        irodoriChunkStartTime = 0
        currentTime = 0
        activeBlockId = -1
        duration = estimateSpeechDuration(blocks: irodoriBlocks, rate: playbackRate)
        print("[Irodori] Loaded \(irodoriChunks.count) chunks from \(irodoriBlocks.count) blocks")
        return true
        #else
        return false
        #endif
    }

    // MARK: - Play / Pause / Stop

    func play() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[AudioPlayerManager] AVAudioSession setup failed: \(error)")
        }
        #endif

        if isCurrentlyIrodoriMode {
            #if os(macOS)
            if let chunkPlayer = irodoriChunkPlayer, !chunkPlayer.isPlaying {
                // 一時停止からの復帰
                chunkPlayer.rate = playbackRate
                chunkPlayer.play()
                isPlaying = true
                startTimer(interval: 0.05) { [weak self] in self?.irodoriTick() }
                updateNowPlaying()
            } else {
                playIrodoriFromChunk(index: currentIrodoriChunkIndex)
            }
            #endif
        } else if isSpeechMode {
            if synthesizer?.isPaused == true {
                synthesizer?.continueSpeaking()
                isPlaying = true
                startTimer(interval: 0.1) { [weak self] in self?.speechTick() }
                updateNowPlaying()
            } else {
                speakFrom(index: currentUtteranceIndex)
            }
        } else {
            guard let player else { return }
            player.rate = playbackRate
            player.play()
            isPlaying = true
            startTimer(interval: 0.05) { [weak self] in self?.wavTick() }
            updateNowPlaying()
        }
    }

    func pause() {
        if isCurrentlyIrodoriMode {
            #if os(macOS)
            irodoriChunkPlayer?.pause()
            #endif
        } else if isSpeechMode {
            synthesizer?.pauseSpeaking(at: .word)
        } else {
            player?.pause()
        }
        isPlaying = false
        stopTimer()
        updateNowPlaying()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func stop() {
        if isCurrentlyIrodoriMode {
            #if os(macOS)
            irodoriPlayTask?.cancel()
            irodoriPlayTask = nil
            irodoriChunkPlayer?.stop()
            irodoriChunkPlayer = nil
            currentIrodoriChunkIndex = 0
            irodoriCumulativeTime = 0
            irodoriChunkStartTime = 0
            activeBlockId = -1
            #endif
        } else if isSpeechMode {
            synthesizer?.stopSpeaking(at: .immediate)
            speechUtterances = []
            utteranceBlockIds = []
            currentUtteranceIndex = 0
            activeBlockId = -1
        } else {
            player?.stop()
        }
        isPlaying = false
        stopTimer()
    }

    // MARK: - Seek

    func seek(to time: Double) {
        if isCurrentlyIrodoriMode {
            #if os(macOS)
            guard !irodoriChunks.isEmpty else { return }
            let charsPerSec = estimatedCharsPerSecond(rate: playbackRate)
            var accumulated = 0.0
            var targetChunk = 0
            for (i, chunk) in irodoriChunks.enumerated() {
                let chunkDuration = Double(chunk.text.count) / max(1, charsPerSec)
                if accumulated + chunkDuration > time {
                    targetChunk = i
                    break
                }
                accumulated += chunkDuration
                targetChunk = i + 1
            }
            let safeIdx = min(targetChunk, irodoriChunks.count - 1)
            let wasPlaying = isPlaying
            irodoriPlayTask?.cancel()
            irodoriChunkPlayer?.stop()
            irodoriChunkPlayer = nil
            currentIrodoriChunkIndex = safeIdx
            irodoriChunkStartTime = accumulated
            irodoriCumulativeTime = accumulated
            currentTime = time
            if wasPlaying { playIrodoriFromChunk(index: safeIdx) }
            #endif
        } else if isSpeechMode {
            // 推定時間からブロックを特定してジャンプ
            guard !speechBlocks.isEmpty else { return }
            var accumulated = 0.0
            let charsPerSec = estimatedCharsPerSecond(rate: playbackRate)
            var targetIdx = 0
            for (i, block) in speechBlocks.enumerated() {
                let blockDuration = Double(preprocessBlockText(block.text).count) / max(1, charsPerSec)
                if accumulated + blockDuration > time {
                    targetIdx = i
                    break
                }
                accumulated += blockDuration
                targetIdx = i + 1
            }
            let safeIdx = min(targetIdx, speechBlocks.count - 1)
            let wasPlaying = isPlaying
            synthesizer?.stopSpeaking(at: .immediate)
            speechUtterances = []
            utteranceBlockIds = []
            speechGroups = buildSpeechGroups(from: Array(speechBlocks[safeIdx...]))
            currentUtteranceIndex = 0
            currentTime = time
            if wasPlaying { speakFrom(index: 0) }
        } else {
            player?.currentTime = time
            currentTime = time
            updateActiveWavBlock()
            updateNowPlaying()
        }
    }

    func seekToBlock(_ block: TextBlock) {
        if isCurrentlyIrodoriMode {
            #if os(macOS)
            guard let chunkIdx = irodoriChunks.firstIndex(where: { chunk in
                chunk.blockRanges.contains { $0.blockId == block.id }
            }) else { return }
            irodoriPlayTask?.cancel()
            irodoriChunkPlayer?.stop()
            irodoriChunkPlayer = nil
            currentIrodoriChunkIndex = chunkIdx
            // 累積時間を再計算
            let charsPerSec = estimatedCharsPerSecond(rate: playbackRate)
            var accumulated = 0.0
            for i in 0..<chunkIdx {
                accumulated += Double(irodoriChunks[i].text.count) / max(1, charsPerSec)
            }
            irodoriChunkStartTime = accumulated
            irodoriCumulativeTime = accumulated
            currentTime = accumulated
            playIrodoriFromChunk(index: chunkIdx)
            #endif
        } else if isSpeechMode {
            guard let blockIdx = speechBlocks.firstIndex(where: { $0.id == block.id }) else { return }
            synthesizer?.stopSpeaking(at: .immediate)
            speechUtterances = []
            utteranceBlockIds = []
            // クリックされたブロックから新たにグループを再構築して読み始める
            speechGroups = buildSpeechGroups(from: Array(speechBlocks[blockIdx...]))
            currentUtteranceIndex = 0
            speakFrom(index: 0)
        } else {
            guard let start = block.audioStart else { return }
            seek(to: start)
            if !isPlaying { play() }
        }
    }

    func setRate(_ rate: Float) {
        playbackRate = rate
        if isCurrentlyIrodoriMode {
            #if os(macOS)
            duration = estimateSpeechDuration(blocks: irodoriBlocks, rate: rate)
            irodoriChunkPlayer?.rate = rate
            #endif
        } else if isSpeechMode {
            duration = estimateSpeechDuration(blocks: speechBlocks, rate: rate)
            // 再生中 or 一時停止中であれば新しい速度で再起動
            if isPlaying || synthesizer?.isPaused == true {
                stopTimer()
                speakFrom(index: currentUtteranceIndex)
            }
        } else {
            if isPlaying { player?.rate = rate }
        }
        updateNowPlaying()
    }

    // MARK: - Irodori TTS Playback (macOS only)

    #if os(macOS)
    private func playIrodoriFromChunk(index: Int) {
        guard isIrodoriMode else { return }
        guard index < irodoriChunks.count else {
            // 全チャンク再生完了
            isPlaying = false
            activeBlockId = -1
            stopTimer()
            onPlaybackFinished?()
            return
        }

        currentIrodoriChunkIndex = index
        isPlaying = true
        isIrodoriGenerating = true

        irodoriPlayTask = Task { [weak self] in
            guard let self else { return }
            do {
                let chunk = self.irodoriChunks[index]
                let wavURL = try await IrodoriTTSService.shared.generateAudio(text: chunk.text)

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.isIrodoriGenerating = false
                    self.startIrodoriChunkPlayback(wavURL: wavURL, chunkIndex: index)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.isIrodoriGenerating = false
                    print("[Irodori] Generation failed for chunk \(index): \(error)")
                    // サーバーエラー時は再生を停止する（カスケード防止）
                    self.isPlaying = false
                    self.activeBlockId = -1
                    self.stopTimer()
                }
            }
        }
    }

    private func startIrodoriChunkPlayback(wavURL: URL, chunkIndex: Int) {
        do {
            let chunkPlayer = try AVAudioPlayer(contentsOf: wavURL)
            chunkPlayer.delegate = self
            chunkPlayer.enableRate = true
            chunkPlayer.rate = playbackRate
            chunkPlayer.prepareToPlay()

            irodoriChunkPlayer = chunkPlayer
            irodoriChunkStartTime = irodoriCumulativeTime

            // ブロックハイライトの初期設定
            let chunk = irodoriChunks[chunkIndex]
            if let firstBlock = chunk.blockRanges.first {
                activeBlockId = firstBlock.blockId
            }

            chunkPlayer.play()
            startTimer(interval: 0.05) { [weak self] in self?.irodoriTick() }
            updateNowPlaying()
        } catch {
            print("[Irodori] Playback failed: \(error)")
            playIrodoriFromChunk(index: chunkIndex + 1)
        }
    }

    private func irodoriTick() {
        guard let chunkPlayer = irodoriChunkPlayer else { return }
        let chunkTime = chunkPlayer.currentTime
        currentTime = irodoriChunkStartTime + chunkTime

        // ブロックハイライト更新 (文字位置比例)
        let chunkIndex = currentIrodoriChunkIndex
        guard chunkIndex < irodoriChunks.count else { return }
        let chunk = irodoriChunks[chunkIndex]
        let chunkDuration = chunkPlayer.duration
        guard chunkDuration > 0 else { return }

        // 現在の再生位置に対応する文字位置を推定
        let progress = chunkTime / chunkDuration
        let estimatedCharPos = Int(progress * Double(chunk.text.count))

        // 該当ブロックを特定
        var newActiveId = chunk.blockRanges.first?.blockId ?? -1
        for range in chunk.blockRanges {
            if range.charOffset <= estimatedCharPos {
                newActiveId = range.blockId
            } else {
                break
            }
        }
        if activeBlockId != newActiveId {
            activeBlockId = newActiveId
        }
    }

    /// Irodori チャンク再生完了時に次のチャンクへ進む (AVAudioPlayerDelegate から呼ばれる)
    private func irodoriChunkDidFinish() {
        guard isIrodoriMode else { return }
        // 累積時間を更新
        if let chunkPlayer = irodoriChunkPlayer {
            irodoriCumulativeTime = irodoriChunkStartTime + chunkPlayer.duration
        }
        irodoriChunkPlayer = nil
        let nextIndex = currentIrodoriChunkIndex + 1
        if nextIndex < irodoriChunks.count {
            playIrodoriFromChunk(index: nextIndex)
        } else {
            // 全チャンク再生完了
            isPlaying = false
            activeBlockId = -1
            stopTimer()
            onPlaybackFinished?()
        }
    }
    #endif

    // MARK: - Speech Synthesis

    private func speakFrom(index: Int) {
        guard isSpeechMode else { return }

        // stopSpeaking 直後の speak は不安定なため、毎回新しいインスタンスを使う
        synthesizer?.delegate = nil
        synthesizer?.stopSpeaking(at: .immediate)
        let newSynth = AVSpeechSynthesizer()
        newSynth.delegate = self
        synthesizer = newSynth

        speechUtterances = []
        utteranceBlockIds = []

        let voice = AVSpeechSynthesisVoice(language: "ja-JP")
        let utteranceRate = max(AVSpeechUtteranceMinimumSpeechRate,
                                min(AVSpeechUtteranceMaximumSpeechRate,
                                    AVSpeechUtteranceDefaultSpeechRate * playbackRate))

        guard !speechGroups.isEmpty else {
            isPlaying = false
            onPlaybackFinished?()
            return
        }
        let startIdx = max(0, min(index, speechGroups.count - 1))
        groupStartOffset = startIdx
        for group in speechGroups[startIdx...] {
            guard !group.text.isEmpty else { continue }
            let u = AVSpeechUtterance(string: group.text)
            u.voice = voice
            u.rate = utteranceRate
            u.postUtteranceDelay = 0.05
            speechUtterances.append(u)
            utteranceBlockIds.append(group.blockRanges.first?.blockId ?? -1)
            newSynth.speak(u)
        }

        if speechUtterances.isEmpty {
            isPlaying = false
            onPlaybackFinished?()
        } else {
            currentUtteranceIndex = index
            isPlaying = true
            startTimer(interval: 0.1) { [weak self] in self?.speechTick() }
        }
    }

    // MARK: - Text Preprocessing

    /// ブロックテキストから改行を除去する。句読点（。！？）でグループ分割するため
    /// 改行は必要なく、残すと AVSpeechSynthesizer が不自然に止まる原因になる。
    private func preprocessBlockText(_ text: String) -> String {
        var result = ""
        for char in text where char != "\n" && char != "\r" {
            result.append(char)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// 読み上げブロックを句読点単位のグループに分割する。
    /// 各グループはブロックのUTF-16文字位置情報を持ち、再生中のハイライト追跡に使用する。
    private func buildSpeechGroups(from blocks: [TextBlock]) -> [SpeechGroup] {
        var groups: [SpeechGroup] = []
        var currentText = ""
        var currentUtf16Count = 0
        var currentBlockRanges: [BlockRange] = []
        let sentenceEnders: Set<Character> = ["。", "！", "？"]

        for block in blocks {
            let processed = preprocessBlockText(block.text)
            guard !processed.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            var blockStarted = false
            for char in processed {
                if !blockStarted {
                    // このブロックのテキストが始まるUTF-16位置を記録
                    currentBlockRanges.append(BlockRange(startCharIndex: currentUtf16Count, blockId: block.id))
                    blockStarted = true
                }
                currentText.append(char)
                currentUtf16Count += char.utf16.count
                if sentenceEnders.contains(char) {
                    if !currentText.trimmingCharacters(in: .whitespaces).isEmpty {
                        groups.append(SpeechGroup(text: currentText, blockRanges: currentBlockRanges))
                    }
                    currentText = ""
                    currentUtf16Count = 0
                    currentBlockRanges = []
                    blockStarted = false
                }
            }
        }

        if !currentText.trimmingCharacters(in: .whitespaces).isEmpty {
            groups.append(SpeechGroup(text: currentText, blockRanges: currentBlockRanges))
        }
        return groups
    }

    // MARK: - Duration Estimation

    private func estimatedCharsPerSecond(rate: Float) -> Double {
        // 日本語: デフォルト速度 (rate=1.0) で約 8〜10字/秒
        return 9.0 * Double(rate)
    }

    private func estimateSpeechDuration(blocks: [TextBlock], rate: Float) -> Double {
        let totalChars = blocks.reduce(0) { $0 + preprocessBlockText($1.text).count }
        return Double(totalChars) / max(1, estimatedCharsPerSecond(rate: rate))
    }

    // MARK: - Timer

    private func startTimer(interval: TimeInterval, tick: @escaping @MainActor () -> Void) {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard self != nil else { return }
                tick()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func wavTick() {
        guard let player else { return }
        currentTime = player.currentTime
        updateActiveWavBlock()
    }

    private func speechTick() {
        if isPlaying { currentTime += 0.1 }
    }

    private func updateActiveWavBlock() {
        var newId = -1
        for block in wavBlocks {
            if let start = block.audioStart, let end = block.audioEnd,
               start <= currentTime, currentTime < end {
                newId = block.id
                break
            }
        }
        if activeBlockId != newId { activeBlockId = newId }
    }

    // MARK: - MPRemoteCommandCenter

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    func updateNowPlaying(title: String = "AudioBook", pageInfo: String = "") {
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: pageInfo,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(playbackRate) : 0.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

// MARK: - AVAudioPlayerDelegate

extension AudioPlayerManager: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            #if os(macOS)
            if self.isIrodoriMode {
                self.irodoriChunkDidFinish()
                return
            }
            #endif
            self.isPlaying = false
            self.stopTimer()
            self.onPlaybackFinished?()
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension AudioPlayerManager: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                        didStart utterance: AVSpeechUtterance) {
        let oid = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.isSpeechMode else { return }
            if let idx = self.speechUtterances.firstIndex(where: { ObjectIdentifier($0) == oid }),
               idx < self.utteranceBlockIds.count {
                self.currentUtteranceIndex = idx
                self.activeBlockId = self.utteranceBlockIds[idx]
                self.updateNowPlaying()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                        didFinish utterance: AVSpeechUtterance) {
        let oid = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.isSpeechMode else { return }
            if let last = self.speechUtterances.last, ObjectIdentifier(last) == oid {
                self.isPlaying = false
                self.activeBlockId = -1
                self.stopTimer()
                self.onPlaybackFinished?()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                        didCancel utterance: AVSpeechUtterance) {
        // stop() で処理済み
    }

    /// 発話中の文字範囲が変わるたびに呼ばれる。ブロックのハイライト位置を更新する。
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                        willSpeakRangeOfSpeechString characterRange: NSRange,
                                        utterance: AVSpeechUtterance) {
        let oid = ObjectIdentifier(utterance)
        let charStart = characterRange.location
        Task { @MainActor [weak self] in
            guard let self, self.isSpeechMode else { return }
            guard let utteranceIdx = self.speechUtterances.firstIndex(where: { ObjectIdentifier($0) == oid }) else { return }
            let groupIdx = utteranceIdx + self.groupStartOffset
            guard groupIdx < self.speechGroups.count else { return }
            let group = self.speechGroups[groupIdx]

            // charStart以下で最大のstartCharIndexを持つブロックが現在のブロック
            var activeId = group.blockRanges.first?.blockId ?? -1
            for br in group.blockRanges {
                if br.startCharIndex <= charStart {
                    activeId = br.blockId
                } else {
                    break
                }
            }
            if self.activeBlockId != activeId {
                self.activeBlockId = activeId
            }
        }
    }
}
