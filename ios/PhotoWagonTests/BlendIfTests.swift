import XCTest
@testable import PhotoWagon

/// Blend If by colour channel, a Blend If layer made into a selection, Clear Layer Style and
/// copying a Live Filter (BlendIfSlidersTests' model side).
@MainActor
final class BlendIfTests: XCTestCase {
    /// A blue square and a black stripe on a new layer over the white Background.
    private func blueSquare() throws -> (EditorModel, UInt64) {
        let model = makeModel(width: 200, height: 200)
        model.run("layer.new.layer", ["name": "sky"])
        model.setForeground(.blue)
        model.run("select.rect", ["x": 50, "y": 50, "width": 100, "height": 100])
        model.run("edit.fill")
        model.setForeground(.black)
        model.run("select.rect", ["x": 50, "y": 160, "width": 100, "height": 10])
        model.run("edit.fill")
        model.run("select.deselect")
        return (model, try XCTUnwrap(model.row("sky")?.id))
    }

    func testBlendIfBlueHidesTheBlueAndLeavesGrayAlone() throws {
        let (model, layer) = try blueSquare()
        let style = LayerStyleState(model: model, layer: layer, start: "blendingOptions")
        XCTAssertEqual(style.blendIfChannels.compactMap { $0["channel"] as? String }, ["gray", "red", "green", "blue"])
        XCTAssertLessThan(model.pixel(100, 100).first ?? 1, 0.1, "blue shows")
        style.setBlendIf("blue", "thisLayer", [0, 0, 100, 160])
        XCTAssertEqual(model.pixel(100, 100).first ?? 0, 1, accuracy: 0.01, "bright blue hidden: the white shows")
        XCTAssertEqual(style.blendIfRange("gray", "thisLayer"), [0, 0, 255, 255])
        XCTAssertEqual(LayerStyleState(model: model, layer: layer, start: "blendingOptions").blendIfRange("blue", "thisLayer"), [0, 0, 100, 160],
                       "read back on reopening")

        // An Embedded Layer keeps what Blend If hid as transparency, so it loads as a selection.
        model.run("layer.smartObjects.convertToSmartObject")
        model.loadSelection("transparency")
        let mean = ((model.query("document.stats", ["of": "selection", "rect": [60, 60, 140, 140]]) as? [String: Any])?["mean"] as? [Double])?.first
        XCTAssertEqual(mean ?? 1, 0, accuracy: 0.01)

        model.run("select.deselect")
        model.run("layer.layerStyle.blendingOptions", ["blend": "Screen"])
        model.run("layer.layerStyle.clear", ["layer": model.activeLayer?.id ?? 0])
        XCTAssertEqual(model.activeLayer?.blend, "Normal", "Clear Layer Style resets the blend mode")
    }

    func testSplitHalvesOnOneSpotGoTheWayTheDragGoes() {
        let v: [Double] = [0, 0, 130, 130]
        XCTAssertEqual(BlendIfBar.handles(v, at: 131, split: false, dx: 5), [2, 3], "joined: both")
        XCTAssertNil(BlendIfBar.handles(v, at: 131, split: true, dx: 0))
        XCTAssertEqual(BlendIfBar.handles(v, at: 131, split: true, dx: 5), [3])
        XCTAssertEqual(BlendIfBar.handles(v, at: 131, split: true, dx: -5), [2])
        XCTAssertEqual(BlendIfBar.handles([0, 0, 100, 200], at: 190, split: true, dx: -5), [3], "apart: the nearest")
    }

    func testALiveFilterCopiesToAnotherLayer() throws {
        let model = makeModel(width: 100, height: 100)
        for name in ["A", "B"] {
            model.run("layer.new.layer", ["name": name])
            model.run("edit.fill")
            model.run("filter.convertForSmartFilters")
        }
        model.run("filter.blur.gaussianBlur", ["radius": 2])
        let (a, b) = (try XCTUnwrap(model.row("A")), try XCTUnwrap(model.row("B")))
        let f = try XCTUnwrap(b.smartFilters.first)
        model.run("layer.smartFilter.transfer", ["from": b.id, "to": a.id, "filter": f.index, "copy": true])
        XCTAssertEqual(model.row("A")?.smartFilters.map(\.name), ["Gaussian Blur"])
        XCTAssertEqual(model.row("B")?.smartFilters.map(\.name), ["Gaussian Blur"], "a copy: B keeps its own")
    }
}
