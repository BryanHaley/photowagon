import XCTest

/// The settings screens of their own (Curves, Color Balance, the blur handles, Color Range…):
/// each opens from its menu, one change shows in the image, and OK keeps it as one step.
class SettingsScreensTests: WalkthroughTestCase {
    let area = [200, 300, 1200, 600]
    let sky = [200, 40, 1200, 200]
    let sand = [600, 750, 800, 850]

    func openBeach() {
        app.buttons["home.open"].tap()
        pickFile("beach")
        waitForCanvas()
    }

    func open(_ path: String..., title: String) {
        menu(path)
        XCTAssert(app.navigationBars[title].waitForExistence(timeout: 10), "\(title) opened")
        waitIdle()
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "screen \(title)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func menu(_ path: [String]) {
        switch path.count {
        case 2: menu(path[0], path[1])
        case 3: menu(path[0], path[1], path[2])
        default: XCTFail("menu path \(path)")
        }
    }

    func ok(_ history: String) {
        app.buttons["settings.run"].firstMatch.tap()
        waitIdle()
        noErrorToast()
        XCTAssertEqual((inspect["history"] as? [String])?.last, history)
    }

    var element: (String) -> XCUIElement { { self.app.descendants(matching: .any)[$0].firstMatch } }

    /// A screenshot kept with the results, for looking at a screen mid-step.
    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "screen \(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    func spread(_ c: [Double]) -> Double { (c.prefix(3).max() ?? 0) - (c.prefix(3).min() ?? 0) }

    /// Drag on `e` between fractions of its size.
    func drag(_ e: XCUIElement, from a: (Double, Double), to b: (Double, Double)) {
        e.coordinate(withNormalizedOffset: CGVector(dx: a.0, dy: a.1))
            .press(forDuration: 0.1, thenDragTo: e.coordinate(withNormalizedOffset: CGVector(dx: b.0, dy: b.1)), withVelocity: .slow, thenHoldForDuration: 0.1)
    }
}

final class CurvesScreenTests: SettingsScreensTests {
    func testCurves() {
        var before = 0.0
        step("Image › Adjustments › Curves: the curve over the histogram") {
            openBeach()
            before = lum(stats(area).mean)
            open("Image", "Adjustments", "Curves…", title: "Curves")
            XCTAssert(element("curves.graph").exists)
            XCTAssert(app.segmentedControls["curves.channel"].exists, "RGB, Red, Green, Blue")
        }
        step("Drag the middle of the curve up: a new point, and the image brightens") {
            drag(element("curves.graph"), from: (0.5, 0.5), to: (0.5, 0.3))
            waitIdle()
            let points = (element("curves.graph").value as? String ?? "").split(separator: " ")
            XCTAssertEqual(points.count, 3, "\(points)")
            XCTAssertGreaterThan(lum(stats(area).mean), before + 0.05)
        }
        step("Drag the point off the graph: it goes, and the image is back") {
            drag(element("curves.graph"), from: (0.5, 0.3), to: (-0.4, 0.3))
            waitIdle()
            XCTAssertEqual((element("curves.graph").value as? String ?? "").split(separator: " ").count, 2)
            XCTAssertEqual(lum(stats(area).mean), before, accuracy: 0.01)
        }
        step("Pencil: draw a dark curve, Smooth it, then back to points") {
            app.segmentedControls["curves.mode"].buttons.element(boundBy: 1).tap()
            XCTAssert(app.buttons["curves.smooth"].waitForExistence(timeout: 5))
            // On iOS 27 the graph runs past the bottom of the screen: scroll the sheet until it all
            // shows, away from the bottom edge where iOS holds touches for its own gesture.
            let graph = element("curves.graph")
            let list = app.collectionViews.firstMatch
            for _ in 0..<4 where graph.frame.maxY > app.windows.firstMatch.frame.height - 60 {
                let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5))
                from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -200)), withVelocity: .slow, thenHoldForDuration: 0.2)
                Thread.sleep(forTimeInterval: 0.5)
            }
            drag(graph, from: (0.15, 0.75), to: (0.9, 0.55))
            waitIdle()
            XCTAssertLessThan(lum(stats(area).mean), before - 0.1, "darker")
            show(app.buttons["curves.smooth"].firstMatch, "Smooth").tap()
            show(app.segmentedControls["curves.mode"].firstMatch, "the edit mode").buttons.element(boundBy: 0).tap()
            waitIdle()
            XCTAssertGreaterThanOrEqual((element("curves.graph").value as? String ?? "").split(separator: " ").count, 5, "points that follow the drawing")
        }
        step("Preset Negative, then Auto, then OK: one Curves step") {
            pick(show(app.buttons["curves.preset"].firstMatch, "the preset"), "Negative")
            waitIdle()
            XCTAssertLessThan(lum(stats(sky).mean), 0.4, "the sky went dark")
            app.buttons["curves.auto"].tap()
            waitIdle()
            ok("Curves")
            XCTAssertNotEqual(lum(stats(area).mean), before, accuracy: 0.005)
        }
    }
}

