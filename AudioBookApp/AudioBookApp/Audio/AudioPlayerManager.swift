import AVFoundation
import MediaPlayer

@MainActor
@Observable
final class AudioPlayerManager: NSObject, AVAudioPlayerDelegate {
    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    var playbackRate: Float = 1.0
    var activeBlockId: Int = -1

    /// 再生完了時に呼ばれるコールバック
    var onPlaybackFinished: (@MainActor () -> Void)?

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var currentBlocks: [TextBlock] = []

    override init() {
        super.init()
        setupRemoteCommands()
    }

    func loadAudio(url: URL, blocks: [TextBlock]) {
        stop()
        currentBlocks = blocks

        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.enableRate = true
            player?.prepareToPlay()
            duration = player?.duration ?? 0
            currentTime = 0
            activeBlockId = -1
        } catch {
            print("[ERROR] Failed to load audio: \(error)")
        }
    }

    func play() {
        guard let player else { return }
        player.rate = playbackRate
        player.play()
        isPlaying = true
        startTimer()
        updateNowPlaying()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        updateNowPlaying()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func stop() {
        player?.stop()
        isPlaying = false
        stopTimer()
    }

    func seek(to time: Double) {
        player?.currentTime = time
        currentTime = time
        updateActiveBlock()
        updateNowPlaying()
    }

    func seekToBlock(_ block: TextBlock) {
        guard let start = block.audioStart else { return }
        seek(to: start)
        if !isPlaying { play() }
    }

    func setRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            player?.rate = rate
        }
        updateNowPlaying()
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime
        updateActiveBlock()
    }

    private func updateActiveBlock() {
        var newId = -1
        for block in currentBlocks {
            if let start = block.audioStart, let end = block.audioEnd,
               start <= currentTime, currentTime < end {
                newId = block.id
                break
            }
        }
        if activeBlockId != newId {
            activeBlockId = newId
        }
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.stopTimer()
            self.onPlaybackFinished?()
        }
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
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
