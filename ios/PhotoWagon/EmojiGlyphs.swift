import CoreText
import Foundation

/// Draws emoji for the engine with Core Text: iOS stores them in a format only the system reads.
final class EmojiGlyphs: ColorGlyphDrawer, @unchecked Sendable {
    func draw(postscriptName: String, glyphId: UInt32, sizePx: Float) -> ColorGlyph? {
        guard sizePx > 0, sizePx <= 1024, let id = CGGlyph(exactly: glyphId) else { return nil }
        let font = CTFontCreateWithName(postscriptName as CFString, CGFloat(sizePx), nil)
        // The name may resolve to a substitute font; only draw the face that was asked for.
        guard CTFontCopyPostScriptName(font) as String == postscriptName else { return nil }
        var glyph = id
        var box = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1)
        if box.isNull || box.isEmpty {
            let advance = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, nil, 1)
            box = CGRect(x: 0, y: -CTFontGetDescent(font), width: advance, height: CTFontGetAscent(font) + CTFontGetDescent(font))
        }
        let left = floor(box.minX), bottom = floor(box.minY)
        let width = Int(ceil(box.maxX) - left), height = Int(ceil(box.maxY) - bottom)
        guard width > 0, height > 0, width <= 2048, height <= 2048, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        var position = CGPoint(x: -left, y: -bottom)
        CTFontDrawGlyphs(font, &glyph, &position, 1, ctx)
        guard let data = ctx.data else { return nil }
        let rgba = Data(bytes: data, count: width * height * 4)
        return ColorGlyph(width: UInt32(width), height: UInt32(height), rgba: rgba, left: Float(left), top: Float(bottom) + Float(height))
    }
}
