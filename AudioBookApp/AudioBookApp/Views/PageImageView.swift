import SwiftUI

struct PageImageView: View {
    let imagePath: String
    let blocks: [TextBlock]
    let activeBlockId: Int
    var onBlockTapped: ((TextBlock) -> Void)?
    var onBackgroundTapped: (() -> Void)?

    var body: some View {
        GeometryReader { geo in
            let imageURL = URL(fileURLWithPath: imagePath)
            let platformImage = loadPlatformImage(contentsOf: imageURL)
            if let platformImage {
                let imgPixelSize = pixelSize(of: platformImage)
                let scale = min(
                    geo.size.width / imgPixelSize.width,
                    geo.size.height / imgPixelSize.height
                )
                let scaledW = imgPixelSize.width * scale
                let scaledH = imgPixelSize.height * scale
                let offsetX = (geo.size.width - scaledW) / 2
                let offsetY = (geo.size.height - scaledH) / 2

                ZStack(alignment: .topLeading) {
                    swiftUIImage(from: platformImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: scaledW, height: scaledH)

                    // 背景タップ（バウンディングボックス外のタップ → 全画面トグル）
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: scaledW, height: scaledH)
                        .onTapGesture {
                            onBackgroundTapped?()
                        }

                    // バウンディングボックスオーバーレイ
                    ForEach(blocks) { block in
                        let rect = scaledRect(block: block, scale: scale)
                        if rect != .zero {
                            let isActive = block.id == activeBlockId
                            let isFootnote = !block.isReadable
                            Rectangle()
                                .fill(isActive
                                      ? Color.yellow.opacity(0.3)
                                      : isFootnote
                                        ? Color.gray.opacity(0.15)
                                        : Color.clear)
                                .overlay(
                                    Rectangle()
                                        .stroke(
                                            isActive
                                            ? Color.orange
                                            : isFootnote
                                              ? Color.gray.opacity(0.3)
                                              : Color.blue.opacity(0.25),
                                            lineWidth: isActive ? 2 : 1
                                        )
                                )
                                .contentShape(Rectangle())
                                .frame(width: rect.width, height: rect.height)
                                .offset(x: rect.minX, y: rect.minY)
                                .onTapGesture {
                                    guard block.isReadable else { return }
                                    onBlockTapped?(block)
                                }
                        }
                    }
                }
                .frame(width: scaledW, height: scaledH)
                .offset(x: offsetX, y: offsetY)
            } else {
                Text("画像を読み込めません")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        #if canImport(AppKit)
        .background(Color(nsColor: .windowBackgroundColor))
        #else
        .background(Color(uiColor: .systemBackground))
        #endif
    }

    private func scaledRect(block: TextBlock, scale: CGFloat) -> CGRect {
        guard let bbox = block.bbox, bbox.count == 4 else { return .zero }
        let x1 = bbox[0] * scale
        let y1 = bbox[1] * scale
        let x2 = bbox[2] * scale
        let y2 = bbox[3] * scale
        return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }
}
