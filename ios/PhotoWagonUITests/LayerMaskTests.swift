import XCTest

/// Layer masks: the mask thumbnail (target, View Mask, Mask Properties, its menu), the link, the
/// trash's question, Select › Sky with the mask button's Hide Selection, and a photo pasted into a
/// mask. See `docs/ios-walkthroughs/layer-mask.md` for each step and where it lives in the app.
/// Shared helpers; each part is its own class below, so parallel runs can spread them.
class LayerMaskTests: WalkthroughTestCase {
    var element: (String) -> XCUIElement { { self.app.descendants(matching: .any)[$0].firstMatch } }

    /// A layer's mask properties, as `document.inspect` reports them.
    func mask(_ name: String) -> [String: Any] { layer(named: name)?["mask"] as? [String: Any] ?? [:] }

    func maskMean(_ name: String, _ rect: [Int]? = nil) -> Double { stats(rect, of: "mask", layer: name).mean.first ?? -1 }

    func hasMask(_ name: String) -> Bool { layer(named: name)?["hasMask"] as? Bool == true }

    func maskThumb(_ name: String) -> XCUIElement { show(element("layer.mask.\(name)"), "\(name)'s mask") }

    /// Touch and hold `name`'s mask, then pick `item` (in a submenu: `then`).
    func maskMenu(_ name: String, _ item: String, then sub: String? = nil) {
        let thumb = maskThumb(name)
        for _ in 0..<3 {
            thumb.press(forDuration: 1.0)
            let b = app.buttons[item].firstMatch
            if b.waitForExistence(timeout: 3) {
                Thread.sleep(forTimeInterval: 0.4)
                b.tap()
                if let sub {
                    let s = app.buttons[sub].firstMatch
                    XCTAssert(s.waitForExistence(timeout: 3), sub)
                    Thread.sleep(forTimeInterval: 0.3)
                    s.tap()
                }
                waitIdle()
                return
            }
        }
        XCTFail("no \(item) in \(name)'s mask menu")
    }
}

// MARK: - The mask thumbnail, its menu, the link and the trash