final class ColorScreensTests: SettingsScreensTests {
    func testColorBalanceChannelMixerSelectiveColor() {
        step("Color Balance: midtones toward red") {
            openBeach()
            let before = stats(area).mean
            open("Image", "Adjustments", "Color Balance…", title: "Color Balance")
            app.sliders["balance.0"].slide(to: 1)
            waitIdle()
            let after = stats(area).mean
            XCTAssertGreaterThan(after[0] - after[2], before[0] - before[2] + 0.05, "\(before) → \(after)")
            ok("Color Balance")
        }
        step("Channel Mixer: Monochrome makes it gray; the total shows") {
            open("Image", "Adjustments", "Channel Mixer…", title: "Channel Mixer")
            XCTAssert(element("mixer.total").exists)
            flip("mixer.monochrome")
            waitIdle()
            XCTAssertLessThan(spread(stats(area).mean), 0.01)
            ok("Channel Mixer")
            app.buttons["undo"].tap()
        }
        step("Selective Color: Blues lose their cyan; switching colors keeps it") {
            let before = stats(sky).mean
            open("Image", "Adjustments", "Selective Color…", title: "Selective Color")
            pick(app.buttons["selective.colors"], "Blues")
            app.sliders["selective.0"].slide(to: 0)
            waitIdle()
            XCTAssertGreaterThan(stats(sky).mean[0], before[0] + 0.01, "redder sky: \(before) → \(stats(sky).mean)")
            pick(app.buttons["selective.colors"], "Reds")
            pick(app.buttons["selective.colors"], "Blues")
            XCTAssertEqual(app.textFields["selective.0.value"].value as? String, "-100")
            ok("Selective Color")
        }
    }

    func testThresholdPhotoFilterBlackWhite() {
        step("Threshold: black and white, the histogram behind the level") {
            openBeach()
            open("Image", "Adjustments", "Threshold…", title: "Threshold")
            XCTAssert(element("threshold.graph").exists)
            XCTAssertLessThan(spread(stats(sand).mean), 0.01, "black and white as it opens")
            let before = lum(stats(area).mean)
            app.sliders["threshold.level"].slide(to: 0.8)
            waitIdle()
            XCTAssertLessThan(lum(stats(area).mean), before - 0.05, "a higher level: more black")
            ok("Threshold")
            app.buttons["undo"].tap()
        }
        step("Photo Filter: more density, warmer") {
            let before = stats(area).mean
            open("Image", "Adjustments", "Photo Filter…", title: "Photo Filter")
            app.sliders["photoFilter.density"].slide(to: 1)
            waitIdle()
            let after = stats(area).mean
            XCTAssertGreaterThan(after[0] - after[2], before[0] - before[2] + 0.05)
            XCTAssert(app.segmentedControls["photoFilter.use"].exists, "Filter or Color")
            ok("Photo Filter")
            app.buttons["undo"].tap()
        }
        step("Black & White: gray; Auto picks a mix; a preset sets the sliders") {
            open("Image", "Adjustments", "Black & White…", title: "Black & White")
            XCTAssertLessThan(spread(stats(area).mean), 0.01)
            app.buttons["bw.auto"].tap()
            waitIdle()
            XCTAssert(app.buttons["bw.preset"].label.contains("Auto"))
            pick(app.buttons["bw.preset"], "Blue Filter")
            waitIdle()
            XCTAssertEqual(app.textFields["bw.blues.value"].value as? String, "130")
            ok("Black & White")
        }
    }

