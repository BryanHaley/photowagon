import XCTest

/// AI Remove: painting over something and removing a selection, the model's download offer, and
/// its row in Preferences.
/// The download itself runs only with `TEST_RUNNER_AI_DOWNLOAD=1` (about 200 MB); without it the
/// test says Not Now, unless the model is already on the simulator.
final class AIRemoveTests: WalkthroughTestCase {
    func testAIRemove() {
        let shorts = [680, 660, 720, 740]
        func red() -> Double { stats(shorts, of: "pixels", layer: "Background").mean[0] }
        let download = ProcessInfo.processInfo.environment["AI_DOWNLOAD"] == "1"
        var haveModel = true

        step("Open the photo, then the AI Remove tool") {
            openSample("seaside")
            tool(group: "Spot Repair Brush", pick: "AI Remove")
            XCTAssertLessThan(red(), 0.4, "the dark shorts")
        }

        step("Remove After Each Stroke off: paint over the person, then Commit") {
            app.buttons["Remove After Each Stroke"].tap()
            for x: Double in stride(from: 620, through: 780, by: 30) { drag(doc: (x, 330), to: (x, 810)) }
            for y: Double in [530, 570] { drag(doc: (540, y), to: (890, y)) }
            tapChip(app.buttons["Commit"])
            let offer = app.alerts["Download AI Remove?"]
            if offer.waitForExistence(timeout: 5) {
                XCTAssert(offer.staticTexts.matching(NSPredicate(format: "label CONTAINS 'MIT licence'")).count > 0, "the licence")
                if !download {
                    haveModel = false
                    offer.buttons["Not Now"].tap()
                    waitIdle()
                    XCTAssertLessThan(red(), 0.4, "nothing removed without the model")
                    return
                }
                offer.buttons["aiRemove.download"].tap()
            }
            let filled = expectation(for: NSPredicate { _, _ in red() > 0.5 }, evaluatedWith: nil)
            wait(for: [filled], timeout: 600)
            noErrorToast()
        }

        step("Rectangular Marquee round the boats; AI Remove › Remove Selection") {
            let hull = [825, 400, 880, 408]
            func white() -> Double { stats(hull, of: "pixels", layer: "Background").mean[0] }
            XCTAssertGreaterThan(white(), 0.7, "a white hull")
            tool(group: "Rectangular Marquee", pick: "Rectangular Marquee")
            drag(doc: (805, 300), to: (990, 418))
            tool(group: "Spot Repair Brush", pick: "AI Remove")
            tapChip(app.buttons["Remove Selection"])
            guard haveModel else {
                let offer = app.alerts["Download AI Remove?"]
                XCTAssert(offer.waitForExistence(timeout: 5), "the offer again")
                offer.buttons["Not Now"].tap()
                return
            }
            let gone = expectation(for: NSPredicate { _, _ in white() < 0.5 }, evaluatedWith: nil)
            wait(for: [gone], timeout: 120)
            noErrorToast()
        }

        step("Edit › Preferences › General…: AI › AI Remove Model") {
            menu("Edit", "Preferences", "General…")
            let row = show(app.descendants(matching: .any)["prefs.aiModel"].firstMatch, "AI Remove Model")
            XCTAssert(row.label.contains("Downloaded"), row.label)
        }
    }
}
