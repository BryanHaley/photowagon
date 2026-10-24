import XCTest
@testable import PhotoWagon

/// The brush's options: Brush Settings paths, mode, flow, smoothing, the pressure buttons, erasing
/// with the brush, symmetry and brush presets.
@MainActor
final class BrushOptionsTests: XCTestCase {
    private func brush(_ model: EditorModel) -> [String: Any] { model.query("brush.get") as? [String: Any] ?? [:] }

    func testBrushSettingsSetNestedValues() {
        XCTAssertEqual(BrushPaths.patch("a.b.c", 1) as NSDictionary, ["a": ["b": ["c": 1]]] as NSDictionary)
        let model = makeModel(width: 100, height: 100)
        model.setBrush(path: "shapeDynamics.enabled", true)
        model.setBrush(path: "shapeDynamics.size.control", "penPressure")
        model.setBrush(path: "shapeDynamics.size.jitter", 0.5)
        model.setBrush(path: "scattering.count", 4)
        let b = brush(model)
        XCTAssertEqual(BrushPaths.get(b, "shapeDynamics.size.control") as? String, "penPressure")
        XCTAssertEqual((BrushPaths.get(b, "shapeDynamics.size.jitter") as? NSNumber)?.doubleValue ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(BrushPaths.get(b, "shapeDynamics.enabled") as? Bool, true, "the rest of the section stays")
        XCTAssertEqual(BrushPaths.get(b, "scattering.count") as? Int, 4)
        XCTAssertNotNil(try model.editor.brushPreview(width: 300, height: 90))
    }

    func testTheBarsOptionsReachTheBrush() {
        let model = makeModel(width: 100, height: 100)
        model.setBrush("flow", 0.3)
        model.setBrush(path: "smoothing.amount", 0.6)
        model.setBrush(path: "pressureSize", true)
        model.setBrush(path: "mode", EditorModel.engineMode("Linear Dodge (Add)"))
        XCTAssertEqual(model.flow, 0.3, accuracy: 0.001)
        XCTAssertEqual(model.smoothing, 0.6, accuracy: 0.001)
        XCTAssert(model.pressureSize)
        XCTAssertEqual(model.brushMode, "LinearDodge")
        XCTAssertEqual(EditorModel.modeTitle(model.brushMode), "Linear Dodge (Add)")
    }

    func testArrowKeysTurnTheBrushTip() {
        let model = makeModel(width: 100, height: 100)
        let angle = { (self.brush(model)["angle"] as? NSNumber)?.doubleValue ?? .nan }
        let start = angle()
        model.rotateBrush(clockwise: true, shift: true)
        XCTAssertEqual(angle(), start - 15, accuracy: 0.01, "→ with ⇧: 15° clockwise")
        model.rotateBrush(clockwise: false, shift: false)
        XCTAssertEqual(angle(), start - 14, accuracy: 0.01, "←: a degree back")
    }

    func testTheAngleDialReadsTheTouch() {
        let c = CGPoint(x: 100, y: 100)
        XCTAssertEqual(BrushAngleDial.angle(at: CGPoint(x: 150, y: 100), center: c), 0)
        XCTAssertEqual(BrushAngleDial.angle(at: CGPoint(x: 100, y: 50), center: c), 90, "up is anticlockwise")
        XCTAssertEqual(BrushAngleDial.angle(at: CGPoint(x: 100, y: 150), center: c), -90)
        XCTAssertEqual(BrushAngleDial.wrapped(195), -165)
        XCTAssertEqual(BrushAngleDial.wrapped(-180), -180)
    }

    func testDifferenceWithWhiteOnWhitePaintsBlack() {
        let model = makeModel(width: 100, height: 100)
        model.setForeground(.white)
        model.run("edit.fill")
        model.setBrush(path: "mode", "Difference")
        model.setBrush("size", 30)
        model.setBrush("hardness", 1)
        let canvas = CanvasUIView(model: model)
        canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        model.tool = .brush
        canvas.drag(pt(20, 50), pt(80, 50))
        XCTAssertLessThan(model.pixel(50, 50).first ?? 1, 0.05)
        XCTAssertGreaterThan(model.pixel(50, 90).first ?? 0, 0.95, "outside the stroke")
    }

    func testTheBrushCanEraseWhileHeld() {
        let model = makeModel(width: 100, height: 100)
        model.run("layer.new.layer", ["name": "paint"])
        model.setForeground(.black)
        model.run("edit.fill")
        XCTAssertLessThan(model.pixel(50, 50).first ?? 1, 0.05)
        model.setBrush(path: "erase", true)
        XCTAssert(model.brushErases)
        let canvas = CanvasUIView(model: model)
        canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        model.tool = .brush
        model.setBrush("hardness", 1)
        canvas.drag(pt(20, 50), pt(80, 50))
        XCTAssertGreaterThan(model.pixel(50, 50).first ?? 0, 0.95, "erased: the white Background shows")
        model.setBrush(path: "erase", false)
        XCTAssertFalse(model.brushErases)
    }

    func testSymmetryMirrorsAcrossTheMiddle() {
        let model = makeModel(width: 100, height: 80)
        model.setSymmetry("vertical")
        XCTAssertEqual(model.symmetry, "vertical")
        XCTAssertEqual(model.symmetryLines, [50, 0, 50, 80])
        model.setForeground(.black)
        let canvas = CanvasUIView(model: model)
        canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        model.tool = .brush
        model.setBrush("hardness", 1)
        canvas.drag(pt(10, 40), pt(25, 40))
        XCTAssertLessThan(model.pixel(83, 40).first ?? 1, 0.1, "the mirrored stroke")
        model.setSymmetry("dual")
        XCTAssertEqual(model.symmetryLines.count, 8, "two axes")
        model.setSymmetry("")
        XCTAssertEqual(model.symmetry, "")
        XCTAssert(model.symmetryLines.isEmpty)
    }

    func testDefineAndSaveBrushPresets() {
        let model = makeModel(width: 100, height: 100)
        model.setForeground(.black)
        model.run("select.rect", ["x": 20, "y": 20, "width": 30, "height": 30])
        model.run("edit.fill")
        model.run("brush.defineFromSelection", ["name": "square"])
        model.reloadBrushPresets()
        XCTAssert(model.brushGroups.flatMap(\.presets).contains("square"))
        model.setBrush("flow", 0.4)
        model.run("brush.presets.save", ["name": "my dust", "toolSettings": true])
        model.reloadBrushPresets()
        XCTAssert(model.brushGroups.flatMap(\.presets).contains("my dust"))
        model.setBrush("flow", 1)
        model.run("tools.setBrush", ["preset": "my dust"])
        XCTAssertEqual(model.flow, 0.4, accuracy: 0.001, "Include Tool Settings brings the flow back")
    }

    /// The size circle goes away even when the slider never reports the let-go.
    func testSizePreviewHidesAfterTheLastChange() {
        let model = makeModel(width: 100, height: 100)
        model.sizePreview(editing: true, after: 0.1)
        XCTAssertTrue(model.showSizePreview)
        wait("the circle hides") { !model.showSizePreview }
        model.sizePreview(editing: true, after: 10)
        model.sizePreview(editing: false)
        XCTAssertFalse(model.showSizePreview, "letting go hides it at once")
    }
}
