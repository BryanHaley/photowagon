import XCTest

/// Apple Vision's person and object masks, which only run on a real device. On a device the
/// app can't read the test bundle or the probe folder, so copy the photo into its Documents
/// first (`seaside.jpg`, with `xcrun devicectl device copy to`) and check the screenshots.
final class DeviceVisionTests: WalkthroughTestCase {
    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    /// Open `name` from Home, tapping again if the tap came while Home was appearing.
    private func openFile(_ name: String) {
        let file = app.buttons["file.\(name)"]
        for _ in 0..<3 where !file.exists {
            openFromHome()
            _ = file.waitForExistence(timeout: 5)
        }
        pickFile(name)
    }

    func testPersonMasks() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Vision needs a real device")
        #endif
        step("Open the seaside photo") {
            openFile("seaside")
            waitForCanvas()
        }
        step("Object Selection › Subject: the man is selected") {
            tool(group: "Object Selection", pick: "Object Selection")
            app.buttons["Subject"].firstMatch.tap()
            XCTAssert(app.buttons["Deselect"].waitForExistence(timeout: 60), "selected")
            XCTAssertFalse(app.staticTexts["No subject found"].waitForExistence(timeout: 3))
        }
        step("Select › Refine Selection… › Refine Hair: Vision's person matte near the edge") {
            menu("Select", "Refine Selection…")
            XCTAssert(app.buttons["refine.hair"].waitForExistence(timeout: 5), "Refine Hair in Refine Selection")
            app.buttons["refine.hair"].tap()
            waitIdle()
            app.buttons["settings.run"].tap()
            waitIdle()
            XCTAssertFalse(app.staticTexts["No person found to refine"].waitForExistence(timeout: 3), "Vision found the man")
            XCTAssert(app.buttons["Deselect"].exists, "still selected")
        }
        step("Properties › Remove Background: the man on transparency, zoomed in on his edge") {
            app.buttons["Deselect"].firstMatch.tap()
            menu("Window", "Properties")
            app.buttons["properties.removeBackground"].tap()
            waitIdle()
            closeSheet()
            app.buttons["layers"].tap()
            let mask = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'layer.mask.'")).firstMatch
            XCTAssert(mask.waitForExistence(timeout: 10), "the layer has a mask")
            closeSheet()
            for _ in 0..<3 { menu("View", "Zoom In") }
        }
    }

    /// Hard hair: tight wet curls by a busy window, and wavy red hair against the sky.
    func testHair() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Vision needs a real device")
        #endif
        for name in ["curls", "red-hair"] {
            step("Open \(name)") {
                openFile(name)
                waitForCanvas()
                tool(group: "Object Selection", pick: "Object Selection")
            }
            step("\(name): Subject, then Refine Selection › Refine Hair, shown as a layer mask") {
                app.buttons["Subject"].firstMatch.tap()
                XCTAssert(app.buttons["Deselect"].waitForExistence(timeout: 60), "selected")
                menu("Select", "Refine Selection…")
                XCTAssert(app.buttons["refine.hair"].waitForExistence(timeout: 5), "Refine Hair in Refine Selection")
                app.buttons["refine.hair"].tap()
                waitIdle()
                app.buttons["settings.run"].tap()
                waitIdle()
                XCTAssertFalse(app.staticTexts["No person found to refine"].waitForExistence(timeout: 3), "Vision found the person")
                app.buttons["Mask"].firstMatch.tap()
                waitIdle()
            }
            step("\(name): Remove Background instead") {
                app.buttons["undo"].firstMatch.tap()
                waitIdle()
                if app.buttons["Deselect"].exists { app.buttons["Deselect"].firstMatch.tap() }
                menu("Window", "Properties")
                app.buttons["properties.removeBackground"].tap()
                waitIdle()
                closeSheet()
            }
        }
    }
}