    func testGradientMapHueSaturationReplaceColor() {
        step("Gradient Map: foreground to background; Reverse inverts it") {
            openBeach()
            open("Image", "Adjustments", "Gradient Map…", title: "Gradient Map")
            XCTAssertLessThan(spread(stats(area).mean), 0.02, "black to white: gray")
            let before = lum(stats(sky).mean)
            flip("gmap.reverse")
            waitIdle()
            XCTAssertLessThan(lum(stats(sky).mean), before - 0.2)
            XCTAssert(app.buttons["gmap.addStop"].exists)
            ok("Gradient Map")
            app.buttons["undo"].tap()
        }
        step("Hue/Saturation from the Image menu: no saturation, gray") {
            open("Image", "Adjustments", "Hue/Saturation…", title: "Hue/Saturation")
            app.sliders["hs.saturation"].slide(to: 0)
            waitIdle()
            XCTAssertLessThan(spread(stats(area).mean), 0.02)
            ok("Hue/Saturation")
            app.buttons["undo"].tap()
        }
        step("Replace Color: pick the sky in the preview, turn its hue") {
            let before = stats(sky).mean
            open("Image", "Adjustments", "Replace Color…", title: "Replace Color")
            app.buttons["replace.pick"].tap()
            app.otherElements["preview"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
            app.sliders["replace.hue"].slide(to: 1)
            waitIdle()
            let after = stats(sky).mean
            XCTAssertLessThan(after[2], before[2] - 0.1, "the sky isn't blue now: \(before) → \(after)")
            ok("Replace Color")
        }
    }
}

final class SelectAndFilterScreensTests: SettingsScreensTests {
    func testColorRangeAndBlurHandles() {
        step("Select › Color Range: tap the sky in the preview; the selection shows") {
            openBeach()
            open("Select", "Color Range…", title: "Color Range")
            app.otherElements["preview"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
            waitIdle()
            XCTAssertEqual(inspect["hasSelection"] as? Bool, true)
            let b = inspect["selectionBounds"] as? [Int] ?? []
            XCTAssertLessThan(b.count == 4 ? b[1] : 999, 100, "starts at the top: \(b)")
            ok("Color Range")
            menu("Select", "Deselect")
        }
        step("Iris Blur: drag the centre handle to the corner; the middle blurs") {
            let before = stats([600, 350, 800, 500]).stddev[0]
            open("Filter", "Blur Effects", "Iris Blur…", title: "Iris Blur")
            let centre = element("handle.centerX")
            XCTAssert(centre.exists)
            centre.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: app.otherElements["preview"].coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)))
            waitIdle()
            ok("Iris Blur")
            XCTAssertLessThan(stats([600, 350, 800, 500]).stddev[0], before - 0.005, "the middle is out of the iris now")
            app.buttons["undo"].tap()
        }
        step("Lighting Effects: the light and its target are handles") {
            open("Filter", "Render", "Lighting Effects…", title: "Lighting Effects")
            XCTAssert(element("handle.lightX").exists && element("handle.targetX").exists)
            element("handle.lightX").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: app.otherElements["preview"].coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8)))
            waitIdle()
            ok("Lighting Effects")
            app.buttons["undo"].tap()
        }
    }

    func testShearDisplaceFilterGallery() {
        step("Shear: bend the line; the image shears") {
            openBeach()
            let before = stats(area).mean
            open("Filter", "Distort", "Shear…", title: "Shear")
            drag(element("shear.graph"), from: (0.5, 0.5), to: (0.8, 0.5))
            waitIdle()
            XCTAssertNotEqual(stats(area).mean[0], before[0], accuracy: 0.002)
            ok("Shear")
        }
        step("Displace: the map is an open document") {
            open("Filter", "Distort", "Displace…", title: "Displace")
            XCTAssert(app.buttons["displace.map"].exists)
            XCTAssertFalse(app.textFields["settings.mapPath"].exists, "no file path")
            ok("Displace")
        }
        step("Filter Gallery: an effect with its settings; add another") {
            open("Filter", "Filter Gallery…", title: "Filter Gallery")
            element("gallery.effect.0").tap()
            XCTAssert(app.navigationBars.element(boundBy: 0).waitForExistence(timeout: 5))
            app.navigationBars.buttons.element(boundBy: 0).tap()
            pick(app.buttons["gallery.add"], "Dry Brush")
            XCTAssert(element("gallery.effect.1").waitForExistence(timeout: 5))
            waitIdle()
            ok("Filter Gallery")
        }
    }

    func testCanvasSizeDuotoneColorTable() {
        step("Canvas Size: anchor top left, wider; the new strip is on the right") {
            openBeach()
            open("Image", "Canvas Size…", title: "Canvas Size")
            app.buttons["anchor.topLeft"].tap()
            replace(app.textFields["settings.width"], with: "1600\n")
            XCTAssert(app.buttons["settings.extensionColor.choice"].exists, "the extension color")
            app.buttons["settings.run"].tap()
            waitIdle()
            XCTAssertEqual(inspect["width"] as? Int, 1600)
            XCTAssertGreaterThan(lum(stats([1450, 400, 1550, 500]).mean), 0.95, "white on the right")
        }
        step("Edit › Fill: a color to pick") {
            open("Edit", "Fill…", title: "Fill")
            XCTAssert(app.buttons["settings.color"].exists)
            app.buttons["Cancel"].firstMatch.tap()
        }
        step("Image › Mode › Duotone: inks with names, colors and curves") {
            menu("Image", "Mode", "Grayscale")
            waitIdle()
            open("Image", "Mode", "Duotone…", title: "Duotone")
            XCTAssertEqual(app.textFields["duotone.name.1"].value as? String, "Warm Brown")
            pick(app.buttons["duotone.type"], "Tritone")
            XCTAssert(app.textFields["duotone.name.2"].waitForExistence(timeout: 5))
            app.buttons["settings.run"].tap()
            waitIdle()
            XCTAssertEqual(inspect["mode"] as? String, "Duotone")
        }
        step("Image › Mode › Color Table: the indexed image's colors") {
            menu("Image", "Mode", "Grayscale")
            menu("Image", "Mode", "RGB Color")
            waitIdle()
            open("Image", "Mode", "Indexed Color…", title: "Indexed Color")
            app.buttons["settings.run"].tap()
            waitIdle()
            XCTAssertEqual(inspect["mode"] as? String, "Indexed")
            open("Image", "Mode", "Color Table…", title: "Color Table")
            XCTAssert(element("colorTable.0").exists)
            app.buttons["settings.run"].tap()
            waitIdle()
            noErrorToast()
        }
    }
}

