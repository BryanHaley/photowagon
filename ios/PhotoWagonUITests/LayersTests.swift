import XCTest

/// Layers: the Layers panel (fill layers, the layer menu, selecting several, merge, group, the
/// Background's rules, blend and opacity, the trash, the New Layer dialog), shape layers, the
/// Crop tool past the image, transparency and export, embedded layers and live filters, and the
/// targeted Hue/Saturation drag, through the app's own UI.
/// Shared helpers; each part is its own class below, so parallel runs can
/// spread the parts across simulators (Xcode spreads classes, not methods).
class LayersTests: WalkthroughTestCase {
    /// In the open Layers panel: Select Layers, then tap each of `names`. Leaves selecting on.
    func selectLayers(_ names: [String]) {
        tapLayer(names[0])
        app.buttons["layers.select"].tap()
        for name in names.dropFirst() { tapLayer(name) }
        // A tap the busy app missed: add whatever isn't selected yet. A row's single tap lands
        // after the double-tap wait (double-tap renames): let it, before looking.
        for _ in 0..<2 {
            Thread.sleep(forTimeInterval: 1)
            let selected = Set((inspect["selectedLayers"] as? [Int]) ?? [])
            for name in names where !selected.contains(layerID(name)) { tapLayer(name) }
        }
        let picked = (inspect["selectedLayers"] as? [Int]) ?? []
        XCTAssertEqual(picked.count, names.count, "selected: \(allLayers.filter { picked.contains($0["id"] as? Int ?? -1) }.map { $0["name"] ?? "" })")
    }
}

// MARK: - The Layers panel

