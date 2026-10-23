import XCTest

/// Blend modes: the ▲▼ step buttons, Pass Through and Normal groups, the adjustment Properties
/// buttons (clip, reset, visibility), Screen with Colorize, Flip Horizontal and Snap Rotation,
/// and Color mode for a colour cast. The blend maths is in compose and `BlendTests`.
/// See `docs/ios-walkthroughs/blend-modes.md` for each step and where it lives in the app.
class BlendModesTests: WalkthroughTestCase {
    /// The photo alone in `rect`.
    func photo(_ rect: [Int], _ layer: String = "Background") -> [Double] { stats(rect, of: "pixels", layer: layer).mean }

    func blend(_ name: String) -> String { layer(named: name)?["blend"] as? String ?? "" }

    func spread(_ a: [Double], _ b: [Double]) -> Double { zip(a.prefix(3), b.prefix(3)).map { abs($0 - $1) }.max() ?? 0 }

    /// The open Layers panel's Blend menu › `mode`.
    func setBlend(_ mode: String) {
        pick(app.buttons["layers.blend"], mode)
        waitIdle()
    }

    func stepBlend(_ id: String, times: Int = 1) {
        for _ in 0..<times {
            app.buttons["layers.blend.\(id)"].tap()
            waitIdle()
        }
    }

    /// Done on the adjustment's Properties (over Layers).
    func closeProperties() {
        let done = app.navigationBars.element(boundBy: max(app.navigationBars.count - 1, 0)).buttons["sheet.done"]
        if done.exists { done.tap() } else { closeSheet() }
        waitIdle()
    }

    func hueSat(_ name: String) -> [String: Any] {
        (layer(named: name)?["adjustment"] as? [String: Any])?["params"] as? [String: Any] ?? [:]
    }
}

// MARK: - Step buttons, groups, Properties buttons, Screen, Flip and Snap Rotation

final class BlendLayersTests: BlendModesTests {
    func testBlendLayers() {
        let corner = [20, 20, 200, 200]
        step("Open the photo, place the bee; the arrows by Blend go through the modes one at a time") {
            openSample("background")
            place("bee-cutout")
            app.buttons["layers"].tap()
            var seen: [String] = []
            for _ in 0..<4 {
                stepBlend("next")
                seen.append(blend("bee-cutout"))
            }
            XCTAssertEqual(seen, ["Dissolve", "Darken", "Multiply", "Color Burn"])
            stepBlend("previous", times: 4)
            XCTAssertEqual(blend("bee-cutout"), "Normal")
        }

        var bee: [Int] = []
        step("◑ › Hue/Saturation, Colorize: the background changes too; the eye under Properties turns it off and on") {
            let b = bounds("bee-cutout")
            bee = [Int(b[0] + b[2] * 0.45), Int(b[1] + b[3] * 0.55), Int(b[0] + b[2] * 0.55), Int(b[1] + b[3] * 0.65)]
            addAdjustment("Hue/Saturation")
            // Below the half-height sheet's edge: pull it up.
            expandSheet()
            flip("hs.colorize")
            waitIdle()
            XCTAssertGreaterThan(spread(stats(corner).mean, photo(corner)), 0.02, "the background is tinted too")
            app.buttons["properties.visible"].tap()
            waitIdle()
            XCTAssertEqual(layer(named: "Hue/Saturation 1")?["visible"] as? Bool, false)
            XCTAssertLessThan(spread(stats(corner).mean, photo(corner)), 0.01, "hidden: the photo as it was")
            app.buttons["properties.visible"].tap()
            waitIdle()
            XCTAssertEqual(layer(named: "Hue/Saturation 1")?["visible"] as? Bool, true)
            closeProperties()
        }

        step("Select the Hue/Saturation and the bee, Group: a new group passes through, the background stays tinted") {
            app.buttons["layers.select"].tap()
            for n in ["Hue/Saturation 1", "bee-cutout"] where layer(named: n)?["selected"] as? Bool != true { tapLayer(n) }
            app.buttons["layers.groupSelected"].tap()
            waitIdle()
            app.buttons["layers.select"].tap()
            XCTAssertEqual(blend("Group 1"), "Pass Through")
            XCTAssertGreaterThan(spread(stats(corner).mean, photo(corner)), 0.02)
        }

        step("The group's Blend › Normal: the Hue/Saturation stays inside, on the bee only") {
            select("Group 1")
            setBlend("Normal")
            XCTAssertEqual(blend("Group 1"), "Normal")
            XCTAssertLessThan(spread(stats(corner).mean, photo(corner)), 0.01, "the background as it was")
            XCTAssertGreaterThan(spread(stats(bee).mean, photo(bee, "bee-cutout")), 0.02, "the bee is still tinted")
            closeSheet()
        }

        // Right of the bee.
        let top = [1440, 120, 1580, 200]
        let low = [1440, 840, 1580, 900]
        step("Place the smoke on black over the photo, Blend › Screen: the black disappears") {
            let before = stats(top).mean
            app.buttons["layers"].tap()
            select("Background")
            closeSheet()
            place("smoke")
            app.buttons["layers"].tap()
            setBlend("Screen")
            XCTAssertLessThan(spread(stats(top).mean, before), 0.02, "black hides")
        }

        step("◑ › Hue/Saturation, the clip button, Colorize: coloured smoke; Reset under Properties: grey again") {
            let grey = stats(low).mean
            addAdjustment("Hue/Saturation")
            app.buttons["properties.clip"].tap()
            waitIdle()
            XCTAssertEqual(layer(named: "Hue/Saturation 2")?["clipped"] as? Bool, true)
            expandSheet()
            flip("hs.colorize")
            waitIdle()
            XCTAssertEqual(hueSat("Hue/Saturation 2")["colorize"] as? Bool, true)
            XCTAssertGreaterThan(spread(stats(low).mean, grey), 0.01, "the smoke takes a colour")
            app.buttons["properties.reset"].tap()
            waitIdle()
            XCTAssertEqual(hueSat("Hue/Saturation 2")["colorize"] as? Bool, false)
            XCTAssertLessThan(spread(stats(low).mean, grey), 0.01, "grey again")
            closeProperties()
        }

        var b: [Double] = []
        step("Free Transform › Flip Horizontal: the smoke mirrored") {
            select("smoke")
            closeSheet()
            b = bounds("smoke")
            let left = [Int(b[0]), Int(b[1]), Int(b[0] + b[2] * 0.3), Int(b[1] + b[3])]
            let right = [Int(b[0] + b[2] * 0.7), Int(b[1]), Int(b[0] + b[2]), Int(b[1] + b[3])]
            let was = stats(right, of: "pixels", layer: "smoke").mean
            menu("Edit", "Free Transform")
            XCTAssert(app.buttons["Commit"].waitForExistence(timeout: 5))
            tapChip(app.buttons["Flip Horizontal"])
            tapChip(app.buttons["Commit"])
            waitIdle()
            XCTAssertLessThan(spread(stats(left, of: "pixels", layer: "smoke").mean, was), 0.01, "the right side is on the left now")
        }

        step("Free Transform › Snap Rotation to 15°, a quarter turn: upright") {
            menu("Edit", "Free Transform")
            XCTAssert(app.buttons["Commit"].waitForExistence(timeout: 5))
            tapChip(app.buttons["Snap Rotation to 15°"])
            // From above the box, clear of its handles, a quarter turn round its centre.
            let (cx, cy) = (b[0] + b[2] / 2, b[1] + b[3] / 2)
            let start = (cx + 400, max(b[1] - 95, 5))
            let a = atan2(start.1 - cy, start.0 - cx) + .pi / 2
            drag(doc: start, to: (cx + 500 * cos(a), cy + 500 * sin(a)))
            tapChip(app.buttons["Commit"])
            waitIdle()
            let r = bounds("smoke")
            XCTAssertGreaterThan(r[3], r[2], "upright now: \(r)")
        }
    }
}

