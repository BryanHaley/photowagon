import XCTest

/// Settings that change the image show the change as you make them: on a phone in a preview at
/// the top of the sheet, on an iPad on the canvas beside the settings. Also the Open page's
/// thumbnails and ☰ › Share….
final class LivePreviewTests: WalkthroughTestCase {

    var wide: Bool { app.windows.firstMatch.frame.width > 700 }

    func testFilterSettingsShowTheirResult() {
        var original = 0.0

        step("The Open page shows thumbnails") {
            app.buttons["home.open"].tap()
            let thumb = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'thumb.'")).firstMatch
            XCTAssert(thumb.waitForExistence(timeout: 10), "a file's thumbnail")
            let loaded = NSPredicate(format: "value == 'image'")
            expectation(for: loaded, evaluatedWith: thumb)
            waitForExpectations(timeout: 10)
            pickFile("beach")
            waitForCanvas()
            original = stats([200, 300, 1200, 600]).stddev[0]
        }

        step("Filter › Blur › Gaussian Blur: the image blurs while the settings are open") {
            menu("Filter", "Blur", "Gaussian Blur…")
            XCTAssert(app.navigationBars["Gaussian Blur"].waitForExistence(timeout: 5))
            waitIdle()
            if wide {
                XCTAssertFalse(app.otherElements["preview"].exists, "no preview: the canvas is beside the settings")
                XCTAssertGreaterThan(canvas.frame.width, app.windows.firstMatch.frame.width * 0.4, "the canvas stays in view: \(canvas.frame)")
                let (w, h) = docSize
                let frame = canvas.frame.insetBy(dx: -2, dy: -2)
                for p in [at(0, 0), at(w, h)] { XCTAssert(frame.contains(p.screenPoint), "the whole image shows: \(p.screenPoint) in \(canvas.frame)") }
            } else {
                XCTAssert(app.otherElements["preview"].exists, "a preview above the settings")
            }
            XCTAssertLessThan(stats([200, 300, 1200, 600]).stddev[0], original, "already blurred, with the starting radius")
        }

        step("Let go of the slider: a stronger blur") {
            let before = stats([200, 300, 1200, 600]).stddev[0]
            app.sliders["settings.radius.slider"].adjust(toNormalizedSliderPosition: 0.6)
            waitIdle()
            XCTAssertLessThan(stats([200, 300, 1200, 600]).stddev[0], before - 0.005, "blurrier")
            XCTAssertEqual((inspect["history"] as? [String])?.last, "Gaussian Blur", "one step, not one per try")
        }

        step("Cancel: the photo as it was") {
            app.buttons["Cancel"].firstMatch.tap()
            waitIdle()
            XCTAssertEqual(stats([200, 300, 1200, 600]).stddev[0], original, accuracy: 0.0005)
        }

        step("Again, OK: the blur stays") {
            menu("Filter", "Blur", "Gaussian Blur…")
            XCTAssert(app.navigationBars["Gaussian Blur"].waitForExistence(timeout: 5))
            replace(app.textFields["settings.radius"], with: "8\n")
            waitIdle()
            app.buttons["settings.run"].tap()
            waitIdle()
            XCTAssertLessThan(stats([200, 300, 1200, 600]).stddev[0], original - 0.01)
            let history = inspect["history"] as? [String] ?? []
            XCTAssertEqual(history.filter { $0 == "Gaussian Blur" }.count, 1, "\(history)")
        }

        step("☰ › Quick Share as PNG…: the share sheet") {
            app.buttons["menu"].tap()
            let share = app.collectionViews.buttons["Quick Share as PNG…"].firstMatch
            XCTAssert(share.waitForExistence(timeout: 5))
            share.tap()
            let sheet = app.otherElements["ActivityListView"].firstMatch
            XCTAssert(sheet.waitForExistence(timeout: 10), "the share sheet")
            let close = app.buttons["Close"].firstMatch
            if close.exists { close.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap() }
        }
    }

    func testLevels() {
        let area = [200, 300, 1200, 600]
        var original = 0.0

        step("Image › Adjustments › Levels: the histogram, the handles and the eyedroppers") {
            app.buttons["home.open"].tap()
            pickFile("beach")
            waitForCanvas()
            original = stats(area).mean[0]
            menu("Image", "Adjustments", "Levels…")
            XCTAssert(app.navigationBars["Levels"].waitForExistence(timeout: 5))
            XCTAssert(app.descendants(matching: .any)["levels.histogram"].exists)
            XCTAssert(app.segmentedControls["levels.channel"].exists, "RGB, Red, Green, Blue")
        }

        step("Drag the white handle left: brighter") {
            let input = app.descendants(matching: .any)["levels.input"]
            input.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: input.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)))
            waitIdle()
            let white = Double((app.textFields["levels.inWhite"].value as? String) ?? "") ?? 255
            XCTAssertLessThan(white, 200, "the field follows the handle")
            XCTAssertGreaterThan(stats(area).mean[0], original + 0.05)
        }

        step("Set White Point, then tap the sand in the preview: the sand turns white") {
            guard !wide else { return }
            let before = stats([600, 750, 800, 850]).mean
            app.swipeUp()
            app.buttons["levels.whitePoint"].tap()
            app.otherElements["preview"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
            waitIdle()
            let after = stats([600, 750, 800, 850]).mean
            XCTAssertGreaterThan(after.prefix(3).min() ?? 0, 0.95, "white, not just brighter: \(before) → \(after)")
            noErrorToast()
        }

        step("Auto, then OK: one Levels step") {
            if !app.buttons["levels.auto"].exists { app.descendants(matching: .any)["levels.histogram"].swipeDown() }
            app.buttons["levels.auto"].tap()
            waitIdle()
            app.buttons["settings.run"].tap()
            waitIdle()
            XCTAssertEqual((inspect["history"] as? [String])?.last, "Levels")
            XCTAssertNotEqual(stats(area).mean[0], original, accuracy: 0.005)
        }
    }
}
