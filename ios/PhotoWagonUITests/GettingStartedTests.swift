import XCTest

/// Getting started: Home, files and saving, the workspace, menus, the status and options bars,
/// tools, panels, Free Transform, actions and a background swap, done through the app's own UI
/// only (never the command search). Each step attaches a screenshot and checks its result
/// through the test probe. Each part is its own class below, so parallel runs can spread the
/// parts across simulators (Xcode spreads classes, not methods).
class GettingStartedTests: WalkthroughTestCase {}

// MARK: - Home, workspace, menus, open/new/save, actions

final class WorkspaceAndFilesTests: GettingStartedTests {
    func testWorkspaceAndFiles() {
        step("Home screen at launch") {
            XCTAssert(app.buttons["home.new"].waitForExistence(timeout: 10))
            XCTAssert(app.staticTexts["Files you open or save show up here."].exists, "Recent starts empty")
        }

        step("Open a photo, change it, File › Save, close: it is listed under Recent") {
            app.buttons["home.open"].tap()
            pickFile("subject")
            waitForCanvas()
            tool(group: "Brush", pick: "Brush")
            drag(doc: (300, 300), to: (600, 400))
            menu("File", "Save")
            XCTAssert(toast("Saved subject.jpg"), "a one-layer JPEG saves in place")
            closeDoc("subject.jpg")
            XCTAssert(app.buttons["recent.subject.jpg"].waitForExistence(timeout: 10))
        }

        step("Reopen it from Recent; Home button and Workspace button") {
            app.buttons["recent.subject.jpg"].tap()
            waitForCanvas()
            XCTAssert(statusBar.contains("900 × 1200"), statusBar)
            app.buttons["home"].tap()
            XCTAssert(app.buttons["home.workspace"].waitForExistence(timeout: 5))
            backToWorkspace()
            XCTAssert(app.scrollViews["toolbar"].exists && app.buttons["layers"].exists && canvas.exists)
        }

        step("Home › New file: a preset, then 1920 × 1080 px named colors, sRGB, white, 8-bit") {
            goHome()
            app.buttons["home.new"].tap()
            XCTAssert(app.buttons["new.create"].waitForExistence(timeout: 10), "the New Document sheet")
            pick(app.buttons["new.preset"], "Landscape 6 × 4 in — 1800 × 1200 px")
            XCTAssertEqual(app.textFields["new.width"].value as? String, "1800", "the preset fills in its size")
            replace(app.textFields["new.name"], with: "colors")
            pick(app.buttons["new.units"], "Pixels")
            replace(app.textFields["new.width"], with: "1920")
            replace(app.textFields["new.height"], with: "1080")
            pick(app.buttons["new.profile"], "sRGB IEC61966-2.1")
            app.buttons["new.create"].tap()
            XCTAssert(docOpen("colors", timeout: 10))
            let i = inspect
            XCTAssertEqual(i["width"] as? Int, 1920)
            XCTAssertEqual(i["height"] as? Int, 1080)
            XCTAssertEqual(i["depth"] as? Int, 8)
            XCTAssertEqual(probe("document.pixel", ["x": 10, "y": 10])["value"] as? [Double], [1, 1, 1, 1], "white background")
        }

        step("Color: pick red and paint on a new layer, then paint on another") {
            newLayer()
            pickColor(containing: "red")
            XCTAssertGreaterThan(colors.fg.first ?? 0, 0.5, "red is the foreground: \(colors.fg)")
            drag(doc: (500, 300), to: (1200, 700))
            newLayer()
            drag(doc: (500, 700), to: (1200, 300))
            XCTAssertEqual(layers.count, 3)
        }

        step("Layers: put Layer 1 on top; Thumbnail Size: Large, None, then back to Medium") {
            selectLayer("Layer 1")
            app.buttons["layers"].tap()
            app.buttons["layers.up"].tap()
            XCTAssertEqual(layers.first?["name"] as? String, "Layer 1", "Layer 1 is on top")
            let thumb = app.descendants(matching: .any)["layer.thumb.Layer 1"].firstMatch
            XCTAssert(thumb.waitForExistence(timeout: 5))
            let medium = thumb.frame.width
            for (size, check) in [("Large", { thumb.frame.width > medium * 1.5 }), ("None", { !thumb.exists }), ("Medium", { abs(thumb.frame.width - medium) < 1 })] {
                pick(menu: "layers.menu", size)
                XCTAssert(check(), "\(size) thumbnails: \(thumb.exists ? thumb.frame.width : 0) (medium \(medium))")
            }
            closeSheet()
        }

        step("Status bar: Layer Count, then Current Tool follows the tool") {
            app.buttons["statusBar"].tap()
            app.buttons["Layer Count"].tap()
            XCTAssert(statusBar.contains("3 layers"), statusBar)
            app.buttons["statusBar"].tap()
            app.buttons["Current Tool"].tap()
            XCTAssert(statusBar.contains("Brush"), statusBar)
            tool(group: "Move", pick: "Move")
            XCTAssert(statusBar.contains("Move"), statusBar)
        }

        step("Options bar for the Brush: size and hardness") {
            tool(group: "Brush", pick: "Brush")
            option("Size", 0.7)
            option("Hardness", 0.2)
            let b = brush
            XCTAssertGreaterThan(b["size"] as? Double ?? 0, 100, "\(b)")
            XCTAssertLessThan(b["hardness"] as? Double ?? 1, 0.35, "\(b)")
            drag(doc: (200, 150), to: (1700, 150))
        }

        step("Options bar for the Gradient: a preset and Reverse") {
            tool(group: "Gradient", pick: "Gradient")
            app.buttons["gradient.preset"].firstMatch.tap()
            let preset = app.collectionViews.buttons["Black, White"].firstMatch
            XCTAssert(preset.waitForExistence(timeout: 5))
            preset.tap()
            app.buttons["Reverse"].tap()
            newLayer()
            drag(doc: (100, 540), to: (1820, 540))
            let (left, right) = (stats([0, 0, 300, 1080], of: "pixels"), stats([1620, 0, 1920, 1080], of: "pixels"))
            XCTAssertGreaterThan(lum(left.mean), lum(right.mean) + 0.5, "reversed: white to black")
            app.buttons["Reverse"].tap()
        }

        step("File › Save on a new document: the save sheet offers only formats that keep layers") {
            menu("File", "Save")
            XCTAssert(app.buttons["save.save"].waitForExistence(timeout: 15), "the save sheet opens")
            XCTAssertEqual(app.textFields["save.name"].value as? String, "colors", "named after the document")
            app.buttons["save.format"].tap()
            XCTAssert(app.buttons["Photoshop® (PSD)"].waitForExistence(timeout: 5))
            XCTAssert(app.buttons["PhotoCraft (default)"].exists && app.buttons["TIFF"].exists)
            XCTAssertFalse(app.buttons["JPEG"].exists, "no JPEG with several layers")
            app.buttons["Photoshop® (PSD)"].tap()
            app.buttons["save.save"].tap()
            XCTAssert(toast("Saved colors.psd"))
            XCTAssert(docOpen("colors.psd", timeout: 5), "the tab shows the file name")
        }

        step("Add text, double-tap the T to edit it; File › Save updates the file in place") {
            tool(group: "Horizontal Type", pick: "Horizontal Type")
            at(600, 500).tap()
            replace(app.textFields["prompt.field"], with: "link")
            app.buttons["prompt.ok"].firstMatch.tap()
            app.buttons["layers"].tap()
            let thumb = app.descendants(matching: .any)["layer.thumb.link"].firstMatch
            XCTAssert(thumb.waitForExistence(timeout: 5), "the text layer's T")
            thumb.doubleTap()
            let alert = app.alerts["Edit Text"]
            XCTAssert(alert.waitForExistence(timeout: 5), "double-tapping the T edits the text")
            replace(alert.textFields.firstMatch, with: "updated link")
            alert.buttons["OK"].firstMatch.tap()
            closeSheet()
            menu("File", "Save")
            XCTAssert(toast("Saved colors.psd"))
            XCTAssertFalse(app.buttons["save.save"].exists, "no save sheet the second time")
        }

        step("Close, Home › Recent: the layers and the edit were saved") {
            closeDoc("colors.psd")
            goHome()
            app.buttons["recent.colors.psd"].tap()
            XCTAssert(docOpen("colors.psd", timeout: 20))
            XCTAssertEqual(layers.count, 5, "Background, three painted layers and the text")
            XCTAssertEqual(typeInfo("updated link")["text"] as? String, "updated link")
        }

        step("File › Save a Copy… as JPEG with a quality: the document keeps its own file") {
            menu("File", "Save a Copy…")
            XCTAssert(app.buttons["save.save"].waitForExistence(timeout: 15))
            pick(app.buttons["save.format"], "JPEG")
            let quality = app.sliders["save.quality"]
            XCTAssert(quality.waitForExistence(timeout: 5), "JPEG has a quality")
            quality.slide(to: 0.5)
            app.buttons["save.save"].tap()
            XCTAssert(toast("Saved colors copy.jpg"))
            XCTAssert(docOpen("colors.psd", timeout: 0), "still colors.psd")
        }

        step("Window › Actions: record a new layer and a brush stroke, then stop") {
            menu("Window", "Actions")
            XCTAssert(app.buttons["actions.new"].waitForExistence(timeout: 10), "the Actions panel")
            app.buttons["actions.new"].tap()
            let alert = app.alerts["New Action"]
            XCTAssert(alert.waitForExistence(timeout: 5))
            replace(alert.textFields.firstMatch, with: "Stripe")
            alert.buttons["OK"].firstMatch.tap()
            XCTAssert(app.buttons["actions.stop"].waitForExistence(timeout: 5), "recording")
            closeSheet()
            XCTAssert(statusBar.contains("Recording Stripe"), statusBar)
            newLayer()
            tool(group: "Brush", pick: "Brush")
            drag(doc: (200, 900), to: (1700, 900))
            menu("Window", "Actions")
            app.buttons["actions.stop"].tap()
            XCTAssert(app.buttons["actions.record"].waitForExistence(timeout: 5), "stopped")
            let steps = probe("actions.get", ["action": "Stripe"])["steps"] as? [Any] ?? []
            XCTAssertEqual(steps.count, 2, "a new layer and a stroke: \(steps)")
        }

        step("Actions: Play runs the steps again") {
            let before = layers.count
            app.descendants(matching: .any)["action.Stripe"].firstMatch.tap()
            // A single tap selects once the double-tap (rename) time has passed.
            let play = app.buttons["actions.play"]
            expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: play)
            waitForExpectations(timeout: 5)
            play.tap()
            let end = Date().addingTimeInterval(10)
            while layers.count == before, Date() < end { Thread.sleep(forTimeInterval: 0.3) }
            XCTAssertEqual(layers.count, before + 1, "another layer, painted")
            closeSheet()
        }

