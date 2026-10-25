import XCTest

/// Saving and exporting: recovery copies kept every few minutes and offered on Home after the app
/// ends, Export As at a size and several scales, and Quick Export of a layer. See
/// `docs/ios-walkthroughs/save-export.md` for each step and where it lives in the app.
final class SaveExportTests: WalkthroughTestCase {
    /// Home › Open lists `names` (files in the app's folder, without their extensions).
    func listed(_ names: [String]) -> [Bool] {
        openFromHome()
        let found = names.map { app.buttons["file.\($0)"].waitForExistence(timeout: 5) }
        app.buttons["Cancel"].firstMatch.tap()
        // Back to the open document.
        let back = app.buttons["home.workspace"]
        if back.waitForExistence(timeout: 3) { back.tap() }
        return found
    }

    func testSaveExport() {
        step("Home › Preferences (no document open): File Handling, Save Recovery Information Every Minute") {
            XCTAssert(app.buttons["home.preferences"].waitForExistence(timeout: 10))
            app.buttons["home.preferences"].tap()
            let picker = show(app.buttons["prefs.recovery"].firstMatch, "the recovery setting")
            XCTAssert(picker.label.contains("10"), "every 10 minutes at first: \(picker.label)")
            pick(picker, "Every Minute")
            XCTAssert(app.buttons["prefs.recovery"].label.contains("Every Minute"))
            closeSheet()
        }

        step("Open the photo, File › Export › Export As: width 800, sizes 1x and 2x, Export") {
            openSample("seaside")
            menu("File", "Export", "Export As…")
            replace(app.textFields["export.name"], with: "exported")
            replace(app.textFields["export.width"], with: "800")
            XCTAssertEqual(app.staticTexts["export.height"].label, "450 px", "the height follows")
            app.descendants(matching: .any)["export.scale.2"].firstMatch.tap()
            app.buttons["export.export"].tap()
            waitIdle()
            noErrorToast()
            XCTAssertEqual(listed(["exported", "exported@2x"]), [true, true])
        }

        step("Hold the layer › Quick Export as PNG: a file named after the layer") {
            app.buttons["layers"].tap()
            layerMenu("Background", "Quick Export as PNG")
            waitIdle()
            closeSheet()
            XCTAssertEqual(listed(["Background"]), [true])
        }

        var painted: [Double] = []
        step("Paint, leave PhotoWagon and end it, open it again: Home › Recovered brings the image back") {
            tool(group: "Brush", pick: "Brush")
            drag(doc: (200, 200), to: (700, 250))
            waitIdle()
            painted = stats([200, 180, 700, 270]).mean
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: 2)
            app.terminate()
            app.launchArguments = ["-uiTestProbe", probeFolder.path]
            app.launch()
            let recovered = app.buttons["recovered.seaside.jpg"]
            XCTAssert(recovered.waitForExistence(timeout: 10), "listed under Recovered")
            recovered.tap()
            waitForCanvas()
            waitIdle()
            let back = stats([200, 180, 700, 270]).mean
            for i in 0..<3 { XCTAssertEqual(back[i], painted[i], accuracy: 0.01, "the brush stroke is there") }
            XCTAssertFalse(app.buttons["recovered.seaside.jpg"].exists)
        }
    }
}
