import XCTest

/// Artboards: a new document made of artboards, Layer › New › Artboard, the Artboard tool (drawing
/// a board, its "+" buttons, dragging a board, size presets and orientation), renaming, a layer per
/// board, moving and copying layers between boards, View › New Guide Layout on the selected board,
/// saved size presets, colour labels, a board's Export As and File › Export › Artboards to Files.
class ArtboardsTests: WalkthroughTestCase {
    /// The artboards, top first: name and board [x, y, width, height].
    var boards: [(name: String, rect: [Double])] {
        layers.compactMap { l in
            guard let a = l["artboard"] as? [String: Any], let r = a["rect"] as? [Double], let n = l["name"] as? String else { return nil }
            return (n, r)
        }
    }

    func board(_ name: String) -> [Double] { boards.first { $0.name == name }?.rect ?? [] }

    /// The artboard holding layer `name`.
    func boardOf(_ name: String) -> String? {
        layers.first { b in (b["children"] as? [[String: Any]] ?? []).contains { $0["name"] as? String == name } }?["name"] as? String
    }

    /// Home › New file: Social Portrait (1080 × 1350) with Artboards on.
    func newArtboardDocument() {
        app.buttons["home.new"].tap()
        XCTAssert(app.buttons["new.create"].waitForExistence(timeout: 10))
        pick(app.buttons["new.preset"], "Social Portrait — 1080 × 1350 px")
        flip("new.artboards")
        app.buttons["new.create"].tap()
        waitForCanvas()
    }

    /// Tap the canvas `dx`, `dy` points from document pixel (`x`, `y`).
    func tapNear(_ x: Double, _ y: Double, dx: Double = 0, dy: Double = 0) {
        at(x, y).withOffset(CGVector(dx: dx, dy: dy)).tap()
    }

    /// In the text prompt in front: replace its text with `text`, then tap its right-hand button.
    func answerPrompt(_ text: String, _ button: String) {
        let alert = app.alerts.firstMatch
        XCTAssert(alert.waitForExistence(timeout: 5), "a prompt")
        let field = alert.textFields.firstMatch
        Thread.sleep(forTimeInterval: 1)
        // Its text starts selected: typing replaces it. Emptying the field first makes iOS show
        // the prompt again.
        field.typeText(text)
        Thread.sleep(forTimeInterval: 0.5)
        // SwiftUI lists each button twice; only one has a frame on screen.
        let buttons = app.alerts.buttons.matching(NSPredicate(format: "label == %@", button)).allElementsBoundByIndex
        if let b = buttons.first(where: { !$0.frame.isEmpty && app.windows.firstMatch.frame.contains($0.frame) }) { tapAt(b) }
        let gone = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: gone, object: alert)], timeout: 5), .completed, "the prompt closed")
    }

    /// The Move tool's Copy While Moving switch (a moved layer's box is committed first: it
    /// takes the options bar).
    func copyWhileMoving() {
        let commit = app.buttons["Commit"]
        if commit.exists { commit.tap() }
        let toggle = app.buttons.matching(NSPredicate(format: "label == 'Copy While Moving'")).firstMatch
        XCTAssert(toggle.waitForExistence(timeout: 5), "Copy While Moving")
        toggle.tap()
    }

    func waitFor(_ what: String, _ done: () -> Bool) {
        let end = Date().addingTimeInterval(10)
        while !done(), Date() < end { Thread.sleep(forTimeInterval: 0.3) }
        XCTAssert(done(), what)
    }
}