        step("Home › Open a second document: both open as tabs") {
            openFromHome()
            pickFile("background")
            XCTAssert(docOpen("background.jpg", timeout: 20))
            XCTAssert(docOpen("colors.psd", timeout: 0) && docOpen("subject.jpg", timeout: 0))
        }
    }
}

// MARK: - Tools, panels, canvas, transform

final class ToolsPanelsAndTransformTests: GettingStartedTests {
    func testToolsPanelsAndTransform() {
        step("New 2000 × 2000 document; Current Tool in the status bar") {
            app.buttons["home.new"].tap()
            replace(app.textFields["new.name"], with: "tools")
            replace(app.textFields["new.width"], with: "2000")
            replace(app.textFields["new.height"], with: "2000")
            app.buttons["new.create"].tap()
            waitForCanvas()
            app.buttons["statusBar"].tap()
            app.buttons["Current Tool"].tap()
        }

        step("Hold a tool group: its tools with their names") {
            tool(group: "Blur", pick: "Blur")
            let group = app.descendants(matching: .any)["group.Blur"].firstMatch
            group.press(forDuration: 1.0)
            XCTAssert(app.buttons.named("Smudge").waitForExistence(timeout: 5), "the group's menu lists Smudge")
            XCTAssert(app.buttons.named("Sharpen").exists)
            app.buttons.named("Smudge").tap()
            XCTAssert(statusBar.contains("Smudge"), statusBar)
        }

        step("Type tool: tap, type, font, size 500 px, leading and tracking") {
            tool(group: "Horizontal Type", pick: "Horizontal Type")
            at(400, 600).tap()
            replace(app.textFields["prompt.field"], with: "Text")
            app.buttons["prompt.ok"].firstMatch.tap()
            replace(app.textFields["type.size"], with: "500")
            app.buttons["type.font"].firstMatch.tap()
            let font = app.buttons["American Typewriter"].firstMatch
            XCTAssert(font.waitForExistence(timeout: 5), "installed fonts are listed")
            font.tap()
            replace(app.textFields["type.leading"], with: "48")
            replace(app.textFields["type.tracking"], with: "200")
            let style = ((typeInfo("Text")["runs"] as? [[String: Any]])?.first?["style"] as? [String: Any]) ?? [:]
            XCTAssertEqual(style["size_pt"] as? Double, 500, "\(style)")
            XCTAssertEqual(style["font_family"] as? String, "American Typewriter")
            XCTAssertEqual(style["leading_pt"] as? Double, 48, "\(style)")
            XCTAssertEqual(style["tracking"] as? Double, 200, "\(style)")
        }

        step("Move tool: move the text, then Align to Canvas, centred both ways") {
            // From the toolbar: a Type option field still has the keyboard.
            tool(group: "Move", pick: "Move")
            let before = bounds("Text")
            drag(doc: (before[0] + before[2] / 2, before[1] + before[3] / 2), to: (before[0] + before[2] / 2 + 200, before[1] + before[3] / 2 + 300))
            XCTAssertEqual(bounds("Text")[0], before[0] + 200, accuracy: 20, "moved right")
            app.buttons["move.align"].tap()
            app.buttons["Horizontal Centers"].tap()
            app.buttons["move.align"].tap()
            app.buttons["Vertical Centers"].tap()
            let b = bounds("Text")
            XCTAssertEqual(b[0] + b[2] / 2, 1000, accuracy: 3, "centred across")
            XCTAssertEqual(b[1] + b[3] / 2, 1000, accuracy: 3, "centred down")
        }

        step("Move: Auto-Select picks the layer under the finger") {
            tool(group: "Brush", pick: "Brush")
            newLayer()
            drag(doc: (940, 1700), to: (1060, 1760))
            selectLayer("Text")
            tool(group: "Move", pick: "Move")
            app.buttons["Auto-Select"].tap()
            drag(doc: (1000, 1730), to: (1000, 1500))
            XCTAssertEqual(activeLayerName, "Layer 1", "Auto-Select picked the layer under the finger")
            XCTAssertLessThan(bounds("Layer 1")[1], 1650, "and moved it")
            app.buttons["Auto-Select"].tap()
        }

        step("Brush tips: Charcoal paints grainy, unlike Hard Round") {
            tool(group: "Brush", pick: "Brush")
            newLayer()
            brushTip("General", "Hard Round")
            option("Size", 0.4)
            drag(doc: (200, 300), to: (1800, 300))
            let hard = stats([200, 200, 1800, 400], of: "pixels")
            newLayer()
            brushTip("Dry Media", "Charcoal")
            option("Size", 0.4)
            drag(doc: (200, 500), to: (1800, 500))
            let charcoal = stats([200, 400, 1800, 600], of: "pixels")
            XCTAssertGreaterThan(charcoal.soft, hard.soft + 0.05, "charcoal has grain: \(charcoal.soft) vs \(hard.soft)")
        }

        step("Brush Tip › Import Brush Tips…: paint with the imported tip") {
            app.buttons["brush.tips"].firstMatch.tap()
            let item = app.buttons["Import Brush Tips…"].firstMatch
            XCTAssert(item.waitForExistence(timeout: 5))
            item.tap()
            pickFile("speckle")
            XCTAssert(toast("Added"), "imported speckle")
            brushTip("speckle", "Speckle")
            newLayer()
            drag(doc: (200, 800), to: (1800, 800))
            XCTAssertGreaterThan(stats([0, 730, 2000, 870], of: "pixels").mean.last ?? 0, 0.005, "Speckle painted")
            brushTip("General", "Hard Round")
        }

        step("Type: drag a text box, size 100, centre it") {
            tool(group: "Horizontal Type", pick: "Horizontal Type")
            drag(doc: (300, 1100), to: (1700, 1500))
            replace(app.textFields["prompt.field"], with: "Box")
            app.buttons["prompt.ok"].firstMatch.tap()
            // Return puts the keyboard away: it covers the options row.
            replace(app.textFields["type.size"], with: "100\n")
            app.segmentedControls["type.align"].buttons.element(boundBy: 1).tap()
            waitIdle()
            let info = typeInfo("Box")
            let align = ((info["paragraphs"] as? [[String: Any]])?.first?["style"] as? [String: Any])?["align"] as? String
            XCTAssertEqual(align, "Center")
            XCTAssertNotNil((info["shape"] as? [String: Any])?["Box"], "a text box: \(info["shape"] ?? "")")
        }

        step("Zoom tool: scrubby zoom right and left") {
            tool(group: "Hand", pick: "Zoom In")
            let before = zoomPercent
            drag(from: (0.4, 0.5), to: (0.8, 0.5))
            let zoomed = zoomPercent
            XCTAssertGreaterThan(zoomed, before)
            drag(from: (0.8, 0.5), to: (0.4, 0.5))
            XCTAssertLessThan(zoomPercent, zoomed)
        }

        step("Pinch to zoom, Hand tool to move around, Fit on Screen") {
            let before = zoomPercent
            canvas.pinch(withScale: 2.5, velocity: 2)
            XCTAssertGreaterThan(zoomPercent, before, "pinch zooms in")
            tool(group: "Hand", pick: "Hand")
            let p = probe("app.docToCanvas", ["x": 1000, "y": 1000])
            drag(from: (0.5, 0.5), to: (0.2, 0.3))
            let q = probe("app.docToCanvas", ["x": 1000, "y": 1000])
            XCTAssertLessThan(q["x"] as? Double ?? 0, (p["x"] as? Double ?? 0) - 50, "the view moved")
            menu("View", "Fit on Screen")
            XCTAssertLessThan(zoomPercent, 60, "fit on screen")
        }

        step("Spot Repair Brush removes a blemish") {
            selectLayer("Background")
            tool(group: "Brush", pick: "Brush")
            option("Size", 0.35)
            foreground(black: true)
            drag(doc: (1500, 1880), to: (1515, 1885))
            let spot = [1470, 1850, 1550, 1915]
            XCTAssertLessThan(lum(stats(spot, of: "pixels").mean), 0.8, "a dark spot")
            tool(group: "Spot Repair Brush", pick: "Spot Repair Brush")
            option("Size", 0.45)
            drag(doc: (1490, 1880), to: (1525, 1885))
            waitIdle()
            noErrorToast()
            XCTAssertGreaterThan(lum(stats(spot, of: "pixels").mean), 0.9, "healed")
        }

        step("Layers: hide and show with the eye, opacity") {
            app.buttons["layers"].tap()
            show(app.buttons["layer.eye.Layer 1"].firstMatch, "Layer 1's eye").tap()
            XCTAssertEqual(layer(named: "Layer 1")?["visible"] as? Bool, false)
            show(app.buttons["layer.eye.Layer 1"].firstMatch, "Layer 1's eye").tap()
            XCTAssertEqual(layer(named: "Layer 1")?["visible"] as? Bool, true)
            app.descendants(matching: .any)["layer.Layer 1"].firstMatch.tap()
            // The list scrolls to the layers; Opacity is above them.
            let opacity = show(app.sliders["layers.opacity"].firstMatch, "Opacity")
            // Checked on the layer: iOS 27 can report the slider's own position late.
            for _ in 0..<3 where abs((layer(named: "Layer 1")?["opacity"] as? Double ?? 0) - 0.5) > 0.04 {
                opacity.slide(to: 0.5)
                Thread.sleep(forTimeInterval: 0.6)
            }
            XCTAssertEqual(layer(named: "Layer 1")?["opacity"] as? Double ?? 0, 0.5, accuracy: 0.06)
            closeSheet()
        }

        step("History: tap a step to go back; then the undo and redo buttons") {
            app.buttons["history"].tap()
            historyBackOne()
            XCTAssertEqual(inspect["canRedo"] as? Bool, true, "a step back")
            closeSheet()
            app.buttons["redo"].tap()
            XCTAssertEqual(inspect["canRedo"] as? Bool, false)
            let steps = (inspect["history"] as? [String])?.count ?? 0
            app.buttons["undo"].tap()
            XCTAssertEqual((inspect["history"] as? [String])?.count, steps - 1)
            app.buttons["redo"].tap()
            XCTAssertEqual((inspect["history"] as? [String])?.count, steps)
        }

        step("View › Canvas Color › Light Gray") {
            let corner = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.02))
            menu("View", "Canvas Color", "Light Gray")
            XCTAssertEqual(screenColor(corner).first ?? 0, 0.75, accuracy: 0.05, "light gray around the image")
        }

        step("Open a photo, unlock it; Edit › Free Transform › Flip Horizontal") {
            openFromHome()
            pickFile("subject")
            XCTAssert(docOpen("subject.jpg", timeout: 20))
            // The photo opens as a locked Background: unlock it first, as in Photoshop.
            app.buttons["layers"].tap()
            showLayer("Background")
            show(app.buttons["layer.lock.Background"].firstMatch, "the Background's lock").tap()
            closeSheet()
            let (l, r) = (stats([0, 0, 300, 1200]), stats([600, 0, 900, 1200]))
            XCTAssertGreaterThan(abs(lum(l.mean) - lum(r.mean)), 0.01, "the photo isn't symmetric")
            menu("Edit", "Free Transform")
            XCTAssert(app.buttons["Commit"].waitForExistence(timeout: 5))
            tapChip(app.buttons["Flip Horizontal"])
            tapChip(app.buttons["Commit"].firstMatch)
            waitIdle()
            XCTAssertEqual(lum(stats([0, 0, 300, 1200]).mean), lum(r.mean), accuracy: 0.01, "left and right swapped")
            app.buttons["undo"].tap()
        }

        step("Reference point: a preset corner, scale from it keeping the proportions") {
            // Zoomed out, so the box's handles are inside the screen's edges.
            menu("View", "Zoom Out")
            menu("Edit", "Free Transform")
            XCTAssert(app.buttons["Commit"].waitForExistence(timeout: 5))
            tapChip(app.buttons["Reference Point"].firstMatch)
            app.buttons["Top Right"].tap()
            tapChip(app.buttons["Scale From Reference Point"].firstMatch)
            drag(doc: (900, 1200), to: (720, 960))
            tapChip(app.buttons["Commit"].firstMatch)
            waitIdle()
            let b = bounds("Layer 0")
            XCTAssertLessThan(b[2], 850, "smaller: \(b)")
            XCTAssertEqual(b[2] / b[3], 0.75, accuracy: 0.02, "kept 3:4: \(b)")
            XCTAssertEqual(b[0] + b[2], 900, accuracy: 4, "the right edge stayed: \(b)")
            XCTAssertEqual(b[1], 0, accuracy: 4, "the top stayed: \(b)")
            app.buttons["undo"].tap()
        }

        step("Reference point: drag it, then rotate outside the box around it") {
            let (pivot, far) = ([55, 55, 65, 65], [700, 900, 800, 1000])
            let (pivotBefore, farBefore) = (lum(stats(pivot, of: "pixels").mean), lum(stats(far, of: "pixels").mean))
            menu("Edit", "Free Transform")
            XCTAssert(app.buttons["Commit"].waitForExistence(timeout: 5))
            tapChip(app.buttons["Scale From Reference Point"].firstMatch)
            drag(doc: (450, 600), to: (60, 60))
            drag(doc: (1050, 1000), to: (900, 1300))
            tapChip(app.buttons["Commit"].firstMatch)
            waitIdle()
            noErrorToast()
            XCTAssertEqual(lum(stats(pivot, of: "pixels").mean), pivotBefore, accuracy: 0.03, "the reference point stayed put")
            XCTAssertGreaterThan(abs(lum(stats(far, of: "pixels").mean) - farBefore), 0.01, "the rest turned")
        }
    }
}

