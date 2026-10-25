import XCTest

/// Help: the first-time tour (it starts with the first document, each tip fits on screen, Help ›
/// Tutorial shows it again, Skip Tutorial ends it for good) and Help › Manual.
final class TutorialTests: WalkthroughTestCase {
    override var skipsTutorial: Bool { false }

    func testTutorial() {
        let titles = ["Tools", "Pick a Tool", "Tool Options", "Home", "Menus", "Undo and Redo", "Search", "History", "View", "Layers", "Colors"]
        let tip = { (title: String) in self.app.descendants(matching: .any)["tutorial.\(title)"] }
        step("Open a photo: the tour starts at the tools") {
            openSample("seaside")
            XCTAssert(tip("Tools").waitForExistence(timeout: 10), "the first tip")
        }

        step("Next through every tip: each fits on screen; Done ends it") {
            let screen = app.windows.firstMatch.frame
            for title in titles {
                let t = tip(title)
                XCTAssert(t.waitForExistence(timeout: 5), title)
                XCTAssert(screen.contains(t.frame), "\(title) at \(t.frame)")
                if title == "Tool Options" { XCTAssert(app.sliders.firstMatch.exists, "the tool's options show") }
                app.buttons["tutorial.next"].tap()
            }
            XCTAssertFalse(tip("Colors").waitForExistence(timeout: 2))
        }

        step("Help › Tutorial shows it again; Skip Tutorial ends it, and the next photo has none") {
            menu("Help", "Tutorial")
            XCTAssert(tip("Tools").waitForExistence(timeout: 5))
            app.buttons["tutorial.skip"].tap()
            XCTAssertFalse(tip("Tools").waitForExistence(timeout: 2))
            openSample("bee")
            XCTAssertFalse(tip("Tools").waitForExistence(timeout: 3))
        }

        step("Help › Manual: its contents, and its first picture loaded") {
            menu("Help", "Manual")
            let page = app.webViews.firstMatch
            XCTAssert(page.staticTexts["The Basics"].firstMatch.waitForExistence(timeout: 10), "the manual's contents")
            let picture = page.images["The Home screen"]
            XCTAssert(picture.waitForExistence(timeout: 5) && picture.frame.height > 100, "\(picture.frame)")
        }
    }

    /// The Menus tip: ☰ opens through it, and closing the menu moves the tour on.
    func testMenusTipOpensTheMenu() {
        step("The Menus tip: open ☰ through it, close it, the tour goes on") {
            openSample("seaside")
            for _ in 0..<4 { app.buttons["tutorial.next"].firstMatch.tap(); Thread.sleep(forTimeInterval: 0.6) }
            XCTAssert(app.descendants(matching: .any)["tutorial.Menus"].waitForExistence(timeout: 5), "the Menus tip")
            tapAt(app.buttons["menu"])
            XCTAssert(app.collectionViews.buttons.named("Crop and Rotate").waitForExistence(timeout: 5), "the menu, quick actions on top")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.9)).tap()
            XCTAssert(app.descendants(matching: .any)["tutorial.Undo and Redo"].waitForExistence(timeout: 5), "closing the menu moved the tour on")
        }
    }
}