final class MaskBasicsTests: LayerMaskTests {
    func testMaskThumbnail() {
        var (w, h) = (1600.0, 900.0)
        var box: [Int] { [Int(w * 0.38), Int(h * 0.35), Int(w * 0.52), Int(h * 0.95)] }
        var inside: [Int] { [Int(w * 0.42), Int(h * 0.5), Int(w * 0.48), Int(h * 0.8)] }
        var outside: [Int] { [Int(w * 0.8), 0, Int(w), Int(h * 0.2)] }
        let fill = "Color Fill 1"

        step("Eyedropper options: Sample Size 3 by 3 Average, Sample All Layers") {
            openSample("seaside")
            (w, h) = docSize
            tool(group: "Eyedropper", pick: "Eyedropper")
            pick(app.buttons["option.sampleSize"], "3 by 3 Average")
            pick(app.buttons["option.sampleLayers"], "All Layers")
            XCTAssert(app.buttons["option.sampleSize"].label.contains("3 by 3"), app.buttons["option.sampleSize"].label)
            XCTAssert(app.buttons["option.sampleLayers"].label.contains("All Layers"), app.buttons["option.sampleLayers"].label)
        }

        step("A box around the man, ◑ › Solid Color › Pick from Image: the sky's colour, masked to the box") {
            tool(group: "Rectangular Marquee", pick: "Rectangular Marquee")
            drag(doc: (Double(box[0]), Double(box[1])), to: (Double(box[2]), Double(box[3])))
            waitIdle()
            app.buttons["layers"].tap()
            addAdjustment("Solid Color")
            XCTAssert(app.navigationBars["Color Fill"].waitForExistence(timeout: 5))
            XCTAssertGreaterThan(maskMean(fill, inside), 0.9, "the box shows")
            XCTAssertLessThan(maskMean(fill, outside), 0.1, "the rest hides")
            // Outside the box the fill is masked off, so this samples the photo's sky.
            app.buttons["fill.pick"].tap()
            app.otherElements["preview"].coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.1)).tap()
            waitIdle()
            app.navigationBars["Color Fill"].buttons["sheet.done"].tap()
            let c = stats(inside).mean
            XCTAssertGreaterThan(c[2], c[0] + 0.1, "a sky blue: \(c)")
            closeSheet()
            app.buttons["Deselect"].firstMatch.tap()
            waitIdle()
        }

        step("Tap the mask: it's the target; hold › View Mask: the mask in grey on the canvas; Done") {
            app.buttons["layers"].tap()
            maskThumb(fill).tap()
            waitIdle()
            XCTAssertEqual(inspect["maskTarget"] as? Bool, true, "the mask is selected")
            maskMenu(fill, "View Mask")
            XCTAssertNotNil(inspect["layerMaskView"] as? [String: Any], "the mask view is on")
            closeSheet()
            let done = app.buttons["maskView.done"]
            XCTAssert(done.waitForExistence(timeout: 5), "it says the mask is showing")
            Thread.sleep(forTimeInterval: 0.5)
            let white = screenColor(at(w * 0.45, h * 0.65))
            let black = screenColor(at(w * 0.9, h * 0.1))
            XCTAssertGreaterThan(lum(white), 0.9, "white in the box: \(white)")
            XCTAssertLessThan(lum(black), 0.2, "black outside, not the photo: \(black)")
            done.tap()
            XCTAssertNil(inspect["layerMaskView"] as? [String: Any], "the image again")
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertLessThan(lum(screenColor(at(w * 0.45, h * 0.65))), 0.9, "the colour shows")
        }

        step("Double-tap the mask: Mask Properties, Density 50%, Feather 20 px") {
            app.buttons["layers"].tap()
            let thumb = maskThumb(fill)
            thumb.doubleTap()
            if !app.navigationBars["Mask Properties"].waitForExistence(timeout: 4) { thumb.doubleTap() }
            XCTAssert(app.navigationBars["Mask Properties"].waitForExistence(timeout: 5), "Mask Properties")
            replace(app.textFields["mask.density.value"], with: "50\n")
            replace(app.textFields["mask.feather.value"], with: "20\n")
            waitIdle()
            XCTAssertEqual(mask(fill)["density"] as? Double ?? 0, 50, accuracy: 0.5)
            XCTAssertEqual(mask(fill)["feather"] as? Double ?? 0, 20, accuracy: 0.5)
            app.navigationBars["Mask Properties"].buttons["sheet.done"].tap()
        }

        step("Hold the mask › Disable Mask: a red cross; › Invert Mask: the other way round") {
            maskMenu(fill, "Disable Mask")
            XCTAssertEqual(mask(fill)["enabled"] as? Bool, false)
            XCTAssertEqual(maskThumb(fill).value as? String, "disabled", "marked off")
            maskMenu(fill, "Invert Mask")
            XCTAssertLessThan(maskMean(fill, inside), 0.1, "the box hides now")
            XCTAssertGreaterThan(maskMean(fill, outside), 0.9)
        }

        step("Tap the link between the thumbnails: unlinked") {
            show(element("layer.link.\(fill)"), "the link").tap()
            waitIdle()
            XCTAssertEqual(mask(fill)["linked"] as? Bool, false)
        }

        var other = "Layer 1"
        step("A new layer; hold the mask › Copy Mask To › it: the same mask on both") {
            let before = Set(allLayers.compactMap { $0["name"] as? String })
            app.buttons["layers.new"].tap()
            waitIdle()
            other = allLayers.compactMap { $0["name"] as? String }.first { !before.contains($0) } ?? other
            maskMenu(fill, "Copy Mask To", then: other)
            XCTAssertTrue(hasMask(other))
            XCTAssertEqual(maskMean(other), maskMean(fill), accuracy: 0.001)
            XCTAssertTrue(hasMask(fill), "a copy: the first keeps its own")
        }

        step("Select the copy, the trash: it asks first; Delete takes the mask, not the layer") {
            maskThumb(other).tap()
            waitIdle()
            app.buttons["layers.delete"].tap()
            let delete = app.buttons["deleteMask.delete"]
            XCTAssert(delete.waitForExistence(timeout: 5), "asks to apply or delete")
            delete.tap()
            waitIdle()
            XCTAssertFalse(hasMask(other))
            XCTAssertNotNil(layer(named: other), "the layer stays")
        }

        step("Hold the mask › Move Mask To › the new layer, then › Delete Mask") {
            maskMenu(fill, "Move Mask To", then: other)
            XCTAssertTrue(hasMask(other), "moved here")
            XCTAssertFalse(hasMask(fill), "moved off")
            maskMenu(other, "Delete Mask")
            XCTAssertFalse(hasMask(other))
            closeSheet()
        }
    }
}