/// Levels' Preview switch, Show Clipping and Auto's Options; on an iPad, the eyedroppers pick on
/// the canvas while the settings step aside.
final class ToneOptionsTests: SettingsScreensTests {
    var wide: Bool { app.windows.firstMatch.frame.width > 700 }

    func testPreviewClippingAndAutoOptions() {
        var original = 0.0
        step("Levels: drag the white point in; Preview off shows the photo as it was, on shows the change") {
            openBeach()
            original = lum(stats(area).mean)
            open("Image", "Adjustments", "Levels…", title: "Levels")
            drag(element("levels.input"), from: (0.995, 0.5), to: (0.6, 0.5))
            waitIdle()
            let changed = lum(stats(area).mean)
            XCTAssertGreaterThan(changed, original + 0.05)
            app.buttons["settings.preview"].tap()
            waitIdle()
            XCTAssertEqual(lum(stats(area).mean), original, accuracy: 0.002)
            app.buttons["settings.preview"].tap()
            waitIdle()
            XCTAssertEqual(lum(stats(area).mean), changed, accuracy: 0.002)
        }
        step("Show Clipping: the histogram marks what clips and says how much; outlines on the preview") {
            flip("levels.showClipping")
            let text = element("levels.clipping")
            XCTAssert(text.waitForExistence(timeout: 5))
            XCTAssert(text.label.contains("Highlights"), text.label)
            XCTAssertFalse(text.label.contains("Highlights 0.0%"), "the white point moved in clips the sky: \(text.label)")
            if !wide { XCTAssert(element("preview.clipping").waitForExistence(timeout: 10), "outlines on the preview") }
            shot("Show Clipping")
            flip("levels.showClipping")
        }
        step("Auto Options: Find Dark & Light Colors with Snap Neutral Midtones, then OK runs Auto") {
            app.buttons["levels.options"].tap()
            XCTAssert(app.navigationBars["Auto Options"].waitForExistence(timeout: 5))
            app.buttons["Find Dark & Light Colors"].tap()
            flip("auto.snap")
            shot("Auto Options")
            app.buttons["auto.ok"].tap()
            waitIdle()
            XCTAssert(app.buttons["levels.preset"].label.contains("Auto"), app.buttons["levels.preset"].label)
            ok("Levels")
        }
    }

