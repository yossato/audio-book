import SwiftUI

#if canImport(AppKit)
import AppKit
typealias PlatformNativeImage = NSImage
#elseif canImport(UIKit)
import UIKit
typealias PlatformNativeImage = UIImage
#endif

func loadPlatformImage(contentsOfFile path: String) -> PlatformNativeImage? {
    #if canImport(AppKit)
    return NSImage(contentsOfFile: path)
    #elseif canImport(UIKit)
    return UIImage(contentsOfFile: path)
    #endif
}

func loadPlatformImage(contentsOf url: URL) -> PlatformNativeImage? {
    #if canImport(AppKit)
    return NSImage(contentsOf: url)
    #elseif canImport(UIKit)
    guard let data = try? Data(contentsOf: url) else { return nil }
    return UIImage(data: data)
    #endif
}

func swiftUIImage(from image: PlatformNativeImage) -> Image {
    #if canImport(AppKit)
    return Image(nsImage: image)
    #elseif canImport(UIKit)
    return Image(uiImage: image)
    #endif
}

func pixelSize(of image: PlatformNativeImage) -> CGSize {
    #if canImport(AppKit)
    guard let rep = image.representations.first else { return image.size }
    return CGSize(width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh))
    #elseif canImport(UIKit)
    return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    #endif
}
