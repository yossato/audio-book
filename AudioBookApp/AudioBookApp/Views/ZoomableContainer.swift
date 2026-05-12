import SwiftUI

/// ピンチズームとパンをサポートするコンテナビュー
struct ZoomableContainer<Content: View>: View {
    let pageIndex: Int
    @ViewBuilder let content: () -> Content

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 5.0

    var body: some View {
        content()
            .scaleEffect(scale)
            .offset(offset)
            .gesture(magnificationGesture)
            .if(scale > 1.0) { view in
                view.gesture(panGesture)
            }
            .onTapGesture(count: 2) {
                if scale > 1.0 {
                    resetZoom()
                } else {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        scale = 2.5
                        lastScale = 2.5
                    }
                }
            }
            .onChange(of: pageIndex) { _, _ in
                resetZoom()
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let newScale = lastScale * value
                scale = min(max(newScale, minScale), maxScale)
            }
            .onEnded { _ in
                if scale <= 1.0 {
                    resetZoom()
                } else {
                    lastScale = scale
                }
            }
    }

    /// ズーム中のみパン操作を有効化（スワイプページ送りと競合しない）
    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1.0 else { return }
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                guard scale > 1.0 else { return }
                lastOffset = offset
            }
    }

    private func resetZoom() {
        withAnimation(.easeInOut(duration: 0.25)) {
            scale = 1.0
            lastScale = 1.0
            offset = .zero
            lastOffset = .zero
        }
    }
}

// MARK: - View Extension for Conditional Modifiers

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