final class ArtboardsMakeTests: ArtboardsTests {
    func testMakeArtboards() {
        step("Home › New file: Social Portrait with Artboards on makes one artboard") {
            newArtboardDocument()
            XCTAssertEqual(boards.map(\.name), ["Artboard 1"])
            XCTAssertEqual(board("Artboard 1"), [0, 0, 1080, 1350])
            XCTAssertEqual(boardOf("Layer 1"), "Artboard 1", "its own layer")
            XCTAssertEqual((inspect["history"] as? [String])?.count ?? 0, 1, "nothing to undo but opening it")
        }

        step("Layer › New › Artboard: a square board named Banner beside it") {
            menu("Layer", "New", "Artboard…")
            XCTAssert(app.textFields["artboard.name"].waitForExistence(timeout: 5))
            replace(app.textFields["artboard.name"], with: "Banner")
            pick(app.buttons["artboard.size"], "Social Square (1080 × 1080)")
            app.buttons["artboard.ok"].tap()
            waitFor("a second board") { boards.count == 2 }
            let b = board("Banner")
            XCTAssertEqual(Array(b.dropFirst(2)), [1080, 1080])
            XCTAssertGreaterThanOrEqual(b.first ?? 0, 1080, "beside the first board, not on it")
            noErrorToast()
        }

        step("Artboard tool: drag on the empty space draws a board") {
            menu("View", "Zoom Out")
            tool(group: "Frame", pick: "Artboard")
            drag(doc: (100, 1500), to: (700, 2100))
            waitFor("a third board") { boards.count == 3 }
            let r = board("Artboard 2")
            XCTAssertEqual(r.first ?? 0, 100, accuracy: 30)
            XCTAssertGreaterThan(r.count == 4 ? r[2] : 0, 400)
        }

        step("Artboard tool: the + on the right of the board adds one beside it") {
            let r = board("Artboard 2")
            tapNear(r[0] + r[2], r[1] + r[3] / 2, dx: 30)
            waitFor("a fourth board") { boards.count == 4 }
            let added = boards.first { !["Artboard 1", "Banner", "Artboard 2"].contains($0.name) }?.rect ?? []
            XCTAssertEqual(Array(added.dropFirst(2)), Array(r.dropFirst(2)), "the same size")
            XCTAssertGreaterThan(added.first ?? 0, r[0] + r[2], "to its right")
        }

        step("Artboard tool: dragging a board moves it") {
            let before = board("Artboard 2")
            drag(doc: (before[0] + 200, before[1] + 200), to: (before[0] + 200, before[1] + 400))
            waitFor("the board moved down") { (board("Artboard 2").dropFirst().first ?? 0) > before[1] + 100 }
            XCTAssertEqual(boards.count, 4, "moved, not a new board")
        }

        step("Layers panel: double-tap a board's name to rename it") {
            app.buttons["layers"].tap()
            let row = showLayer("Banner")
            row.doubleTap()
            answerPrompt("Cover", "OK")
            waitFor("renamed") { boards.contains { $0.name == "Cover" } }
        }

        step("Layers panel: New Layer with Artboard 1 selected goes into Artboard 1") {
            tapLayer("Artboard 1")
            app.buttons["layers.new"].tap()
            waitFor("Layer 2 inside the board") { boardOf("Layer 2") == "Artboard 1" }
            closeSheet()
        }

        step("Brush on Layer 2 inside Artboard 1") {
            tool(group: "Brush", pick: "Brush")
            drag(doc: (300, 600), to: (700, 600))
            waitIdle()
            XCTAssertLessThan(stats([300, 560, 700, 640]).mean.first ?? 1, 0.6, "painted")
        }

        step("Move tool: drag the stroke onto Cover puts its layer in Cover") {
            menu("View", "Fit on Screen")
            tool(group: "Move", pick: "Move")
            let cover = board("Cover")
            // To one side of the middle: the box's centre point sits there.
            drag(doc: (400, 600), to: (cover[0] + 300, 600))
            waitIdle()
            waitFor("Layer 2 moved into Cover") { boardOf("Layer 2") == "Cover" }
            XCTAssertLessThan(stats([Int(cover[0]) + 250, 560, Int(cover[0]) + 550, 640]).mean.first ?? 1, 0.6, "the stroke shows on Cover")
        }

        step("Move tool with Copy While Moving: drag a copy back onto Artboard 1") {
            copyWhileMoving()
            let cover = board("Cover")
            drag(doc: (cover[0] + 300, 600), to: (400, 600))
            waitIdle()
            copyWhileMoving()
            waitFor("the copy is in Artboard 1") { boardOf("Layer 2 copy") == "Artboard 1" }
            XCTAssertEqual(boardOf("Layer 2"), "Cover", "the original stays")
        }
    }
}

