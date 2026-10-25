import XCTest

/// Fill against Opacity in the special blend modes, Layer Style's Blending Options (Blend If,
/// Transparency Shapes Layer, Fill Opacity), a gradient fill's settings and layer effects, through
/// the app's own UI. See `docs/ios-walkthroughs/opacity-fill.md` for each step and what else covers it.
/// Shared helpers; each part is its own class below, so parallel runs can
/// spread the parts across simulators (Xcode spreads classes, not methods).
class OpacityFillTests: WalkthroughTestCase {
    // MARK: - Helpers

    /// The middle of the text, and below and right of it, where its shadow falls.
    var textRect: [Int] {
        let b = bounds("CONCRETE")
        return b.count == 4 ? [Int(b[0] + b[2] * 0.1), Int(b[1] + b[3] * 0.3), Int(b[0] + b[2] * 0.9), Int(b[1] + b[3] * 0.7)] : []
    }

    var shadowRect: [Int] {
        let b = bounds("CONCRETE")
        return b.count == 4 ? [Int(b[0] + b[2] * 0.1), Int(b[1] + b[3]), Int(b[0] + b[2] * 0.9), Int(b[1] + b[3] + 30)] : []
    }

    /// The active layer's style, as Layer Style reads it.
    var effectKinds: [String] { (probe("layer.layerStyle.get")["effects"] as? [[String: Any]] ?? []).compactMap { $0["kind"] as? String } }

    func effect(_ i: Int) -> [String: Any] {
        let list = probe("layer.layerStyle.get")["effects"] as? [[String: Any]] ?? []
        return list.indices.contains(i) ? list[i]["params"] as? [String: Any] ?? [:] : [:]
    }

    /// A Layer Style value, from the field beside its slider.
    func styleValue(_ key: String) -> Double {
        Double(app.textFields["style.\(key).value"].firstMatch.value as? String ?? "") ?? .nan
    }

    /// Type a Layer Style value in the field beside its slider.
    func setStyle(_ key: String, _ value: Double) {
        let field = show(app.textFields["style.\(key).value"].firstMatch, "style \(key)")
        replace(field, with: "\(Int(value))\n")
        XCTAssertEqual(styleValue(key), value, "\(key)")
    }