// MARK: - A mask from Select › Sky, and a photo pasted into a mask

final class SkyMaskTests: LayerMaskTests {
    func testSkyAndPastedMask() {
        var (w, h) = (1600.0, 1200.0)
        var sky: [Int] { [0, 0, Int(w), Int(h * 0.12)] }
        var land: [Int] { [0, Int(h * 0.85), Int(w), Int(h)] }
        let pixels = { self.stats(nil, of: "pixels", layer: "Layer 0").mean }

        step("Edit › Preferences › General: placed pictures fit the canvas and come in as embedded layers") {
            openSample("background")
            (w, h) = docSize
            menu("Edit", "Preferences", "General…")
            XCTAssert(app.navigationBars["General"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.switches["prefs.resizeImageDuringPlace"].value as? String, "1")
            XCTAssertEqual(app.switches["prefs.alwaysCreateEmbedded"].value as? String, "1")
            closeSheet()
        }

        step("Tap the Background's lock: a normal layer") {
            app.buttons["layers"].tap()
            app.buttons["layer.lock.Background"].tap()
            waitIdle()
            XCTAssertNotNil(layer(named: "Layer 0"))
            closeSheet()
            // For the paste below.
            menu("Select", "All")
            menu("Edit", "Copy")
            waitIdle()
        }

        step("Select › Sky, then hold the mask button › Hide Selection: the sky hides, the land shows") {
            menu("Select", "Sky")
            waitIdle()
            XCTAssertGreaterThan(stats(sky, of: "selection").mean.first ?? 0, 0.8, "the sky is selected")
            XCTAssertLessThan(stats(land, of: "selection").mean.first ?? 1, 0.2, "not the land")
            app.buttons["layers"].tap()
            maskButton("Hide Selection")
            XCTAssertLessThan(maskMean("Layer 0", sky), 0.2, "the sky hides")
            XCTAssertGreaterThan(maskMean("Layer 0", land), 0.8, "the land shows")
        }

        var before: [Double] = []
        step("Hold the mask › View Mask, Edit › Paste: the photo goes into the mask, still selected") {
            before = pixels()
            maskMenu("Layer 0", "View Mask")
            closeSheet()
            menu("Edit", "Paste")
            waitIdle()
            XCTAssertLessThan(maskMean("Layer 0", land), 0.5, "the dark land, not white")
            XCTAssertEqual(maskMean("Layer 0"), lum(before), accuracy: 0.08, "the photo's tones")
            XCTAssertNotNil(inspect["selectionBounds"] as? [Any], "the pasted part stays selected")
        }

        step("Edit › Free Transform: the pasted part shrinks in the mask; the layer doesn't move") {
            let m = maskMean("Layer 0")
            menu("Edit", "Free Transform")
            XCTAssert(app.buttons["Commit"].waitForExistence(timeout: 5))
            let b = (probe("document.inspect")["selectionBounds"] as? [Double]) ?? [0, 0, w, h]
            // The bottom right corner, in towards the middle.
            let corner = b.count == 4 ? (b[0] + b[2], b[1] + b[3]) : (w, h)
            drag(doc: (min(corner.0, w - 2), min(corner.1, h - 2)), to: (w * 0.7, h * 0.7))
            app.buttons["Commit"].tap()
            waitIdle()
            XCTAssertNotEqual(maskMean("Layer 0"), m, accuracy: 0.005, "the mask changed")
            XCTAssertEqual(pixels(), before, "the layer's pixels are where they were")
        }
    }
}
