import XCTest
@testable import PhotoWagon

/// Blend modes from the Layers panel and adjustment Properties: stepping through the modes,
/// clipping and resetting an adjustment layer, Normal vs Pass Through groups and the 15° turn
/// (BlendModesTests' model side).
@MainActor
final class BlendTests: XCTestCase {
    func testStepBlendGoesThroughTheMenuInOrderAndWraps() {
        XCTAssertEqual(EditorModel.stepBlend("Normal", by: 1, group: false), "Dissolve")
        XCTAssertEqual(EditorModel.stepBlend("Dissolve", by: 1, group: false), "Darken", "on to the next section")
        XCTAssertEqual(EditorModel.stepBlend("Normal", by: -1, group: false), "Luminosity", "wraps to the end")
        XCTAssertEqual(EditorModel.stepBlend("Normal", by: -1, group: true), "Pass Through", "a group starts at Pass Through")
        XCTAssertEqual(EditorModel.stepBlend("Pass Through", by: 1, group: true), "Normal")
        XCTAssertEqual(EditorModel.stepBlend("Pass Through", by: 1, group: false), "Normal", "unknown here: the first")
    }

    func testClipAndResetAnAdjustmentLayer() throws {
        let model = makeModel(width: 100, height: 100)
        model.run("layer.new.layer", ["name": "paint"])
        model.run("edit.fill", ["contents": "gray"])
        model.run("layer.newAdjustmentLayer.brightnessContrast", ["brightness": 60])
        let id = try XCTUnwrap(model.activeLayer?.id)
        model.toggleClip(id)
        XCTAssertEqual(model.activeLayer?.clipped, true)
        model.toggleClip(id)
        XCTAssertEqual(model.activeLayer?.clipped, false)
        XCTAssertNotEqual(model.activeLayer?.adjustment?.params["brightness"] as? Double, 0)
        model.run("layer.setAdjustment", ["layer": id])
        XCTAssertEqual((model.activeLayer?.adjustment?.params["brightness"] as? NSNumber)?.doubleValue, 0, "back to the defaults")
    }

    func testANormalGroupKeepsItsAdjustmentInside() throws {
        let model = makeModel(width: 100, height: 100)
        model.run("layer.new.layer", ["name": "inside"])
        model.run("select.rect", ["x": 0, "y": 0, "width": 50, "height": 100])
        model.run("edit.fill", ["contents": "gray"])
        model.run("select.deselect")
        model.run("layer.newAdjustmentLayer.invert")
        model.run("layer.select", ["layer": try XCTUnwrap(model.row("inside")?.id), "mode": "add"])
        model.run("layer.groupLayers")
        let group = try XCTUnwrap(model.layers.first(where: \.isGroup))
        XCTAssertEqual(group.blend, "Pass Through", "a new group passes through")
        XCTAssertEqual(model.mean([60, 0, 100, 100]).first ?? 1, 0, accuracy: 0.01, "the white background is inverted")
        model.run("layer.setProps", ["layer": group.id, "blend": "Normal"])
        XCTAssertEqual(model.mean([60, 0, 100, 100]).first ?? 0, 1, accuracy: 0.01, "a Normal group keeps it inside")
    }

    func testSnapRotationTurnsIn15DegreeSteps() throws {
        let model = makeModel(width: 400, height: 400)
        model.run("layer.new.layer", ["name": "square"])
        model.run("select.rect", ["x": 100, "y": 100, "width": 100, "height": 100])
        model.run("edit.fill")
        model.run("select.deselect")
        model.beginTransform()
        model.snapRotation = true
        let view = CanvasUIView(model: model)
        // Outside the box: turn about the centre (150, 150) by about 20°.
        view.drag(pt(260, 150), pt(260, 190), steps: 6)
        let angle = try XCTUnwrap(model.transform?.angle) * 180 / .pi
        XCTAssertEqual(angle.truncatingRemainder(dividingBy: 15), 0, accuracy: 0.01, "\(angle)°")
        XCTAssertNotEqual(angle, 0)
    }
}
