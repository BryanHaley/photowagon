import XCTest

/// Blend If by colour channel: the Blue slider takes out a sky, split for a soft edge; the result
/// as a selection through an Embedded Layer; copying a Live Filter to another layer; Clear Layer
/// Style. See `docs/ios-walkthroughs/blend-if.md` for each step and where it lives in the app.
final class BlendIfSlidersTests: WalkthroughTestCase {
    let sky = [0, 0, 1600, 300], trees = [1150, 950, 1600, 1200]

    func alpha(_ rect: [Int]) -> Double { stats(rect).mean.last ?? -1 }
    func selected(_ rect: [Int]) -> Double { stats(rect, of: "selection").mean.first ?? -1 }

    func testBlendIfSliders() {
        step("Open the photo, unlock it, double-tap the right of the layer: Layer Style") {
            openSample("background")
            app.buttons["layers"].tap()
            show(app.buttons["layer.lock.Background"].firstMatch, "the Background's lock").tap()
            openStyle("Layer 0")
        }

        step("Blend If › Blue, This Layer's white slider to the left: the sky goes, the trees stay") {
            pick(show(app.buttons["style.blendIf.channel"].firstMatch, "the Blend If channel"), "Blue")
            blendIf("thisLayer", handle: 2, to: 130, channel: "blue")
            XCTAssertLessThan(alpha(sky), 0.1, "the sky is transparent")
            XCTAssertGreaterThan(alpha(trees), 0.8, "the trees stay")
            XCTAssertEqual(blendIfRanges("gray")["thisLayer"], [0, 0, 255, 255], "Gray untouched")
        }

        step("Split the white slider and pull the halves apart: a soft edge") {
            flip("style.blendIf.thisLayer.split")
            blendIf("thisLayer", handle: 3, to: 210, channel: "blue")
            let r = blendIfRanges("blue")["thisLayer"] ?? []
            XCTAssert(r.count == 4 && r[2] < 150 && r[3] > 190, "split apart: \(r)")
            XCTAssertGreaterThan(stats(sky).soft, 0.2, "the sky partly shows")
            app.buttons["style.ok"].tap()
        }

        step("Convert to Embedded Layer, Select › Load Selection › Layer Transparency: the trees, not the sky") {
            if !app.buttons["layers.fx"].exists { app.buttons["layers"].tap() }
            layerMenu("Layer 0", "Convert to Embedded Layer")
            waitIdle()
            closeSheet()
            menu("Select", "Load Selection", "Layer Transparency")
            waitIdle()
            XCTAssertLessThan(selected(sky), 0.6)
            XCTAssertGreaterThan(selected(trees), 0.8)
            menu("Select", "Deselect")
        }

        step("Place a picture, Gaussian Blur on it; hold the filter › Copy to Layer › Layer 0") {
            place("bee-cutout")
            menu("Filter", "Blur", "Gaussian Blur…")
            let radius = app.textFields.firstMatch
            XCTAssert(radius.waitForExistence(timeout: 5))
            replace(radius, with: "2")
            app.buttons["settings.run"].tap()
            waitIdle()
            app.buttons["layers"].tap()
            let row = show(app.descendants(matching: .any)["filter.bee-cutout.Gaussian Blur"].firstMatch, "the filter")
            row.press(forDuration: 1.0)
            app.buttons["Copy to Layer"].tap()
            app.buttons["Layer 0"].tap()
            waitIdle()
            XCTAssertEqual((layer(named: "Layer 0")?["smartFilters"] as? [Any])?.count, 1, "Layer 0 has the blur too")
            XCTAssertEqual((layer(named: "bee-cutout")?["smartFilters"] as? [Any])?.count, 1, "a copy")
        }

        step("Blend › Screen, then hold the layer › Clear Layer Style: Normal again") {
            pick(app.buttons["layers.blend"], "Screen")
            waitIdle()
            XCTAssertEqual(layer(named: "bee-cutout")?["blend"] as? String, "Screen")
            layerMenu("bee-cutout", "Clear Layer Style")
            waitIdle()
            XCTAssertEqual(layer(named: "bee-cutout")?["blend"] as? String, "Normal")
        }
    }
}
