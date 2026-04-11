import SwiftUI

struct PlayerControlsView: View {
    @Bindable var audioManager: AudioPlayerManager
    let pageIndex: Int
    let totalPages: Int
    var onPrevPage: () -> Void
    var onNextPage: () -> Void

    private let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        VStack(spacing: 8) {
            // シークバー
            HStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { audioManager.duration > 0 ? audioManager.currentTime / audioManager.duration : 0 },
                        set: { audioManager.seek(to: $0 * audioManager.duration) }
                    ),
                    in: 0...1
                )
                Text("\(formatTime(audioManager.currentTime)) / \(formatTime(audioManager.duration))")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // コントロールボタン
            HStack(spacing: 16) {
                Button(action: onPrevPage) {
                    Image(systemName: "chevron.left")
                        .font(.title2)
                }
                .disabled(pageIndex <= 0)
                .keyboardShortcut(.leftArrow, modifiers: [])

                Button(action: { audioManager.togglePlayPause() }) {
                    Image(systemName: audioManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 36))
                }
                .keyboardShortcut(.space, modifiers: [])

                Button(action: onNextPage) {
                    Image(systemName: "chevron.right")
                        .font(.title2)
                }
                .disabled(pageIndex >= totalPages - 1)
                .keyboardShortcut(.rightArrow, modifiers: [])

                Spacer()

                // 速度ピッカー
                Picker("速度", selection: Binding(
                    get: { audioManager.playbackRate },
                    set: { audioManager.setRate($0) }
                )) {
                    ForEach(speeds, id: \.self) { speed in
                        Text("\(speed, specifier: "%.2g")x").tag(speed)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 80)

                Text("ページ \(pageIndex + 1) / \(totalPages)")
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
}