// MARK: - Keyboard shortcuts (run on an iPad)

final class KeyboardShortcutsTests: GettingStartedTests {
    /// On the iPhone simulator XCUITest's ⌘ keys stop arriving once a menu has been opened (on
    /// an iPad they keep working), so this runs on an iPad simulator.
    func testKeyboardShortcuts() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "run on an iPad simulator: on the iPhone simulator ⌘ keys stop arriving after a menu")

        step("New 2000 × 2000 document") {
            app.buttons["home.new"].tap()
            replace(app.textFields["new.width"], with: "2000")
            replace(app.textFields["new.height"], with: "2000")
            app.buttons["new.create"].tap()
            waitForCanvas()
        }

        step("⌘+ and ⌘− zoom, ⌘0 fits") {
            menu("View", "Fit on Screen")
            let fit = zoomPercent
            key("=", .command)
            XCTAssertGreaterThan(zoomPercent, fit, "⌘+")
            key("-", .command)
            key("-", .command)
            XCTAssertLessThan(zoomPercent, fit, "⌘−")
            key("0", .command)
            XCTAssertEqual(zoomPercent, fit, accuracy: 1, "⌘0")
        }

        step("⌘ held: a temporary Auto-Select") {
            key("b")
            for x in [500.0, 1500] {
                newLayer()
                drag(doc: (x - 60, 1000), to: (x + 60, 1060))
            }
            selectLayer("Layer 1")
            key("v")
            XCUIElement.perform(withKeyModifiers: .command) {
                drag(doc: (1500, 1030), to: (1500, 800))
            }
            XCTAssertEqual(activeLayerName, "Layer 2", "⌘ held picks the layer under the finger")
            XCTAssertLessThan(bounds("Layer 2")[1], 950, "and moves it")
        }

        step("⌘Z undoes, ⇧⌘Z redoes") {
            let steps = (inspect["history"] as? [String])?.count ?? 0
            key("z", .command)
            XCTAssertEqual((inspect["history"] as? [String])?.count, steps - 1, "⌘Z")
            key("z", [.command, .shift])
            XCTAssertEqual((inspect["history"] as? [String])?.count, steps, "⇧⌘Z")
        }

        step("⌘T, then ⇧ while rotating: 15° steps") {
            openFromHome()
            pickFile("subject")
            waitForCanvas()
            // A locked Background: unlock it first, as in Photoshop.
            app.buttons["layers"].tap()
            showLayer("Background")
            show(app.buttons["layer.lock.Background"].firstMatch, "the Background's lock").tap()
            closeSheet()
            key("t", .command)
            XCTAssert(app.buttons["Commit"].waitForExistence(timeout: 5), "⌘T starts Free Transform")
            XCUIElement.perform(withKeyModifiers: .shift) {
                drag(doc: (1050, 100), to: (1050, 500))
            }
            tapChip(app.buttons["Commit"].firstMatch)
            waitIdle()
            let w = bounds("Layer 0")[2]
            let fits = stride(from: 15.0, through: 75, by: 15).contains { a in
                let t = a * .pi / 180
                return abs(900 * cos(t) + 1200 * sin(t) - w) < 6
            }
            XCTAssert(fits, "a multiple of 15°: width \(w)")
        }
    }
}

