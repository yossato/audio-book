import SwiftUI

struct PageImageView: View {
    let imagePath: String
    let blocks: [TextBlock]
    let activeBlockId: Int
    var onBlockTapped: ((TextBlock) -> Void)?

    var body: some View {
        GeometryReader { geo in
            let nsImage = NSImage(contentsOfFile: imagePath)
            if let nsImage {
                let pixelSize = pixelSize(of: nsImage)
                let scale = min(
                    geo.size.width / pixelSize.width,
                    geo.size.height / pixelSize.height
                )
                let scaledW = pixelSize.width * scale
                let scaledH = pixelSize.height * scale
                let offsetX = (geo.size.width - scaledW) / 2
                let offsetY = (geo.size.height - scaledH) / 2

                ZStack(alignment: .topLeading) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: scaledW, height: scaledH)

                    // バウンディングボックスオーバーレイ
                    ForEach(blocks) { block in
                        let rect = scaledRect(block: block, scale: scale)
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
                .frame(width: scaledW, height: scaledH)
                .offset(x: offsetX, y: offsetY)
            } else {
                Text("画像を読み込めません")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func pixelSize(of image: NSImage) -> CGSize {
        guard let rep = image.representations.first else {
            return image.size
        }
        return CGSize(width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh))
    }

    private func scaledRect(block: TextBlock, scale: CGFloat) -> CGRect {
        guard block.bbox.count == 4 else { return .zero }
        let x1 = block.bbox[0] * scale
        let y1 = block.bbox[1] * scale
        let x2 = block.bbox[2] * scale
        let y2 = block.bbox[3] * scale
        return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }
}
