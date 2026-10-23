import XCTest

/// Filters: Fluid Warp painted on the canvas and changed later as a live filter, a live filter's
/// Blending Options, Last Filter, Develop's presets and Preview, and Stamp Visible. See
/// `docs/ios-walkthroughs/filters.md` for each step and where it lives in the app.
final class FiltersTests: WalkthroughTestCase {
    /// Where the hair meets the sky.
    let edge = [470, 930, 540, 990]

    func red(_ rect: [Int]) -> Double { stats(rect).mean.first ?? -1 }
    var filters: [[String: Any]] { layer(named: topName)?["smartFilters"] as? [[String: Any]] ?? [] }

    func testFilters() {
        var original = 0.0
        step("Open the portrait, Layer via Copy, Convert for Live Filters, Filter › Fluid Warp: drag on the canvas, Commit") {
            openSample("red-hair")
            menu("Layer", "New", "Layer via Copy")
            menu("Filter", "Convert for Live Filters")
            original = red(edge)
            menu("Filter", "Fluid Warp…")
            XCTAssert(app.buttons["Commit"].waitForExistence(timeout: 5), "Fluid Warp on the canvas")
            drag(doc: (380, 960), to: (560, 960))
            waitIdle()
            XCTAssertEqual(red(edge), original, accuracy: 0.005, "a preview until Commit")
            tapChip(app.buttons["Commit"])
            waitIdle()
            noErrorToast()
            XCTAssertEqual(filters.first?["command"] as? String, "filter.liquify", "a live filter")
            XCTAssertLessThan(red(edge), original - 0.03, "the sky pushed into the hair")
        }

        step("Double-tap the Fluid Warp filter: back on the canvas; … › Amount 0%, Commit: the original again") {
            app.buttons["layers"].tap()
            let row = show(app.descendants(matching: .any)["filter.\(topName).Fluid Warp"].firstMatch, "the filter")
            row.doubleTap()
            if !app.buttons["Commit"].waitForExistence(timeout: 4) { row.doubleTap() }
            XCTAssert(app.buttons["Commit"].waitForExistence(timeout: 5), "Fluid Warp again")
            pick(app.buttons["warp.more"], "Amount 0%")
            tapChip(app.buttons["Commit"])
            waitIdle()
            XCTAssertEqual(red(edge), original, accuracy: 0.01)
            XCTAssertEqual(filters.count, 1, "the same filter, changed")
        }

        step("Gaussian Blur 80 px, then Filter › Last Filter: a second blur") {
            menu("Filter", "Blur", "Gaussian Blur…")
            replace(app.textFields["settings.radius"], with: "80")
            app.buttons["settings.run"].tap()
            waitIdle()
            menu("Filter", "Last Filter")
            waitIdle()
            XCTAssertEqual(filters.filter { $0["command"] as? String == "filter.blur.gaussianBlur" }.count, 2)
        }

        step("Hold the blur › Blending Options: Screen") {
            app.buttons["layers"].tap()
            let row = show(app.descendants(matching: .any)["filter.\(topName).Gaussian Blur"].firstMatch, "the blur")
            row.press(forDuration: 1.0)
            app.buttons["Blending Options…"].tap()
            pick(app.buttons["filterBlend.mode"], "Screen")
            waitIdle()
            XCTAssert(filters.contains { $0["blend"] as? String == "Screen" }, "\(filters.map { $0["blend"] ?? "" })")
            closeSheet()
            closeSheet()
        }

        step("Filter › Develop: the Punchy preset, Save Preset as mine, Preview off and on, OK") {
            menu("Filter", "Develop…")
            XCTAssert(app.buttons["raw.ok"].waitForExistence(timeout: 5))
            app.buttons["raw.preset.Punchy"].tap()
            waitIdle()
            app.buttons["raw.savePreset"].tap()
            let alert = app.alerts["Save Preset"]
            XCTAssert(alert.waitForExistence(timeout: 5))
            alert.textFields.firstMatch.typeText("mine")
            alert.buttons["Save"].tap()
            XCTAssert(app.buttons["raw.preset.mine"].waitForExistence(timeout: 5), "the saved preset")
            app.buttons["raw.preview"].tap()
            XCTAssertEqual(app.buttons["raw.preview"].value as? String, "off")
            app.buttons["raw.preview"].tap()
            app.buttons["raw.ok"].tap()
            waitIdle()
            let raw = filters.first { $0["command"] as? String == "filter.cameraRaw" }
            XCTAssertEqual((raw?["params"] as? [String: Any])?["contrast"] as? Double, 25, "Punchy's contrast")
        }

        step("Hold the layer › Stamp Visible: a new layer with everything merged") {
            let before = layerTotal
            if !app.buttons["layers.fx"].exists { app.buttons["layers"].tap() }
            layerMenu(topName, "Stamp Visible")
            waitIdle()
            XCTAssertEqual(layerTotal, before + 1)
        }
    }
}
