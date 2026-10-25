import CoreVideo
import XCTest
@testable import PhotoWagon

/// App logic with the real engine and no UI: quick checks of what the walkthroughs drive.
@MainActor
final class ModelTests: XCTestCase {
    func testImportingABrushFileAddsItsTip() throws {
        let model = EditorModel()
        model.importBrushTips(sample("speckle.gbr"))
        XCTAssertEqual(model.toast, "Added 1 brush tip")
        XCTAssert(model.brushGroups.contains { $0.presets.contains("Speckle") }, "\(model.brushGroups.map(\.name))")
    }

    func testThumbnailsComeFromTheFile() async throws {
        let image = await FileThumbnail.make(sample("curls.jpg"), scale: 2)
        XCTAssertNotNil(image, "a photo's thumbnail")
        let none = await FileThumbnail.make(URL(fileURLWithPath: "/nonexistent/x.pcraft"), scale: 2)
        XCTAssertNil(none)
    }

    func testRefineSelectionIsInTheSelectMenu() throws {
        let model = EditorModel()
        let c = try XCTUnwrap(model.editor.commands().first { $0.id == "select.refineEdge" })
        XCTAssertEqual(c.label, "Refine Selection…")
        XCTAssert(c.menu.hasPrefix("Select"), c.menu)
        XCTAssert(MenuTree.shows(c))
    }

    /// Refine Hair's merge: the person matte's softer edge is taken only near a mostly-person mask.
    func testThePersonMatteSoftensOnlyTheObjectsEdge() throws {
        let (w, h) = (40, 40)
        // The object: a 10–30 square. The matte: the same square plus a soft fringe to x = 34,
        // and another person far away at 0–3.
        var mask = Data((0..<w * h).map { i -> UInt8 in (10..<30).contains(i % w) && (10..<30).contains(i / w) ? 255 : 0 })
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_OneComponent8, nil, &buffer)
        let matte = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(matte, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(matte))
        let row = CVPixelBufferGetBytesPerRow(matte)
        for y in 0..<h {
            for x in 0..<w {
                let inSquare = (10..<34).contains(x) && (10..<30).contains(y)
                let v: UInt8 = x < 3 ? 255 : !inSquare ? 0 : x < 30 ? 255 : 128
                base.storeBytes(of: v, toByteOffset: y * row + x, as: UInt8.self)
            }
        }
        CVPixelBufferUnlockBaseAddress(matte, [])
        ObjectFinder.addHair(&mask, w, h, matte)
        XCTAssertEqual(mask[20 * w + 30], 128, "the fringe just outside is taken")
        XCTAssertEqual(mask[20 * w + 1], 0, "the other person, far away, isn't")
        XCTAssertEqual(mask[20 * w + 20], 255)
    }

    /// Toasts stay listed after they go, for the UI tests; the list keeps the last 50.
    func testToastsAreKept() {
        let model = makeModel()
        for i in 0..<55 { model.toast = "t\(i)" }
        model.toast = nil
        XCTAssertEqual(model.toasts.count, 50)
        XCTAssertEqual(model.toasts.last, "t54")
    }
}
