import XCTest

/// A frame animation and an animated GIF: Window › Timeline, Create Frame Animation, layers from
/// several files, Make Frames From Layers, a new frame with its layer moved, playing, frame delays,
/// and File › Export › Save for Web as a looping GIF that opens again as frames.
final class AnimatedGifTests: WalkthroughTestCase {
    var animation: [String: Any] { probe("animation.info")["animation"] as? [String: Any] ?? [:] }
    var frames: [[String: Any]] { animation["frames"] as? [[String: Any]] ?? [] }
    var current: Int { animation["current"] as? Int ?? -1 }
    var element: (String) -> XCUIElement { { self.app.descendants(matching: .any)[$0].firstMatch } }

    /// Where the drop of frame 1 sits (document pixels): the frames are 640 × 400, centred.
    func dropTop(_ w: Double, _ h: Double) -> [Int] { [Int(w / 2) - 30, Int(h / 2) - 140, Int(w / 2) + 30, Int(h / 2) - 60] }

    func testAnimatedGif() {
        var (w, h) = (1920.0, 1080.0)

        step("Home › New file with the default settings") {
            app.buttons["home.new"].tap()
            XCTAssert(app.buttons["new.create"].waitForExistence(timeout: 10))
            app.buttons["new.create"].tap()
            waitForCanvas()
            (w, h) = docSize
            XCTAssertEqual(layers.count, 1, "the Background")
        }

        step("Window › Timeline shows the Timeline under the canvas") {
            menu("Window", "Timeline")
            XCTAssert(element("timeline").waitForExistence(timeout: 5))
            XCTAssert(app.buttons["timeline.create"].exists)
        }

        step("Create Frame Animation: the first frame") {
            app.buttons["timeline.create"].tap()
            XCTAssert(element("timeline.frame.0").waitForExistence(timeout: 5))
            XCTAssertEqual(frames.count, 1)
        }

        step("Layer › New › From Files: Select the eight drop frames and place them, a layer each") {
            menu("Layer", "New", "From Files…")
            XCTAssert(app.buttons["browser.select"].waitForExistence(timeout: 10))
            app.buttons["browser.select"].tap()
            let place = app.buttons["browser.placeChosen"]
            for i in 1...8 {
                let f = app.buttons["file.drop-\(i)"]
                show(f, "drop-\(i)")
                // Rows answer a moment late, and a tap while the list settles can be lost: tap
                // again if the count didn't go up.
                let ticked = NSPredicate(format: "label == %@", "Place \(i)")
                for _ in 0..<2 {
                    f.tap()
                    if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ticked, object: place)], timeout: 3) == .completed { break }
                }
            }
            expectation(for: NSPredicate(format: "label == 'Place 8'"), evaluatedWith: place)
            waitForExpectations(timeout: 10)
            place.tap()
            let end = Date().addingTimeInterval(30)
            while layers.count < 9, Date() < end { Thread.sleep(forTimeInterval: 0.5) }
            waitIdle()
            noErrorToast()
            XCTAssertEqual(layers.count, 9, "\(layers.map { $0["name"] ?? "" }) history \(inspect["history"] ?? "") redo \(inspect["historyRedo"] ?? "") docs \(probe("app.documents"))")
            XCTAssertEqual(layers.dropLast().last?["name"] as? String, "drop-1", "the first file at the bottom, above the Background")
        }

        step("Delete the Background layer: the canvas is transparent") {
            // Setup: the Layers walkthrough tests this control.
            app.buttons["layers"].tap()
            tapLayer("Background")
            let end = Date().addingTimeInterval(5)
            while activeLayerName != "Background", Date() < end { Thread.sleep(forTimeInterval: 0.3) }
            XCTAssertEqual(activeLayerName, "Background")
            // The panel's buttons sit at the top of the list: scroll back up to them.
            for _ in 0..<4 where !app.buttons["layers.delete"].isHittableSafe { layerRow("drop-8").swipeDown() }
            app.buttons["layers.delete"].tap()
            waitIdle()
            XCTAssertNil(layer(named: "Background"))
            XCTAssertEqual(stats([0, 0, 40, 40]).mean.last ?? 1, 0, accuracy: 0.001, "transparent")
            closeSheet()
        }

        step("Timeline menu › Make Frames From Layers: eight frames, one layer each") {
            pick(app.buttons["timeline.menu"], "Make Frames From Layers")
            XCTAssert(element("timeline.frame.7").waitForExistence(timeout: 5))
            XCTAssertEqual(frames.count, 8)
            XCTAssertEqual(layers.filter { $0["visible"] as? Bool == true }.map { $0["name"] as? String }, ["drop-1"], "frame 1 shows drop-1 only")
            XCTAssertGreaterThan(stats(dropTop(w, h)).mean.last ?? 0, 0.05, "frame 1: the drop near the top")
        }

        step("Duplicate frame 1 and move the drop down a bit, twice: the drop falls") {
            element("timeline.frame.0").tap()
            app.buttons["layers"].tap()
            tapLayer("drop-1")
            let end = Date().addingTimeInterval(5)
            while activeLayerName != "drop-1", Date() < end { Thread.sleep(forTimeInterval: 0.3) }
            closeSheet()
            tool(group: "Move", pick: "Move")
            for k in 1...2 {
                app.buttons["timeline.new"].tap()
                waitIdle()
                XCTAssertEqual(current, k)
                drag(doc: (w / 2, h / 2 - 100 + Double(k - 1) * 70), to: (w / 2, h / 2 - 30 + Double(k - 1) * 70))
                waitIdle()
            }
            XCTAssertEqual(frames.count, 10)
            XCTAssertLessThan(stats(dropTop(w, h)).mean.last ?? 1, 0.01, "frame 3: the drop has moved down")
            element("timeline.frame.0").tap()
            waitIdle()
            XCTAssertGreaterThan(stats(dropTop(w, h)).mean.last ?? 0, 0.05, "frame 1 keeps the drop at the top")
        }

        step("Play from the first frame, then Stop") {
            app.buttons["timeline.play"].tap()
            Thread.sleep(forTimeInterval: 0.6)
            XCTAssertNotEqual(current, 0, "playing")
            app.buttons["timeline.play"].tap()
            XCTAssertEqual(app.buttons["timeline.play"].label, "Play", "stopped")
        }

        step("Select All Frames, then a frame's delay › 0.2 s: every frame waits 0.2 s") {
            pick(app.buttons["timeline.menu"], "Select All Frames")
            pick(app.buttons["timeline.delay.0"], "0.2 s")
            waitIdle()
            XCTAssertEqual(frames.compactMap { ($0["delay"] as? Double).map { ($0 * 10).rounded() / 10 } }, Array(repeating: 0.2, count: 10))
        }

        step("File › Export › Save for Web: GIF, ten frames, looping Forever, saved as “water drop”") {
            menu("File", "Export", "Save for Web…")
            XCTAssert(app.navigationBars["Save for Web"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.segmentedControls["web.format"].buttons["GIF"].isSelected, true, "GIF for an animation")
            let estimate = element("web.estimate")
            expectation(for: NSPredicate(format: "label CONTAINS '10 frames'"), evaluatedWith: estimate)
            waitForExpectations(timeout: 60)
            replace(app.textFields["web.name"], with: "water drop\n")
            // The option, not the Timeline's own Looping button behind the sheet (also "Forever").
            show(app.buttons["web.loops"].firstMatch, "Looping Options").tap()
            let forever = app.collectionViews.buttons["Forever"]
            XCTAssert(forever.waitForExistence(timeout: 5))
            forever.tap()
            app.buttons["web.save"].tap()
            XCTAssert(toast("Saved water drop.gif") || app.buttons["statusBar"].exists)
            waitIdle()
            noErrorToast()
        }

        step("Open the GIF: ten frames of 0.2 s, looping forever, on a transparent background") {
            openFromHome()
            pickFile("water drop")
            XCTAssert(docOpen("water drop.gif", timeout: 20))
            waitIdle()
            XCTAssertEqual(frames.count, 10)
            XCTAssertEqual(animation["loops"] as? Int, 0, "forever")
            XCTAssertEqual((frames.first?["delay"] as? Double) ?? 0, 0.2, accuracy: 0.01)
            XCTAssertEqual(stats([0, 0, 40, 40]).mean.last ?? 1, 0, accuracy: 0.001, "transparent")
            XCTAssertGreaterThan(stats(dropTop(w, h)).mean.last ?? 0, 0.05, "the first frame: the drop at the top")
        }
    }
}

private extension XCUIElement {
    var isHittableSafe: Bool { exists && isHittable }
}