final class LayersPanelTests: LayersTests {
    func testLayersPanel() {
        step("Open the design: a gradient, text, a subject and more text") {
            app.buttons["home.open"].tap()
            pickFile("design")
            waitForCanvas()
            XCTAssertEqual(allLayers.map { $0["name"] as? String ?? "" }, ["Game", "subject", "The Good", "Gradient Background", "Background"])
        }

        step("Double-tap the gradient's thumbnail: pick another gradient") {
            let before = stats([0, 0, 1080, 200]).mean
            app.buttons["layers"].tap()
            app.descendants(matching: .any)["layer.thumb.Gradient Background"].firstMatch.doubleTap()
            XCTAssert(app.navigationBars["Gradient Fill"].waitForExistence(timeout: 5))
            let preset = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'fill.preset.Blue'")).firstMatch
            for _ in 0..<5 where !preset.isHittable { app.swipeUp() }
            preset.tap()
            app.navigationBars["Gradient Fill"].buttons["sheet.done"].tap()
            let after = stats([0, 0, 1080, 200]).mean
            XCTAssertGreaterThan(after[2] - after[0], before[2] - before[0] + 0.3, "blue now: \(before) → \(after)")
        }

        step("Hold a layer › Show This Layer Only: that layer alone; again: everything back") {
            layerMenu("subject", "Show This Layer Only")
            XCTAssertEqual(allLayers.filter { $0["visible"] as? Bool == true }.map { $0["name"] as? String ?? "" }, ["subject"])
            layerMenu("subject", "Show This Layer Only")
            XCTAssert(allLayers.allSatisfy { $0["visible"] as? Bool == true })
        }

        step("Select the top layer and the ones down to the gradient: Merge") {
            selectLayers(["Game", "subject", "The Good", "Gradient Background"])
            app.buttons["layers.merge"].tap()
            XCTAssertEqual(layerTotal, 2, "four became one, over the Background")
            XCTAssertEqual(layers.first?["kind"] as? String, "Pixel", "burnt into pixels: the text can't change now")
            app.buttons["layers.select"].tap()
            closeSheet()
        }

        // Each step's screenshot shows its result: the undo comes at the start of the next.
        step("Select the two text layers: Group") {
            app.buttons["undo"].tap()
            XCTAssertEqual(layerTotal, 5)
            app.buttons["layers"].tap()
            selectLayers(["Game", "The Good"])
            show(app.buttons["layers.groupSelected"], "the Group button").tap()
            app.buttons["layers.select"].tap()
            let group = allLayers.first { $0["kind"] as? String == "Group" }
            XCTAssertEqual((group?["children"] as? [Any])?.count, 2, "the text in one group")
            closeSheet()
        }

        step("The Background: renaming offers to make it a layer (Cancel); it can't move up, fade or blend") {
            app.buttons["undo"].tap()
            XCTAssertNil(allLayers.first { $0["kind"] as? String == "Group" })
            app.buttons["layers"].tap()
            showLayer("Background").doubleTap()
            let alert = app.alerts["New Layer"]
            XCTAssert(alert.waitForExistence(timeout: 5), "it offers to make it a normal layer")
            alert.buttons["Cancel"].tap()
            XCTAssertEqual(inspect["backgroundLayer"] as? Int, layerID("Background"))
            tapLayer("Background")
            app.buttons["layers.up"].tap()
            XCTAssertEqual(allLayers.last?["name"] as? String, "Background", "it stays at the bottom")
            XCTAssertFalse(app.sliders["layers.opacity"].isEnabled, "no opacity")
            XCTAssertFalse(app.buttons["layers.blend"].isEnabled, "no blend mode")
        }

        step("The subject: Blend Screen, Opacity 76% (drag the word Opacity)") {
            tapLayer("subject")
            pick(app.buttons["layers.blend"], "Screen")
            XCTAssertEqual(layer(named: "subject")?["blend"] as? String, "Screen")
            let label = app.staticTexts["layers.opacity.label"]
            let mid = label.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            mid.press(forDuration: 0.1, thenDragTo: mid.withOffset(CGVector(dx: -72, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.2)
            let o = layer(named: "subject")?["opacity"] as? Double ?? 1
            XCTAssertEqual(o, 0.76, accuracy: 0.05, "scrubbed down to about 76%")
        }

        step("The trash deletes the selected layer") {
            let before = layerTotal
            app.buttons["layers.delete"].tap()
            XCTAssertEqual(layerTotal, before - 1)
            XCTAssertNil(layer(named: "subject"))
            // New layers go above the top one.
            tapLayer("Game")
            closeSheet()
        }

        step("Layer › New › Layer… (⇧⌘N): grain, Overlay, filled with 50% gray") {
            menu("Layer", "New", "Layer…")
            XCTAssert(app.textFields["newLayer.name"].waitForExistence(timeout: 5))
            replace(app.textFields["newLayer.name"], with: "grain")
            pick(app.buttons["newLayer.mode"], "Overlay")
            flip("newLayer.neutral")
            let before = stats([0, 0, 300, 200]).mean
            app.buttons["newLayer.ok"].tap()
            XCTAssertEqual(layer(named: "grain")?["blend"] as? String, "Overlay")
            XCTAssertEqual(stats([0, 0, 300, 200], of: "pixels", layer: "grain").mean.first ?? 0, 0.5, accuracy: 0.01, "50% gray")
            XCTAssertEqual(lum(stats([0, 0, 300, 200]).mean), lum(before), accuracy: 0.01, "and it changes nothing yet")
        }

        step("Rectangle tool: a shape layer; double-tap it to change its colour and round its corners") {
            tool(group: "Rectangle", pick: "Rectangle")
            drag(doc: (200, 600), to: (700, 850))
            let name = topName
            XCTAssertEqual(layer(named: name)?["kind"] as? String, "Shape")
            app.buttons["layers"].tap()
            XCTAssertEqual(app.descendants(matching: .any)["layer.thumb.\(name)"].firstMatch.value as? String, "Shape", "marked as a shape")
            app.descendants(matching: .any)["layer.thumb.\(name)"].firstMatch.doubleTap()
            XCTAssert(app.navigationBars["Shape"].waitForExistence(timeout: 5))
            app.sliders["shape.radius"].adjust(toNormalizedSliderPosition: 0.5)
            app.buttons["shape.fill"].tap()
            chooseColor(containing: "orange")
            let live = probe("shape.info", ["layer": layerID(name)])["live"] as? [String: Any]
            XCTAssertGreaterThan((live?["radii"] as? [Double])?.first ?? 0, 10, "rounded corners: \(live ?? [:])")
            let c = stats([300, 700, 600, 800]).mean
            XCTAssert(c[0] > c[2] + 0.3, "orange: \(c)")
            app.navigationBars["Shape"].buttons["sheet.done"].tap()
            closeSheet()
        }

        step("Crop, Delete Cropped Pixels off: drag the right edge past the image to add canvas") {
            let (w, h) = docSize
            // Room beside the image to drag into.
            menu("View", "Zoom Out")
            tool(group: "Crop", pick: "Crop")
            // On by default; off keeps what a crop cuts away.
            app.buttons["Delete Cropped Pixels"].tap()
            at(w / 2, h / 2).tap()
            drag(doc: (w, h / 2), to: (w + 300, h / 2))
            app.buttons["Commit"].tap()
            waitIdle()
            XCTAssertEqual(docSize.w, w + 300, accuracy: 4, "wider")
        }
    }
}

// MARK: - Transparency, embedded layers and live filters

final class LayerKindsTests: LayersTests {
    func testLayerKinds() {
        step("Open the bee, tap the Background's lock: the Eraser leaves transparency") {
            app.buttons["home.open"].tap()
            pickFile("bee")
            waitForCanvas()
            app.buttons["layers"].tap()
            app.buttons["layer.lock.Background"].tap()
            XCTAssertNil(inspect["backgroundLayer"] as? Int)
            closeSheet()
            tool(group: "Eraser", pick: "Eraser")
            drag(doc: (900, 100), to: (900, 300))
            XCTAssertLessThan(stats([890, 120, 910, 280], of: "pixels", layer: "Layer 0").mean.last ?? 1, 0.05, "transparent")
        }

        step("Magic Wand, Tolerance 20, tap the white, Delete: only the bee is left") {
            tool(group: "Object Selection", pick: "Magic Wand")
            app.sliders["option.Tolerance"].adjust(toNormalizedSliderPosition: 20.0 / 255)
            at(50, 950).tap()
            XCTAssert(app.buttons["Delete"].waitForExistence(timeout: 10), "selected")
            app.buttons["Delete"].tap()
            waitIdle()
            XCTAssertLessThan(stats([0, 800, 1000, 1000], of: "pixels", layer: "Layer 0").mean.last ?? 1, 0.02, "the white is gone")
            XCTAssertGreaterThan(stats([400, 500, 600, 600], of: "pixels", layer: "Layer 0").mean.last ?? 0, 0.98, "the bee stays")
            app.buttons["Deselect"].firstMatch.tap()
        }

        step("File › Export › Export As… PNG (it keeps transparency)") {
            menu("File", "Export", "Export As…")
            replace(app.textFields["export.name"], with: "bee transparent")
            app.buttons["export.export"].tap()
            XCTAssert(toast("Exported bee transparent.png"))
        }

        step("Open the bee on its own, hold it › Convert to Embedded Layer; double-tap its thumbnail, erase, File › Save, close: the embedded layer follows") {
            openFromHome()
            pickFile("bee-cutout")
            XCTAssert(docOpen("bee-cutout.png", timeout: 20))
            let name = topName
            app.buttons["layers"].tap()
            layerMenu(name, "Convert to Embedded Layer")
            XCTAssertEqual(app.descendants(matching: .any)["layer.thumb.\(name)"].firstMatch.value as? String, "Embedded", "marked as embedded")
            let b = bounds(name)
            let spot = [Int(b[0] + b[2] * 0.35), Int(b[1] + b[3] * 0.45), Int(b[0] + b[2] * 0.45), Int(b[1] + b[3] * 0.55)]
            let before = stats(spot, of: "pixels", layer: name).mean.last ?? 0
            app.descendants(matching: .any)["layer.thumb.\(name)"].firstMatch.doubleTap()
            XCTAssertGreaterThan((probe("app.documents")["names"] as? [String])?.count ?? 0, 2, "its contents open as another document")
            waitForCanvas()
            tool(group: "Eraser", pick: "Eraser")
            option("Size", 0.6)
            let (cw, ch) = docSize
            for f in stride(from: 0.35, to: 0.6, by: 0.08) { drag(doc: (cw * 0.3, ch * f), to: (cw * 0.5, ch * f)) }
            menu("File", "Save")
            // A busy app can show the message before the test looks: the check is the layer below.
            _ = toast("Saved the embedded layer")
            waitIdle()
            menu("File", "Close")
            let dontSave = app.buttons["Don't Save"]
            if dontSave.waitForExistence(timeout: 3) { dontSave.tap() }
            waitIdle()
            XCTAssertLessThan(stats(spot, of: "pixels", layer: name).mean.last ?? 1, before - 0.3, "erased in the embedded layer too")
        }

        step("The Eraser can't change an embedded layer (it offers to rasterize: Cancel); a mask hides instead, and brings back") {
            let name = topName
            let b = bounds(name)
            tool(group: "Eraser", pick: "Eraser")
            drag(doc: (b[0] + b[2] * 0.6, b[1] + b[3] * 0.5), to: (b[0] + b[2] * 0.9, b[1] + b[3] * 0.5))
            XCTAssert(app.buttons["rasterize.ok"].waitForExistence(timeout: 5), "asks to rasterize")
            app.buttons["Cancel"].firstMatch.tap()
            XCTAssertEqual(layer(named: name)?["kind"] as? String, "Embedded")
            app.buttons["layers"].tap()
            app.buttons["layers.mask"].tap()
            XCTAssertEqual(inspect["maskTarget"] as? Bool, true, "painting goes on the mask")
            closeSheet()
            // Keys stop reaching the iPhone simulator once a menu has been used: colours from the picker.
            pickColor(containing: "black")
            tool(group: "Brush", pick: "Brush")
            let row = [Int(b[0] + b[2] * 0.6), Int(b[1] + b[3] * 0.5 - 5), Int(b[0] + b[2] * 0.9), Int(b[1] + b[3] * 0.5 + 5)]
            let before = stats(row).mean
            drag(doc: (b[0] + b[2] * 0.6, b[1] + b[3] * 0.5), to: (b[0] + b[2] * 0.9, b[1] + b[3] * 0.5))
            XCTAssertLessThan(stats(row, of: "mask", layer: name).mean.first ?? 1, 0.3, "black hides")
            pickColor(containing: "white")
            drag(doc: (b[0] + b[2] * 0.6, b[1] + b[3] * 0.5), to: (b[0] + b[2] * 0.9, b[1] + b[3] * 0.5))
            XCTAssertEqual(lum(stats(row).mean), lum(before), accuracy: 0.03, "white brings it back")
        }

        var copy = ""
        step("Open the seaside, Layer › New › Layer via Copy, Filter › Convert for Live Filters, Develop: brighter") {
            openFromHome()
            pickFile("seaside")
            XCTAssert(docOpen("seaside.jpg", timeout: 20))
            menu("Layer", "New", "Layer via Copy")
            XCTAssertEqual(layerTotal, 2)
            copy = topName
            menu("Filter", "Convert for Live Filters")
            XCTAssertEqual(layer(named: copy)?["kind"] as? String, "Embedded")
            let before = lum(stats().mean)
            menu("Filter", "Develop…")
            XCTAssert(app.buttons["raw.ok"].waitForExistence(timeout: 5), "Develop")
            app.sliders["raw.exposure"].adjust(toNormalizedSliderPosition: 0.6)
            waitIdle()
            app.buttons["raw.ok"].tap()
            waitIdle()
            let f = (layer(named: copy)?["smartFilters"] as? [[String: Any]])?.first
            XCTAssertEqual(f?["command"] as? String, "filter.cameraRaw")
            XCTAssertGreaterThan(lum(stats().mean), before + 0.03, "brighter")
        }

        step("Add Noise: a live filter; double-tap it to change it, hold it › Delete Live Filter; the arrow folds the filters away") {
            menu("Filter", "Noise", "Add Noise…")
            app.buttons["settings.run"].tap()
            waitIdle()
            var filters = layer(named: copy)?["smartFilters"] as? [[String: Any]] ?? []
            XCTAssert(filters.contains { $0["command"] as? String == "filter.noise.addNoise" }, "\(filters)")
            app.buttons["layers"].tap()
            let row = show(app.descendants(matching: .any)["filter.\(copy).Add Noise"].firstMatch, "the filter under its layer")
            row.doubleTap()
            // Two slow taps are two single taps: try again.
            if !app.navigationBars["Add Noise"].waitForExistence(timeout: 4) { row.doubleTap() }
            XCTAssert(app.navigationBars["Add Noise"].waitForExistence(timeout: 5))
            app.sliders["settings.amount.slider"].adjust(toNormalizedSliderPosition: 0.5)
            app.buttons["settings.run"].tap()
            filters = layer(named: copy)?["smartFilters"] as? [[String: Any]] ?? []
            let noise = filters.first { $0["command"] as? String == "filter.noise.addNoise" }
            XCTAssertGreaterThan((noise?["params"] as? [String: Any])?["amount"] as? Double ?? 0, 20, "changed later: \(filters)")
            row.press(forDuration: 1.0)
            app.buttons["Delete Live Filter"].tap()
            XCTAssertEqual((layer(named: copy)?["smartFilters"] as? [Any])?.count ?? 0, 1, "only Develop left")
            showLayer(copy)
            app.buttons["layer.filters.\(copy)"].tap()
            XCTAssertFalse(app.descendants(matching: .any)["filter.\(copy).Develop"].exists)
            closeSheet()
        }

        step("◑ › Hue/Saturation, Window › Properties: drag on a blue in the image (the targeted adjustment)") {
            app.buttons["layers"].tap()
            addAdjustment("Hue/Saturation")
            XCTAssert(app.navigationBars["Hue/Saturation"].waitForExistence(timeout: 5))
            app.navigationBars["Hue/Saturation"].buttons["sheet.done"].tap()
            closeSheet()
            // Window › Properties leaves the canvas free to drag on.
            menu("Window", "Properties")
            XCTAssert(app.navigationBars["Hue/Saturation"].waitForExistence(timeout: 5))
            flip("hs.targeted")
            XCTAssert(app.segmentedControls["hs.dragHue"].waitForExistence(timeout: 5), "dragging in the image is on")
            // The shirt is under the half-height sheet here: drag on the sky, as blue as the shirt.
            drag(doc: (400, 60), to: (240, 60))
            let blues = (layer(named: "Hue/Saturation 1")?["adjustment"] as? [String: Any]).flatMap { ($0["params"] as? [String: Any])?["blues"] as? [String: Any] }
            XCTAssertLessThan(blues?["saturation"] as? Double ?? 0, -20, "dragging left took saturation out of the blues: \(blues ?? [:])")
            app.navigationBars["Hue/Saturation"].buttons["sheet.done"].tap()
        }
    }
}
