import XCTest
@testable import PhotoWagon

/// The Crop and Rotate screen's frame, and the ☰ menu's quick actions.
@MainActor
final class CropRotateTests: XCTestCase {
    private func near(_ a: CGPoint, _ b: CGPoint, _ what: String) {
        XCTAssertEqual(a.x, b.x, accuracy: 1e-6, what)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-6, what)
    }

    func testWholeImageAndItsParams() {
        let f = CropFrame(width: 800, height: 600)
        XCTAssertEqual(f.params["x"] as? Double, 0)
        XCTAssertEqual(f.params["width"] as? Double, 800)
        XCTAssertEqual(f.params["angle"] as? Double, 0)
    }

    func testCornerAndEdgeDrags() {
        let f = CropFrame(width: 800, height: 600)
        // Bottom-right corner in by 50×30 points at 0.5 points a pixel: 100×60 pixels.
        let g = f.resized(.init(x: 1, y: 1), by: CGVector(dx: -50, dy: -30), scale: 0.5, aspect: nil)
        XCTAssertEqual(g.size, CGSize(width: 700, height: 540))
        near(g.center, CGPoint(x: 350, y: 270), "the top-left corner stays")
        // Past the image: the box (and the canvas) grows.
        let h = f.resized(.init(x: -1, y: 0), by: CGVector(dx: -100, dy: 0), scale: 1, aspect: nil)
        XCTAssertEqual(h.size.width, 900)
        XCTAssertEqual(h.params["x"] as? Double, -100)
        // Never smaller than the minimum.
        let tiny = f.resized(.init(x: 1, y: 0), by: CGVector(dx: -5000, dy: 0), scale: 1, aspect: nil)
        XCTAssertEqual(tiny.size.width, CropFrame.minSide)
    }

    func testARatioKeepsItsShape() {
        let f = CropFrame(width: 800, height: 600)
        let corner = f.resized(.init(x: 1, y: 1), by: CGVector(dx: -200, dy: 0), scale: 1, aspect: 1)
        XCTAssertEqual(corner.size.width, corner.size.height, accuracy: 1e-6)
        let edge = f.resized(.init(x: 1, y: 0), by: CGVector(dx: -200, dy: 0), scale: 1, aspect: 2)
        XCTAssertEqual(edge.size, CGSize(width: 600, height: 300))
        XCTAssertEqual(edge.center.y, 300, accuracy: 1e-6, "an edge grows the other way about the middle")
        XCTAssertEqual(f.fitted(to: 1).size, CGSize(width: 600, height: 600))
        XCTAssertEqual(CropAspect.original.ratio(image: CGSize(width: 800, height: 600)) ?? 0, 4.0 / 3, accuracy: 1e-9)
        XCTAssertNil(CropAspect.freeform.ratio(image: .zero))
        XCTAssertEqual(CropAspect.r16x9.title, "16:9")
    }

    func testTurnedFrameMovesAlongItsOwnAxes() {
        var f = CropFrame(width: 800, height: 600)
        f.angle = 90
        // Dragging the image right moves the box left along the box's x, the document's -y here.
        let p = f.panned(by: CGVector(dx: 10, dy: 0), scale: 1)
        near(p.center, CGPoint(x: 400, y: 290), "pan")
        XCTAssertEqual(CropFrame.normalized(270), -90)
    }

    func testAutoEnhanceUsesDevelopsAuto() {
        let dark = [SIMD3<Float>](repeating: SIMD3(40, 40, 60), count: 400)
        let p = EditorModel.autoEnhanceParams(dark)
        XCTAssertGreaterThan(p["exposure"] as? Double ?? 0, 0, "a dark image gets brighter")
        XCTAssertNotEqual(p["temperature"] as? Double ?? 0, 0, "and the blue cast balanced")
        XCTAssertTrue(EditorModel.autoEnhanceParams([]).isEmpty)
    }

    func testQuickActionsUnderQuickShare() {
        let model = makeModel(width: 100, height: 100)
        let titles = MainMenu(model: model).quickActions().compactMap { ($0 as? UIAction)?.title }
        XCTAssertEqual(titles, ["Crop and Rotate", "Auto Enhance", "Develop", "Curves", "Levels", "Select All", "Select None", "Copy", "Copy Merged", "Paste"])
        let none = MainMenu(model: makeModel()).quickActions().compactMap { $0 as? UIAction }
        XCTAssertTrue(none.allSatisfy { $0.attributes.contains(.disabled) }, "nothing open")
    }

    func testAutoEnhanceRunsOnTheImage() {
        let model = makeModel(width: 64, height: 64)
        model.run("edit.fill", ["use": "color", "color": "#203040"])
        let before = model.mean()
        model.autoEnhance()
        idle(model)
        XCTAssertNotEqual(model.mean().first ?? 0, before.first ?? 0, accuracy: 0.005, "it changed the image")
        XCTAssertEqual(model.historyNames.last, "Develop")
    }

    /// Turning keeps the box on the image: shrunk, the same shape, every corner inside.
    func testTurningKeepsTheBoxOnTheImage() {
        var f = CropFrame(width: 800, height: 600)
        f.angle = 10
        let k = f.keptInside(width: 800, height: 600)
        XCTAssertLessThan(k.size.width, 800)
        XCTAssertEqual(k.size.width / k.size.height, 800.0 / 600, accuracy: 1e-6, "the same shape")
        for cx in [-1.0, 1] {
            for cy in [-1.0, 1] {
                let v = k.toDocument(CGVector(dx: cx * k.size.width / 2, dy: cy * k.size.height / 2))
                let (x, y) = (k.center.x + v.dx, k.center.y + v.dy)
                XCTAssert((-1e-6...800 + 1e-6).contains(x) && (-1e-6...600 + 1e-6).contains(y), "corner \(x), \(y) on the image")
            }
        }
        XCTAssertTrue(f.addsCanvas(width: 800, height: 600))
        XCTAssertFalse(k.addsCanvas(width: 800, height: 600))
        // Unturned, the whole image already fits; off the image, the box comes back onto it.
        XCTAssertEqual(CropFrame(width: 800, height: 600).keptInside(width: 800, height: 600).size, CGSize(width: 800, height: 600))
        var off = CropFrame(width: 100, height: 100)
        off.center = CGPoint(x: -50, y: 50)
        XCTAssertGreaterThanOrEqual(off.keptInside(width: 800, height: 600).center.x, 0)
    }

    func testTheImagesCornersInTheCroppedDocument() {
        // A box past the left edge by 100: the image starts 100 in.
        let f = CropFrame(width: 800, height: 600).resized(.init(x: -1, y: 0), by: CGVector(dx: -100, dy: 0), scale: 1, aspect: nil)
        let c = f.imageCorners(width: 800, height: 600)
        XCTAssertEqual(c[0].x, 100, accuracy: 1e-6)
        XCTAssertEqual(c[2].x, 900, accuracy: 1e-6)
        XCTAssertEqual(c[2].y, 600, accuracy: 1e-6)
    }

    /// Crop and Rotate's fills for the canvas it adds.
    func testWhatFillsTheAddedCanvas() {
        for (fill, alpha) in [(CropFill.color, 1.0), (.transparent, 0.0)] {
            let model = makeModel(width: 100, height: 100)
            let f = CropFrame(width: 100, height: 100).resized(.init(x: 1, y: 0), by: CGVector(dx: 50, dy: 0), scale: 1, aspect: nil)
            model.cropRotate(f, fill: fill, image: CGSize(width: 100, height: 100))
            idle(model)
            XCTAssertEqual(model.doc?.width, 150, "\(fill)")
            XCTAssertEqual(model.pixel(140, 50).last ?? -1, alpha, accuracy: 0.01, "\(fill): the added canvas")
        }
    }

    /// Colour: the added canvas in the colour picked; the background colour comes back after.
    func testColourFillUsesThePickedColour() {
        let model = makeModel(width: 100, height: 100)
        let before = model.backgroundColor.hex
        let f = CropFrame(width: 100, height: 100).resized(.init(x: 1, y: 0), by: CGVector(dx: 50, dy: 0), scale: 1, aspect: nil)
        model.cropRotate(f, fill: .color, color: .red, image: CGSize(width: 100, height: 100))
        idle(model)
        XCTAssertEqual(model.pixel(140, 50), [1, 0, 0, 1])
        XCTAssertEqual(model.backgroundColor.hex, before)
    }

    /// Three quarter turns clockwise keep going clockwise (no snapping back the other way).
    func testQuarterTurnsKeepTheirDirection() {
        var f = CropFrame(width: 100, height: 50)
        for _ in 0..<3 { f = f.turned(to: f.angle - 90, size: CGSize(width: f.size.height, height: f.size.width), inside: nil) }
        XCTAssertEqual(f.angle, -270)
        XCTAssertEqual(f.params["angle"] as? Double, 90, "the engine gets it within a turn")
    }

    /// Keep Inside Image shrinks the box while turning, and turning back grows it to its old size.
    func testTurningBackGrowsTheBox() {
        let full = CropFrame(width: 800, height: 600)
        let image = CGSize(width: 800, height: 600)
        let tilted = full.turned(to: 20, size: full.size, inside: image)
        XCTAssertLessThan(tilted.size.width, 700)
        let back = tilted.turned(to: 0, size: full.size, inside: image)
        near(CGPoint(x: back.size.width, y: back.size.height), CGPoint(x: 800, y: 600), "grown back")
        XCTAssertEqual(tilted.turned(to: 0, size: tilted.size, inside: image).size, tilted.size, "without the old size it stays small")
    }
}