// MARK: - Color: a new colour, the same light

final class ColorModeTests: BlendModesTests {
    func testColorMode() {
        var (w, h) = (1377.0, 1600.0)
        var patch: [Int] { [Int(w * 0.56), Int(h * 0.61), Int(w * 0.61), Int(h * 0.69)] }
        step("Open the photo with a green cast; ◑ › Hue/Saturation, Edit › Greens, Hue: the green patch turns") {
            openSample("cast")
            (w, h) = docSize
            let before = stats(patch).mean
            app.buttons["layers"].tap()
            addAdjustment("Hue/Saturation")
            expandSheet()
            pick(app.buttons["hs.part"], "Greens")
            app.sliders["hs.hue"].firstMatch.adjust(toNormalizedSliderPosition: 0.2)
            waitIdle()
            closeProperties()
            let after = stats(patch).mean
            XCTAssertLessThan(after[1] - after[0], before[1] - before[0] - 0.03, "less green: \(before) → \(after)")
            app.buttons["layers.delete"].tap()
            waitIdle()
            XCTAssertNil(layer(named: "Hue/Saturation 1"))
            closeSheet()
        }

        step("Eyedropper options: Sample Size 3 by 3, Current & Below") {
            tool(group: "Eyedropper", pick: "Eyedropper")
            pick(app.buttons["option.sampleSize"], "3 by 3 Average")
            pick(app.buttons["option.sampleLayers"], "Current & Below")
            XCTAssert(app.buttons["option.sampleLayers"].label.contains("Current & Below"))
        }

        step("A new layer in Color mode; Brush, touch and hold on good skin to take its colour; paint the green patch") {
            app.buttons["layers"].tap()
            app.buttons["layers.new"].tap()
            waitIdle()
            // Near the end of a long menu: from Normal, two steps back (Luminosity, Color).
            stepBlend("previous", times: 2)
            XCTAssertEqual(blend(activeLayerName ?? ""), "Color")
            closeSheet()
            brush("Soft Round", size: 0.4)
            // The new layer is empty: the colour comes from below (Current & Below).
            at(w * 0.6, h * 0.82).press(forDuration: 1.0)
            waitIdle()
            let skin = colors.fg
            XCTAssertGreaterThan(skin[0], skin[1] + 0.05, "a skin colour in front: \(skin)")
            let before = stats(patch).mean
            for x in stride(from: w * 0.55, through: w * 0.62, by: 25) { drag(doc: (x, h * 0.58), to: (x, h * 0.72)) }
            waitIdle()
            let after = stats(patch).mean
            XCTAssertLessThan(after[1] - after[0], before[1] - before[0] - 0.05, "less green: \(before) → \(after)")
            XCTAssertEqual(lum(after), lum(before), accuracy: 0.15, "the light kept")
        }
    }
}
