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

    // MARK: - Shared timer

    private var timer: Timer?

    override init() {
        super.init()
        setupRemoteCommands()
    }

    // MARK: - Load

    /// url が nil またはファイルが存在しない場合は AVSpeechSynthesizer モードで動作する
    func loadAudio(url: URL?, blocks: [TextBlock]) {
        stop()

        if let url, FileManager.default.fileExists(atPath: url.path) {
            // ----- WAV モード -----
            isSpeechMode = false
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
        } else {
            // ----- 音声合成モード -----
            isSpeechMode = true
            // 割注・ルビ・ノンブル等をスキップし、本文とタイトルのみ読み上げる
            speechBlocks = blocks.filter { $0.isReadable }
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

    // MARK: - Play / Pause / Stop

    func play() {
        if isSpeechMode {
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
        if isSpeechMode {
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
        if isSpeechMode {
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
        if isSpeechMode {
            // 推定時間からブロックを特定してジャンプ
            guard !speechBlocks.isEmpty else { return }
            var accumulated = 0.0
            let charsPerSec = estimatedCharsPerSecond(rate: playbackRate)
            var targetIdx = 0
            for (i, block) in speechBlocks.enumerated() {
                let blockDuration = Double(block.text.count) / max(1, charsPerSec)
                if accumulated + blockDuration > time {
                    targetIdx = i
                    break
                }
                accumulated += blockDuration
                targetIdx = i + 1
            }
            let wasPlaying = isPlaying
            synthesizer?.stopSpeaking(at: .immediate)
            speechUtterances = []
            utteranceBlockIds = []
            currentUtteranceIndex = min(targetIdx, speechBlocks.count - 1)
            currentTime = time
            if wasPlaying { speakFrom(index: currentUtteranceIndex) }
        } else {
            player?.currentTime = time
            currentTime = time
            updateActiveWavBlock()
            updateNowPlaying()
        }
    }

    func seekToBlock(_ block: TextBlock) {
        if isSpeechMode {
            guard let idx = speechBlocks.firstIndex(where: { $0.id == block.id }) else { return }
            let wasPlaying = isPlaying
            synthesizer?.stopSpeaking(at: .immediate)
            speechUtterances = []
            utteranceBlockIds = []
            currentUtteranceIndex = idx
            if wasPlaying { speakFrom(index: idx) } else { speakFrom(index: idx) }
        } else {
            guard let start = block.audioStart else { return }
            seek(to: start)
            if !isPlaying { play() }
        }
    }

    func setRate(_ rate: Float) {
        playbackRate = rate
        if isSpeechMode {
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

        let startIdx = max(0, min(index, speechBlocks.count - 1))
        for block in speechBlocks[startIdx...] {
            let text = block.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let u = AVSpeechUtterance(string: text)
            u.voice = voice
            u.rate = utteranceRate
            u.postUtteranceDelay = 0.05
            speechUtterances.append(u)
            utteranceBlockIds.append(block.id)
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

    // MARK: - Duration Estimation

    private func estimatedCharsPerSecond(rate: Float) -> Double {
        // 日本語: デフォルト速度 (rate=1.0) で約 8〜10字/秒
        return 9.0 * Double(rate)
    }

    private func estimateSpeechDuration(blocks: [TextBlock], rate: Float) -> Double {
        let totalChars = blocks.reduce(0) { $0 + $1.text.count }
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
}

