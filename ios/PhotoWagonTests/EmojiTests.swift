import XCTest
@testable import PhotoWagon

/// Emoji in type layers draw in colour (iOS stores them in a format only Core Text reads).
@MainActor
final class EmojiTests: XCTestCase {
    func testEmojiDrawInColour() throws {
        let model = makeModel(width: 400, height: 300)
        // Fonts load on a background thread; add the emoji font now.
        _ = addFonts(paths: EditorModel.installedFontFiles().filter { $0.contains("Emoji") })
        model.run("type.create", ["x": 50, "y": 150, "text": "A😀", "size": 60])
        var yellow = 0
        for y in stride(from: 80, to: 160, by: 4) {
            for x in stride(from: 80, to: 200, by: 4) {
                let p = model.pixel(x, y)
                if p.count >= 3, p[0] > 0.8, p[1] > 0.55, p[2] < 0.4 { yellow += 1 }
            }
        }
        XCTAssertGreaterThan(yellow, 20, "the grinning face is yellow")
    }

    func testTheDrawerSkipsUnknownFonts() {
        let drawer = EmojiGlyphs()
        XCTAssertNil(drawer.draw(postscriptName: "NoSuchFont-Regular", glyphId: 5, sizePx: 40))
        XCTAssertNil(drawer.draw(postscriptName: "AppleColorEmoji", glyphId: 5, sizePx: 0))
        let g = drawer.draw(postscriptName: "AppleColorEmoji", glyphId: 100, sizePx: 40)
        XCTAssertEqual(g.map { $0.rgba.count }, g.map { Int($0.width * $0.height * 4) })
    }

    func testPlainTextStillDrawsOnceAllFontsAreLoaded() throws {
        let model = makeModel(width: 400, height: 300)
        _ = addFonts(paths: EditorModel.installedFontFiles())
        model.run("type.create", ["x": 50, "y": 150, "text": "Hi", "size": 60, "color": "#000000"])
        let b = try XCTUnwrap(model.activeLayer?.bounds)
        XCTAssertGreaterThan(b[2], 20, "the letters have pixels: \(b)")
    }
}