    func testPropertiesEyedropperPicksOnThePreview() throws {
        try XCTSkipIf(wide, "the iPad test covers its side panel")
        step("A Levels adjustment layer in Window › Properties: Set White Point, then the sky in the preview") {
            openBeach()
            app.buttons["layers"].tap()
            addAdjustment("Levels")
            XCTAssert(app.navigationBars["Levels"].waitForExistence(timeout: 5))
            app.navigationBars["Levels"].buttons["sheet.done"].tap()
            closeSheet()
            menu("Window", "Properties")
            XCTAssert(app.navigationBars["Levels"].waitForExistence(timeout: 5))
            let before = stats(sky).mean
            expandSheet()
            for _ in 0..<3 where !app.buttons["levels.whitePoint"].exists { element("levels.showClipping").swipeUp() }
            app.buttons["levels.whitePoint"].tap()
            XCTAssertFalse(element("pick.bar").exists, "a phone picks on the preview, not the canvas")
            app.otherElements["preview"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
            waitIdle()
            shot("Properties pick")
            XCTAssertGreaterThan(lum(stats(sky).mean), lum(before) + 0.1, "the sky is the white point now")
            noErrorToast()
        }
    }

    func testIPadEyedropperPicksOnTheCanvas() throws {
        try XCTSkipUnless(wide, "an iPad: the settings sit beside the canvas")
        step("Levels › Set White Point: the settings step aside and the canvas takes the pick") {
            openBeach()
            open("Image", "Adjustments", "Levels…", title: "Levels")
            app.swipeUp()
            app.buttons["levels.whitePoint"].tap()
            XCTAssert(element("pick.bar").waitForExistence(timeout: 5), "what to tap, and Cancel")
            XCTAssertFalse(app.navigationBars["Levels"].isHittable, "the settings are out of the way")
            shot("iPad pick")
        }
        step("Cancel brings the settings back without picking") {
            app.buttons["pick.cancel"].tap()
            XCTAssert(app.navigationBars["Levels"].waitForExistence(timeout: 5))
            XCTAssertFalse(element("pick.bar").exists)
        }
        step("Pick the sand on the canvas: it turns white and the settings return") {
            app.buttons["levels.whitePoint"].tap()
            XCTAssert(element("pick.bar").waitForExistence(timeout: 5))
            // The canvas grows as the settings step aside.
            Thread.sleep(forTimeInterval: 0.6)
            at(700, 800).tap()
            waitIdle()
            XCTAssertFalse(element("pick.bar").exists)
            XCTAssert(app.navigationBars["Levels"].isHittable)
            // One pixel picked: the patch around it comes out nearly white.
            XCTAssertGreaterThan(stats(sand).mean.prefix(3).min() ?? 0, 0.9)
            ok("Levels")
        }
    }
}