    /// Set a percentage slider (Layers' Opacity or Fill) to `percent`: the slider, then dragging
    /// its name for the last few percent (3 points a percent).
    func slide(_ id: String, to percent: Int) {
        let s = app.sliders[id].firstMatch
        XCTAssert(s.waitForExistence(timeout: 5), id)
        let value = { (s.value as? String).flatMap { Int($0.dropLast()) } ?? -1 }
        s.slide(to: Double(percent) / 100)
        let label = app.staticTexts["\(id).label"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        for _ in 0..<4 where value() != percent {
            let dx = Double(percent - value()) * 3
            let from = label.withOffset(CGVector(dx: dx < 0 ? 20 : -20, dy: 0))
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: dx, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertEqual(value(), percent, "\(id)")
    }

    /// The photo alone in `rect`.
    func photo(_ rect: [Int]) -> [Double] { stats(rect, of: "pixels", layer: "Background").mean }
}
// MARK: - Fill in a special blend mode, and Blend If

final class FillAndBlendIfTests: OpacityFillTests {
    func testFillAndBlendIf() {
        let sand = [0, 720, 1400, 875]
        var original: [Double] = []

        step("Open the beach; Solid Color, a warm orange") {
            app.buttons["home.open"].tap()
            pickFile("beach")
            waitForCanvas()
            original = stats(sand).mean
            app.buttons["layers"].tap()
            addAdjustment("Solid Color")
            XCTAssert(app.navigationBars["Color Fill"].waitForExistence(timeout: 5))
            app.buttons["fill.color"].tap()
            chooseColor(containing: "orange")
            app.navigationBars["Color Fill"].buttons["sheet.done"].tap()
            let c = stats(sand).mean
            XCTAssert(c[0] > c[2] + 0.3, "orange: \(c)")
        }

        step("Hard Mix: Fill isn't Opacity; Fill 20% gives a colour grade") {
            pick(app.buttons["layers.blend"], "Hard Mix")
            let full = stats(sand)
            slide("layers.opacity", to: 50)
            let opacity = stats(sand).mean
            slide("layers.opacity", to: 100)
            slide("layers.fill", to: 50)
            let fill = stats(sand).mean
            let gap = (0..<3).map { abs(fill[$0] - opacity[$0]) }.max() ?? 0
            XCTAssertGreaterThan(gap, 0.04, "they differ: \(opacity) vs \(fill)")
            XCTAssertGreaterThan(full.stddev[1], 0.2, "Hard Mix at 100% posterizes: \(full.stddev)")
            slide("layers.fill", to: 20)
            let graded = stats(sand)
            XCTAssertLessThan(graded.stddev[1], 0.2, "no longer posterized: \(graded.stddev)")
            XCTAssertGreaterThan(graded.mean[0] - graded.mean[2], original[0] - original[2] + 0.03, "warmer: \(original) → \(graded.mean)")
            closeSheet()
        }

        step("Double-tap the right of the layer: Layer Style › Blending Options") {
            openStyle("Color Fill 1")
            XCTAssertEqual(styleValue("fillOpacity"), 20, "the page shows the layer's fill")
        }

        step("Blend If › Underlying Layer: black slider right, then split it and move the white one") {
            // The sand is at most about 155 of 255 bright, the sky about 180.
            blendIf("underlying", handle: 0, to: 165)
            var r = blendIfRanges["underlying"] ?? []
            XCTAssert(r.count == 4 && r[0] > 155 && r[0] == r[1], "joined: \(r)")
            let after = stats(sand).mean
            for i in 0..<3 { XCTAssertEqual(after[i], original[i], accuracy: 0.015, "the sand is the photo again: \(original) → \(after)") }
            let skyRect = [0, 0, 1400, 150]
            let sky = stats(skyRect).mean
            XCTAssertGreaterThan(sky[0] - sky[2], photo(skyRect)[0] - photo(skyRect)[2] + 0.05, "the sky keeps the grade")

            flip("style.blendIf.underlying.split")
            blendIf("underlying", handle: 0, to: 90)
            let split = stats(skyRect).mean
            blendIf("underlying", handle: 2, to: 175)
            r = blendIfRanges["underlying"] ?? []
            XCTAssert(r.count == 4 && r[0] < 110 && r[1] > 150 && r[2] < 190 && r[3] > 240, "split apart: \(r)")
            let faded = stats(skyRect).mean
            XCTAssertLessThan(abs(faded[0] - photo(skyRect)[0]), abs(split[0] - photo(skyRect)[0]), "the sky less orange: \(split) → \(faded)")
            app.buttons["style.ok"].tap()
        }
    }
}

// MARK: - Transparency Shapes Layer, and a gradient fill's settings

final class FakeSunTests: OpacityFillTests {
    func testFakeSun() {
        let (sx, sy) = (450.0, 450.0)
        let around = [Int(sx) - 150, Int(sy) - 150, Int(sx) + 150, Int(sy) + 150]

        step("Open the dog photo; a new layer, the Soft Round brush, bigger, a bright yellow; dab in the middle") {
            app.buttons["home.open"].tap()
            pickFile("subject")
            waitForCanvas()
            newLayer()
            tool(group: "Brush", pick: "Brush")
            brushTip("General", "Soft Round")
            // About 350 px.
            option("Size", 0.85)
            pickColor(containing: "yellow")
            at(sx, sy).tap()
            waitIdle()
            let dab = stats([Int(sx) - 20, Int(sy) - 20, Int(sx) + 20, Int(sy) + 20], of: "pixels", layer: "Layer 1").mean
            XCTAssertGreaterThan(dab[3], 0.5, "painted: \(dab)")
            XCTAssertGreaterThan(stats(around, of: "pixels", layer: "Layer 1").soft, 0.1, "with a soft edge")
        }

        step("Color Dodge, then Layer Style › Transparency Shapes Layer off: what's under the sun shapes it") {
            app.buttons["layers"].tap()
            pick(app.buttons["layers.blend"], "Color Dodge")
            XCTAssertEqual(layer(named: "Layer 1")?["blend"] as? String, "Color Dodge")
            // The dab's fading edge, where its transparency now acts as Fill.
            let edge = [Int(sx) + 110, Int(sy) - 40, Int(sx) + 190, Int(sy) + 40]
            let before = stats(edge).mean
            openStyle("Layer 1")
            flip("style.transparencyShapesLayer")
            app.buttons["style.ok"].tap()
            waitIdle()
            XCTAssertEqual((layer(named: "Layer 1")?["advancedBlending"] as? [String: Any])?["transparencyShapes"] as? Bool, false, "\(layer(named: "Layer 1") ?? [:])")
            XCTAssertGreaterThan(stats(edge).mean[0], before[0] + 0.015, "a brighter, blinding sun: \(before) → \(stats(edge).mean)")
        }

        step("A glare: Gradient fill, yellow to red, fading to transparent; Radial, a bigger Scale, Reverse") {
            app.buttons["layers"].tap()
            addAdjustment("Gradient")
            XCTAssert(app.navigationBars["Gradient Fill"].waitForExistence(timeout: 5))
            show(app.buttons["fill.stop.0"].firstMatch, "the left colour stop").tap()
            chooseColor(containing: "yellow")
            show(app.buttons["fill.stop.1"].firstMatch, "the right colour stop").tap()
            chooseColor(containing: "red")
            replace(show(app.descendants(matching: .any)["fill.opacity.1.value"].firstMatch, "the right opacity stop"), with: "0\n")
            replace(show(app.descendants(matching: .any)["fill.opacityAt.0.value"].firstMatch, "the left opacity stop's location"), with: "26\n")
            pick(show(app.buttons["fill.style"], "style"), "Radial")
            show(app.sliders["fill.scale"], "scale").slide(to: 0.9)
            flip("fill.reverse")
            let g = probe("gradient.fill.get")
            let t = g["transparency"] as? [[Double]] ?? []
            XCTAssertEqual(t.last?.last ?? 100, 0, accuracy: 3, "transparent at the right: \(t)")
            XCTAssertEqual(t.first?.first ?? 0, 0.26, accuracy: 0.01, "the left stop at 26%: \(t)")
            XCTAssertEqual((g["stops"] as? [[Any]] ?? []).count, 2)
            XCTAssertEqual(g["style"] as? String, "radial")
            XCTAssertGreaterThan((g["scale"] as? Double) ?? 0, 120)
            XCTAssertEqual(g["reverse"] as? Bool, true)
        }

        step("While its settings are open, drag in the image to move the gradient") {
            let before = probe("gradient.fill.get")["offset"] as? [Double] ?? []
            show(app.buttons["fill.move"], "Move It in the Image").tap()
            XCTAssert(app.navigationBars["Gradient Fill"].waitForExistence(timeout: 8), "Properties, beside the canvas")
            Thread.sleep(forTimeInterval: 0.5)
            drag(doc: (300, 150), to: (450, 250))
            let after = probe("gradient.fill.get")["offset"] as? [Double] ?? []
            XCTAssert(before.count == 2 && after.count == 2 && (abs(after[0] - before[0]) > 5 || abs(after[1] - before[1]) > 5), "moved: \(before) → \(after)")
            closeSheet()
        }
    }
}

// MARK: - Layer effects keep their look when Fill goes down

final class LayerStylesTests: OpacityFillTests {
    func testLayerStyles() {
        step("Open the concrete wall; type CONCRETE in orange, big") {
            app.buttons["home.open"].tap()
            pickFile("concrete")
            waitForCanvas()
            let (w, h) = docSize
            pickColor(containing: "orange")
            tool(group: "Horizontal Type", pick: "Horizontal Type")
            at(w * 0.3, h * 0.4).tap()
            replace(app.textFields["prompt.field"], with: "CONCRETE")
            app.buttons["prompt.ok"].firstMatch.tap()
            replace(app.textFields["type.size"], with: "260")
            tool(group: "Move", pick: "Move")
            XCTAssertEqual(layer(named: "CONCRETE")?["kind"] as? String, "Type")
            let t = stats(textRect).mean
            XCTAssertGreaterThan(t[0], t[2] + 0.15, "orange text: \(t)")
        }

        step("Layers › fx › Drop Shadow: farther, softer, another colour") {
            let plain = stats(shadowRect).mean
            app.buttons["layers"].tap()
            pick(menu: "layers.fx", "Drop Shadow…")
            XCTAssert(app.navigationBars["Layer Style"].waitForExistence(timeout: 8))
            XCTAssertEqual(effectKinds, ["dropShadow"])
            expandSheet()
            setStyle("distance", 40)
            setStyle("size", 12)
            XCTAssertLessThan(lum(stats(shadowRect).mean), lum(plain) - 0.03, "a shadow below and to the right")
            show(app.buttons["style.color"], "colour").tap()
            chooseColor(containing: "blue")
            XCTAssertNotEqual(effect(0)["color"] as? String, "#000000")
        }

        step("Add another drop shadow, then delete one") {
            show(app.buttons["style.duplicate"], "Add Another").tap()
            XCTAssertEqual(effectKinds, ["dropShadow", "dropShadow"])
            show(app.buttons["style.delete"], "Delete").tap()
            XCTAssertEqual(effectKinds, ["dropShadow"])
        }

        step("Blending Options › Fill Opacity 0%: the orange goes, the shadow stays") {
            let shadow = lum(stats(shadowRect).mean)
            app.buttons["style.page.Blending Options"].firstMatch.tap()
            setStyle("fillOpacity", 0)
            let t = stats(textRect).mean
            XCTAssertLessThan(t[0] - t[2], 0.08, "no orange left: \(t)")
            XCTAssertEqual(lum(stats(shadowRect).mean), shadow, accuracy: 0.03, "the shadow is unchanged")
        }

        step("Add Effect › Bevel & Emboss: depth and size") {
            let flat = stats(textRect).stddev
            pick(menu: "style.add", "Bevel & Emboss")
            XCTAssertEqual(Set(effectKinds), ["dropShadow", "bevelEmboss"])
            setStyle("depth", 300)
            setStyle("size", 10)
            XCTAssertGreaterThan(stats(textRect).stddev[0], flat[0] + 0.01, "edges lit and shaded: \(flat) → \(stats(textRect).stddev)")
            app.buttons["style.ok"].tap()
        }
    }
}
