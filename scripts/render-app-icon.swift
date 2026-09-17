#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct RGBAImage {
    let width: Int
    let height: Int
    var pixels: [UInt8]
}

private func loadRGBA(from url: URL) throws -> RGBAImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        throw NSError(domain: "AgentAimIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取输入图片"])
    }

    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "AgentAimIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法创建像素画布"])
    }

    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return RGBAImage(width: width, height: height, pixels: pixels)
}

private func extractMark(from source: RGBAImage) throws -> CGImage {
    let scanInsetX = source.width / 6
    let scanInsetY = source.height / 6
    var minX = source.width
    var minY = source.height
    var maxX = 0
    var maxY = 0

    for y in scanInsetY..<(source.height - scanInsetY) {
        for x in scanInsetX..<(source.width - scanInsetX) {
            let index = (y * source.width + x) * 4
            let red = Int(source.pixels[index])
            let green = Int(source.pixels[index + 1])
            let blue = Int(source.pixels[index + 2])
            let isDark = (red + green + blue) / 3 < 165
            let isRed = red > 145 && red > green * 2 && red > blue * 2
            if isDark || isRed {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
    }

    guard minX <= maxX, minY <= maxY else {
        throw NSError(domain: "AgentAimIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "没有识别到图标主体"])
    }

    let padding = max(4, source.width / 160)
    minX = max(0, minX - padding)
    minY = max(0, minY - padding)
    maxX = min(source.width - 1, maxX + padding)
    maxY = min(source.height - 1, maxY + padding)

    let width = maxX - minX + 1
    let height = maxY - minY + 1
    var output = [UInt8](repeating: 0, count: width * height * 4)

    for y in 0..<height {
        for x in 0..<width {
            let sourceIndex = ((minY + y) * source.width + minX + x) * 4
            let destinationIndex = (y * width + x) * 4
            let red = Double(source.pixels[sourceIndex])
            let green = Double(source.pixels[sourceIndex + 1])
            let blue = Double(source.pixels[sourceIndex + 2])
            let distanceFromWhite = sqrt(
                pow(255 - red, 2) + pow(255 - green, 2) + pow(255 - blue, 2)
            )
            let alpha = max(0, min(1, (distanceFromWhite - 18) / 52))

            output[destinationIndex] = UInt8(red * alpha)
            output[destinationIndex + 1] = UInt8(green * alpha)
            output[destinationIndex + 2] = UInt8(blue * alpha)
            output[destinationIndex + 3] = UInt8(255 * alpha)
        }
    }

    guard let provider = CGDataProvider(data: Data(output) as CFData),
          let image = CGImage(
              width: width,
              height: height,
              bitsPerComponent: 8,
              bitsPerPixel: 32,
              bytesPerRow: width * 4,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
              provider: provider,
              decode: nil,
              shouldInterpolate: true,
              intent: .defaultIntent
          )
    else {
        throw NSError(domain: "AgentAimIcon", code: 4, userInfo: [NSLocalizedDescriptionKey: "无法生成透明标志"])
    }
    return image
}

private func renderIcon(mark: CGImage, size: Int = 1024) throws -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "AgentAimIcon", code: 5, userInfo: [NSLocalizedDescriptionKey: "无法创建最终图标画布"])
    }

    context.clear(CGRect(x: 0, y: 0, width: size, height: size))

    let tileInset = CGFloat(size) * 0.075
    let tileRect = CGRect(
        x: tileInset,
        y: tileInset + CGFloat(size) * 0.008,
        width: CGFloat(size) - tileInset * 2,
        height: CGFloat(size) - tileInset * 2
    )
    let cornerRadius = tileRect.width * 0.225
    let tilePath = CGPath(
        roundedRect: tileRect,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -CGFloat(size) * 0.018),
        blur: CGFloat(size) * 0.035,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.22)
    )
    context.addPath(tilePath)
    context.setFillColor(CGColor(red: 0.965, green: 0.961, blue: 0.945, alpha: 1))
    context.fillPath()
    context.restoreGState()

    context.addPath(tilePath)
    context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.08))
    context.setLineWidth(CGFloat(size) * 0.004)
    context.strokePath()

    let maximumMarkSize = CGFloat(size) * 0.55
    let aspectRatio = CGFloat(mark.width) / CGFloat(mark.height)
    let markWidth = aspectRatio >= 1 ? maximumMarkSize : maximumMarkSize * aspectRatio
    let markHeight = aspectRatio >= 1 ? maximumMarkSize / aspectRatio : maximumMarkSize
    let markRect = CGRect(
        x: (CGFloat(size) - markWidth) / 2,
        y: (CGFloat(size) - markHeight) / 2 + CGFloat(size) * 0.006,
        width: markWidth,
        height: markHeight
    )
    context.interpolationQuality = .high
    context.draw(mark, in: markRect)

    guard let image = context.makeImage() else {
        throw NSError(domain: "AgentAimIcon", code: 6, userInfo: [NSLocalizedDescriptionKey: "无法导出最终图标"])
    }
    return image
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw NSError(domain: "AgentAimIcon", code: 7, userInfo: [NSLocalizedDescriptionKey: "无法创建 PNG 输出"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "AgentAimIcon", code: 8, userInfo: [NSLocalizedDescriptionKey: "PNG 写入失败"])
    }
}

guard CommandLine.arguments.count == 3 else {
    fputs("用法：render-app-icon.swift <输入图片> <输出 PNG>\n", stderr)
    exit(2)
}

do {
    let source = try loadRGBA(from: URL(fileURLWithPath: CommandLine.arguments[1]))
    let mark = try extractMark(from: source)
    let icon = try renderIcon(mark: mark)
    try writePNG(icon, to: URL(fileURLWithPath: CommandLine.arguments[2]))
} catch {
    fputs("生成图标失败：\(error.localizedDescription)\n", stderr)
    exit(1)
}
