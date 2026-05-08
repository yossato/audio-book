import SwiftUI

struct PlayerControlsView: View {
    @Bindable var audioManager: AudioPlayerManager
    let pageIndex: Int
    let totalPages: Int
    var onPrevPage: () -> Void
    var onNextPage: () -> Void
    var onPageChange: (Int) -> Void

    @State private var sliderPage: Double = 0
    @State private var isDragging = false

    private let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        VStack(spacing: 8) {
            // ページスライダー（Kindle 風）
            HStack(spacing: 8) {
                Text("\(displayPage)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .trailing)

                Slider(
                    value: $sliderPage,
                    in: 0...max(1, Double(totalPages - 1)),
                    step: 1,
                    onEditingChanged: { editing in
                        isDragging = editing
                        if !editing {
                            onPageChange(Int(sliderPage))
                        }
                    }
                )

                Text("/ \(totalPages)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .leading)
            }

            // コントロールボタン
            HStack(spacing: 16) {
                Button(action: onPrevPage) {
                    Image(systemName: "chevron.left")
                        .font(.title2)
                }
                .disabled(pageIndex <= 0)
                #if os(macOS)
                .keyboardShortcut(.leftArrow, modifiers: [])
                #endif

                Button(action: { audioManager.togglePlayPause() }) {
                    if audioManager.isIrodoriGenerating {
                        ProgressView()
                            .controlSize(.regular)
                            .frame(width: 36, height: 36)
                    } else {
                        Image(systemName: audioManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 36))
                    }
                }
                #if os(macOS)
                .keyboardShortcut(.space, modifiers: [])
                #endif

                Button(action: onNextPage) {
                    Image(systemName: "chevron.right")
                        .font(.title2)
                }
                .disabled(pageIndex >= totalPages - 1)
                #if os(macOS)
                .keyboardShortcut(.rightArrow, modifiers: [])
                #endif

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
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .onAppear { sliderPage = Double(pageIndex) }
        .onChange(of: pageIndex) { _, newValue in
            if !isDragging {
                sliderPage = Double(newValue)
            }
        }
    }

    /// ドラッグ中はスライダー値、それ以外は実際のページを表示
    private var displayPage: Int {
        isDragging ? Int(sliderPage) + 1 : pageIndex + 1
    }
}
