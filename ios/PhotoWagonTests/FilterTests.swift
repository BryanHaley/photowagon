import XCTest
@testable import PhotoWagon

/// Fluid Warp on the canvas, Develop presets and a live filter's blending (FiltersTests' model side).
@MainActor
final class FilterTests: XCTestCase {
    /// Black stripes on a white layer, and a canvas over it.
    private func stripes() -> (EditorModel, CanvasUIView) {
        let model = makeModel(width: 200, height: 200)
        model.run("layer.new.layer", ["name": "stripes"])
        model.setForeground(.white)
        model.run("edit.fill")
        model.setForeground(.black)
        for x in stride(from: 20, to: 200, by: 40) {
            model.run("select.rect", ["x": x, "y": 0, "width": 20, "height": 200])
            model.run("edit.fill")
        }
        model.run("select.deselect")
        let canvas = CanvasUIView(model: model)
        canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        return (model, canvas)
    }

    private func row(_ model: EditorModel) -> [Double] { (0..<200).map { model.pixel($0, 100).first ?? -1 } }

    func testFluidWarpPaintsOnTheCanvasAndCommits() {
        let (model, canvas) = stripes()
        let before = row(model)
        model.perform(CommandInfo(id: "filter.liquify", label: "Fluid Warp…", menu: "Filter", enabled: true, reason: nil, params: "{}"))
        XCTAssertNotNil(model.fluidWarp)
        XCTAssert(model.hasPending)
        model.fluidWarp?.pressure = 100
        canvas.drag(pt(60, 100), pt(120, 100), steps: 8)
        XCTAssertEqual(model.fluidWarp?.strokes.count, 1, "a drag is a stroke, not a move")
        XCTAssertEqual(row(model), before, "only a preview until Commit")
        model.commitPending()
        idle(model)
        XCTAssertNil(model.fluidWarp)
        XCTAssertNotEqual(row(model), before, "the stripes moved")
        XCTAssertEqual(model.historyNames.last, "Fluid Warp")
    }

    func testAFluidWarpLiveFilterReopensOnTheCanvas() throws {
        let (model, canvas) = stripes()
        let before = row(model)
        model.run("filter.convertForSmartFilters")
        model.beginFluidWarp()
        model.fluidWarp?.pressure = 100
        canvas.drag(pt(60, 100), pt(120, 100), steps: 8)
        model.commitPending()
        idle(model)
        let warped = row(model)
        let f = try XCTUnwrap(model.row("stripes")?.smartFilters.first)
        XCTAssertEqual(f.command, "filter.liquify")

        model.editFluidWarp(layer: try XCTUnwrap(model.row("stripes")?.id), filter: f)
        XCTAssertEqual(model.fluidWarp?.strokes.count, 1, "the old strokes")
        XCTAssertEqual(model.row("stripes")?.smartFilters.first?.visible, false, "hidden while it's redone")
        model.cancelPending()
        XCTAssertEqual(model.row("stripes")?.smartFilters.first?.visible, true)
        XCTAssertEqual(row(model), warped, "Cancel changes nothing")

        model.editFluidWarp(layer: try XCTUnwrap(model.row("stripes")?.id), filter: f)
        model.fluidWarp?.amount = 0
        model.commitPending()
        idle(model)
        XCTAssertEqual(model.row("stripes")?.smartFilters.count, 1)
        XCTAssertEqual(model.row("stripes")?.smartFilters.first?.visible, true)
        let back = row(model)
        XCTAssertLessThan(zip(back, before).map { abs($0 - $1) }.max() ?? 1, 0.02, "Amount 0%: the original")
    }

    func testDevelopPresetsSaveByName() {
        let model = makeModel()
        model.saveDevelopPreset(" Mine ", ["exposure": 0.5, "contrast": 0])
        model.saveDevelopPreset("Mine", ["exposure": 1])
        model.saveDevelopPreset("  ", ["exposure": 1])
        XCTAssertEqual(model.developPresets.map(\.name), ["Mine"], "the same name replaces; no blank names")
        XCTAssertEqual(model.developPresets.first?.values, ["exposure": 1])
    }

    func testALiveFilterTakesABlendModeAndOpacity() throws {
        let (model, _) = stripes()
        model.run("filter.convertForSmartFilters")
        model.run("filter.blur.gaussianBlur", ["radius": 4])
        let f = try XCTUnwrap(model.row("stripes")?.smartFilters.first)
        model.run("layer.smartFilter.blendingOptions", ["layer": try XCTUnwrap(model.row("stripes")?.id), "index": f.index, "blend": "Screen", "opacity": 0.5])
        let g = try XCTUnwrap(model.row("stripes")?.smartFilters.first)
        XCTAssertEqual(g.blend, "Screen")
        XCTAssertEqual(g.opacity, 0.5, accuracy: 0.001)
    }
}