final class ArtboardsExportTests: ArtboardsTests {
    func testSizesGuidesLabelsAndExport() {
        step("Home › New file with Artboards; Artboard tool + adds a second board") {
            newArtboardDocument()
            menu("View", "Zoom Out")
            tool(group: "Frame", pick: "Artboard")
            tapNear(1080, 675, dx: 30)
            waitFor("two boards") { boards.count == 2 }
        }

        step("Artboard tool: Size › Social Story sets the selected board to 1080 × 1920") {
            pick(menu: "artboard.sizes", "Social Story (1080 × 1920)")
            waitFor("resized") { Array(board("Artboard 2").dropFirst(2)) == [1080, 1920] }
        }

        step("Artboard tool: Landscape turns it to 1920 × 1080") {
            app.buttons["Landscape"].tap()
            waitFor("landscape") { Array(board("Artboard 2").dropFirst(2)) == [1920, 1080] }
        }

        step("New file › Save Preset: Card, 800 × 600, offered by the Artboard tool") {
            app.buttons["home"].tap()
            app.buttons["home.new"].tap()
            XCTAssert(app.buttons["new.create"].waitForExistence(timeout: 10))
            replace(app.textFields["new.width"], with: "800")
            replace(app.textFields["new.height"], with: "600")
            app.buttons["new.savePreset"].tap()
            answerPrompt("Card", "Save")
            app.navigationBars.buttons["Cancel"].firstMatch.tap()
            backToWorkspace()
            pick(menu: "artboard.sizes", "Card (800 × 600)")
            waitFor("the saved size") { Array(board("Artboard 2").dropFirst(2)) == [800, 600] }
        }

        step("Tap Artboard 1's name to select it; View › New Guide Layout on the selected board") {
            tapNear(5, 0, dy: -9)
            waitFor("Artboard 1 selected") { activeLayerName == "Artboard 1" }
            menu("View", "New Guide Layout…")
            let columns = app.textFields["settings.columns"]
            XCTAssert(columns.waitForExistence(timeout: 5))
            replace(columns, with: "3")
            pick(app.buttons["settings.target"], "Selected artboards")
            app.buttons["settings.run"].tap()
            let guides = { (self.inspect["guides"] as? [String: Any])?["vertical"] as? [Double] ?? [] }
            waitFor("column guides") { guides().count >= 2 }
            XCTAssert(guides().allSatisfy { $0 >= 0 && $0 <= 1080 }, "on Artboard 1 only: \(guides())")
        }

        step("Layers panel: hold Artboard 2 › Color › Red labels it") {
            app.buttons["layers"].tap()
            layerMenu("Artboard 2", "Color")
            let red = app.buttons["Red"]
            XCTAssert(red.waitForExistence(timeout: 5))
            red.tap()
            waitFor("red label") { self.layers.first { $0["name"] as? String == "Artboard 2" }?["labelColor"] as? String == "red" }
        }

        step("Layers panel: hold Artboard 2 › Export As: a JPEG of that board") {
            layerMenu("Artboard 2", "Export As…")
            XCTAssert(app.buttons["artboards.export"].waitForExistence(timeout: 5))
            pick(app.buttons["artboards.format"], "JPEG")
            app.buttons["artboards.export"].tap()
            waitFor("the file") { (self.probe("app.files")["names"] as? [String] ?? []).contains("0000_Artboard 2.jpg") }
        }

        step("File › Export › Artboards to Files: every board as PNG") {
            menu("File", "Export", "Artboards to Files…")
            XCTAssert(app.buttons["artboards.export"].waitForExistence(timeout: 5))
            replace(app.textFields["artboards.prefix"], with: "Post")
            flip("artboards.selectedOnly")
            app.buttons["artboards.export"].tap()
            let names = { (self.probe("app.files")["names"] as? [String] ?? []).filter { $0.hasPrefix("Post_") && $0.hasSuffix(".png") } }
            waitFor("a file per board") { names().count == 2 }
            XCTAssert(names().contains { $0.hasSuffix("Artboard 1.png") } && names().contains { $0.hasSuffix("Artboard 2.png") }, "\(names())")
        }
    }
}