// MARK: - Change the background; remove a person

final class BackgroundSwapTests: GettingStartedTests {
    func testBackgroundSwap() {
        step("Home › Open the subject") {
            app.buttons["home.open"].tap()
            pickFile("subject")
            waitForCanvas()
            XCTAssert(statusBar.contains("900 × 1200"), statusBar)
        }

        step("File › Place Embedded… the new background, scaled from the centre") {
            menu("File", "Place Embedded…")
            pickFile("background")
            XCTAssert(app.buttons["Commit"].waitForExistence(timeout: 20))
            tapChip(app.buttons["Scale From Reference Point"].firstMatch)
            drag(doc: (900, 937), to: (1150, 1150))
            tapChip(app.buttons["Commit"].firstMatch)
            waitIdle()
            XCTAssertEqual(layers.count, 2)
            let b = bounds("background")
            if b.count == 4 {
                XCTAssertGreaterThan(b[2], 900, "bigger than the photo: \(b)")
                XCTAssertEqual(b[0] + b[2] / 2, 450, accuracy: 6, "still centred: \(b)")
            }
        }

        step("Layers: unlock the Background, put the new background under it, rename it subject") {
            app.buttons["layers"].tap()
            show(app.buttons["layer.lock.Background"].firstMatch, "the Background's lock").tap()
            let placed = app.descendants(matching: .any)["layer.background"]
            XCTAssert(placed.waitForExistence(timeout: 5), "the placed layer is named after its file")
            placed.tap()
            app.buttons["layers.down"].tap()
            let subject = app.descendants(matching: .any)["layer.Layer 0"]
            XCTAssert(subject.waitForExistence(timeout: 5), "the unlocked Background is Layer 0")
            subject.doubleTap()
            let alert = app.alerts["Rename Layer"]
            XCTAssert(alert.waitForExistence(timeout: 5), "double-tapping a layer name renames it")
            replace(alert.textFields.firstMatch, with: "subject")
            alert.buttons["OK"].firstMatch.tap()
            XCTAssert(app.descendants(matching: .any)["layer.subject"].waitForExistence(timeout: 5))
            closeSheet()
            XCTAssertEqual(layers.map { $0["name"] as? String }, ["subject", "background"])
        }

        step("Window › Properties › Remove Background") {
            selectLayer("subject")
            menu("Window", "Properties")
            app.buttons["properties.removeBackground"].tap()
            waitIdle()
            closeSheet()
            XCTAssertEqual(layer(named: "subject")?["hasMask"] as? Bool, true)
            XCTAssertGreaterThan(stats([380, 450, 520, 800], of: "mask", layer: "subject").mean.first ?? 0, 0.8, "the dog is kept")
            XCTAssertLessThan(stats([0, 900, 120, 1200], of: "mask", layer: "subject").mean.first ?? 1, 0.2, "the grass is hidden")
        }

        step("Select the new background, Filter › Blur › Gaussian Blur… 16 px") {
            let sharp = stats([0, 0, 900, 300], of: "pixels", layer: "background").stddev
            selectLayer("background")
            menu("Filter", "Blur", "Gaussian Blur…")
            let radius = app.textFields.firstMatch
            XCTAssert(radius.waitForExistence(timeout: 5))
            replace(radius, with: "16")
            app.buttons["settings.run"].tap()
            waitIdle()
            let soft = stats([0, 0, 900, 300], of: "pixels", layer: "background").stddev
            XCTAssertLessThan(lum(soft), lum(sharp), "softer")
        }

        step("Select the mask, Smudge at strength 50, [ and ] for size, push the edge in") {
            app.buttons["layers"].tap()
            let mask = app.descendants(matching: .any)["layer.mask.subject"].firstMatch
            XCTAssert(mask.waitForExistence(timeout: 5), "the subject has a mask")
            mask.tap()
            closeSheet()
            XCTAssertEqual(inspect["maskTarget"] as? Bool, true)
            tool(group: "Blur", pick: "Smudge")
            option("Strength", percent: 50)
            let strength = Int((app.sliders["option.Strength"].value as? String ?? "").dropLast()) ?? 0
            XCTAssertEqual(strength, 50, accuracy: 1)
            let size = brush["size"] as? Double ?? 0
            key("]")
            XCTAssertGreaterThan(brush["size"] as? Double ?? 0, size)
            // The dog's left edge halfway down: where the mask turns from hidden to kept.
            var edge = 0.0
            for x in stride(from: 40.0, through: 440, by: 20) where (stats([Int(x), 690, Int(x) + 20, 710], of: "mask", layer: "subject").mean.first ?? 0) > 0.5 {
                edge = x
                break
            }
            XCTAssertGreaterThan(edge, 40, "found the edge")
            let before = stats([Int(edge) - 40, 640, Int(edge) + 40, 760], of: "mask", layer: "subject").mean.first ?? 0
            drag(doc: (edge - 60, 700), to: (edge + 30, 700))
            let after = stats([Int(edge) - 40, 640, Int(edge) + 40, 760], of: "mask", layer: "subject").mean.first ?? 0
            XCTAssertLessThan(after, before - 0.01, "the hidden part was pushed in: \(before) → \(after)")
        }

        step("Object Selection on the person in yellow (hold: Object Finder shows it, lift: selects it), then Quick Fill") {
            openFromHome()
            pickFile("beach")
            XCTAssert(docOpen("beach.jpg", timeout: 20))
            let (person, near) = ([495, 413, 551, 552], [420, 413, 476, 552])
            XCTAssertGreaterThan(stats(person).stddev.first ?? 0, 0.22, "a person stands there")
            tool(group: "Object Selection", pick: "Object Selection")
            XCTAssert(app.buttons["Object Finder"].exists && app.buttons["Show All Objects"].exists, "Object Finder options")
            // Held until the highlight shows (the engine looks for the object in the simulator).
            at(523, 470).press(forDuration: 6)
            waitIdle()
            XCTAssert(app.buttons["Quick Fill"].waitForExistence(timeout: 10), "something was selected")
            let shown = probe("app.objectHighlight")["last"] as? [Double] ?? []
            XCTAssert(shown.count == 4 && shown[0] > 470 && shown[2] < 600, "the hold highlighted that person: \(shown)")
            let sel = inspect["selectionBounds"] as? [Double] ?? []
            XCTAssert(sel.count == 4 && sel[0] > 470 && sel[0] + sel[2] < 600 && sel[3] > 100, "that person only, head to feet: \(sel)")
            app.buttons["Quick Fill"].tap()
            waitIdle()
            noErrorToast()
            let (after, around) = (stats(person), stats(near))
            XCTAssertLessThan(after.stddev.first ?? 1, 0.2, "the person is gone")
            XCTAssertEqual(lum(after.mean), lum(around.mean), accuracy: 0.05, "filled like the beach around it")
        }

        step("Lasso the leftovers, then Quick Fill again") {
            // A test can only drag in straight lines: draw the loop with the Polygonal Lasso.
            tool(group: "Lasso", pick: "Polygonal Lasso")
            for (x, y) in [(485.0, 405.0), (561.0, 405.0), (561.0, 562.0), (485.0, 562.0), (485.0, 405.0)] {
                at(x, y).tap()
            }
            if app.buttons["Commit"].exists { tapChip(app.buttons["Commit"].firstMatch) }
            XCTAssert(app.buttons["Quick Fill"].waitForExistence(timeout: 10))
            app.buttons["Quick Fill"].tap()
            waitIdle()
            noErrorToast()
            XCTAssertLessThan(stats([495, 413, 551, 552]).stddev.first ?? 1, 0.2)
        }
    }
}
