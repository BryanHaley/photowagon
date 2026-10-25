import XCTest

/// Shared setup and helpers for the walkthrough tests. The app starts from default settings,
/// with the sample files in its folder and the test probe on.
class WalkthroughTestCase: XCTestCase {
    var app: XCUIApplication!
    /// The first-time tour stays out of the way unless a test is about it.
    var skipsTutorial: Bool { true }
    /// The files copied into the app's folder at launch.
    var samplesFolder: String { Bundle(for: WalkthroughTestCase.self).resourcePath ?? "" }

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        let samples = samplesFolder
        try? FileManager.default.createDirectory(at: probeFolder, withIntermediateDirectories: true)
        app.launchArguments = ["-resetSettings", "YES", "-seedSamples", samples, "-resetRecents", "YES", "-uiTestProbe", probeFolder.path, "-skipTutorial", skipsTutorial ? "YES" : "NO"]
        app.launch()
    }

    // MARK: - Probe

    /// Shared with the app (simulator processes see the Mac's /tmp).
    let probeFolder = URL(fileURLWithPath: "/tmp/photowagon-probe-\(ProcessInfo.processInfo.processIdentifier)")

    private var probeSeq = 0
    private var toastsSeen = 0

    /// Run a read-only engine command through the app's test probe.
    @discardableResult
    func probe(_ id: String, _ params: [String: Any] = [:]) -> [String: Any] {
        probeSeq += 1
        let (query, result) = (probeFolder.appendingPathComponent("query.json"), probeFolder.appendingPathComponent("result.json"))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: ["seq": probeSeq, "id": id, "params": params]).write(to: query, options: .atomic))
        let end = Date().addingTimeInterval(20)
        while Date() < end {
            if let data = try? Data(contentsOf: result), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["seq"] as? Int == probeSeq {
                let r = obj["result"]
                if let d = r as? [String: Any] {
                    XCTAssertNil(d["error"], "probe \(id): \(d)")
                    return d
                }
                return ["value": r as Any]
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("the app didn't answer the probe (\(id))")
        return [:]
    }

    /// The document as the engine sees it (`document.inspect`).
    var inspect: [String: Any] { probe("document.inspect") }

    /// The layers, top first.
    var layers: [[String: Any]] { inspect["layers"] as? [[String: Any]] ?? [] }

    /// Every layer, groups' layers after their group, top first.
    var allLayers: [[String: Any]] {
        func walk(_ l: [[String: Any]]) -> [[String: Any]] { l.flatMap { [$0] + walk($0["children"] as? [[String: Any]] ?? []) } }
        return walk(layers)
    }

    var layerTotal: Int { allLayers.count }

    /// The top layer's name.
    var topName: String { allLayers.first?["name"] as? String ?? "" }

    func layer(named name: String) -> [String: Any]? { allLayers.first { $0["name"] as? String == name } }

    func layerID(_ name: String) -> Int { layer(named: name)?["id"] as? Int ?? -1 }

    /// The Layers panel row for `name` (open the panel first).
    func layerRow(_ name: String) -> XCUIElement { app.descendants(matching: .any)["layer.\(name)"].firstMatch }

    /// Scroll the open Layers panel until `name`'s row shows (the list only builds rows on screen).
    @discardableResult
    func showLayer(_ name: String) -> XCUIElement { show(layerRow(name), "layer \(name)") }

    /// Scroll the open panel until `row` shows.
    @discardableResult
    func show(_ row: XCUIElement, _ what: String) -> XCUIElement {
        let list = app.collectionViews.firstMatch
        let shown = { row.exists && !row.frame.isEmpty && self.app.windows.firstMatch.frame.insetBy(dx: 0, dy: 40).contains(CGPoint(x: row.frame.midX, y: row.frame.midY)) }
        // A half-height sheet shows a row or two: pull it up first.
        if !shown() { expandSheet() }
        var swipes = 0
        // Short, slow drags: a swipe can fling right past a row, and a fast swipe down at the top
        // closes the sheet on iOS 27.
        let scroll = { (down: Bool) in
            let (a, b) = down ? (0.75, 0.4) : (0.4, 0.75)
            // Near the left edge, on the labels, not a slider.
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: a))
                .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: b)), withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        // iOS 27 reports rows' new frames a moment after a scroll.
        while swipes < 30, !shown() { scroll(true); swipes += 1; Thread.sleep(forTimeInterval: 0.5) }
        while swipes < 60, !shown() { scroll(false); swipes += 1; Thread.sleep(forTimeInterval: 0.5) }
        XCTAssert(row.waitForExistence(timeout: 5), what)
        return row
    }

    /// Flip a toggle in a form: tap the switch itself (its label doesn't flip it).
    func flip(_ id: String) {
        let row = app.switches[id].firstMatch
        // Settings sheets have a preview on top: the switch may be below the fold.
        if !row.waitForExistence(timeout: 3) { show(row, id) }
        XCTAssert(row.waitForExistence(timeout: 5), id)
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    /// Pull the open sheet up to full height.
    func expandSheet() {
        let bar = app.navigationBars.firstMatch
        guard bar.exists else { return }
        let from = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)), withVelocity: .slow, thenHoldForDuration: 0.2)
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Tap a layer's name in the open Layers panel.
    func tapLayer(_ name: String) { showLayer(name).tap() }

    /// Touch and hold a layer in the open Layers panel, then pick `item` from its menu.
    func layerMenu(_ name: String, _ item: String) {
        let row = showLayer(name)
        for _ in 0..<3 {
            row.press(forDuration: 1.0)
            let b = app.buttons.named(item)
            if b.waitForExistence(timeout: 3) {
                Thread.sleep(forTimeInterval: 0.4)
                b.tap()
                return
            }
        }
        XCTFail("no \(item) in \(name)'s menu")
    }

    /// In the open Layers panel: the adjustment button's `item` (Photo Filter, Exposure…).
    func addAdjustment(_ item: String) {
        pick(menu: "layers.adjust", item)
    }

    /// Mean and spread over `rect` (document pixels) of the composite, a layer's pixels or its mask.
    func stats(_ rect: [Int]? = nil, of: String = "composite", layer: String? = nil) -> (mean: [Double], stddev: [Double], soft: Double) {
        var p: [String: Any] = ["of": of]
        if let rect { p["rect"] = rect }
        if let layer { p["layer"] = layer }
        let r = probe("document.stats", p)
        guard let mean = r["mean"] as? [Double], let sd = r["stddev"] as? [Double], !mean.isEmpty else {
            XCTFail("no stats: \(r)")
            return ([0, 0, 0, 0], [0, 0, 0, 0], 0)
        }
        return (mean, sd, r["soft"] as? Double ?? 0)
    }

    /// The canvas point showing document pixel (`x`, `y`).
    func at(_ x: Double, _ y: Double) -> XCUICoordinate {
        let p = probe("app.docToCanvas", ["x": x, "y": y])
        let (cx, cy) = (p["x"] as? Double ?? 0, p["y"] as? Double ?? 0)
        return canvas.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: cx, dy: cy))
    }

    /// Drag on the canvas between document pixels.
    func drag(doc a: (Double, Double), to b: (Double, Double)) {
        at(a.0, a.1).press(forDuration: 0.05, thenDragTo: at(b.0, b.1), withVelocity: .slow, thenHoldForDuration: 0.05)
    }

    /// The document's size in pixels.
    var docSize: (w: Double, h: Double) {
        let i = inspect
        return (i["width"] as? Double ?? 0, i["height"] as? Double ?? 0)
    }

    /// A layer's bounds as [x, y, width, height].
    func bounds(_ name: String) -> [Double] { layer(named: name)?["bounds"] as? [Double] ?? [] }

    var activeLayerName: String? {
        let i = inspect
        let id = i["activeLayer"] as? Int
        func walk(_ l: [[String: Any]]) -> [[String: Any]] { l.flatMap { [$0] + walk($0["children"] as? [[String: Any]] ?? []) } }
        return walk(i["layers"] as? [[String: Any]] ?? []).first { $0["id"] as? Int == id }?["name"] as? String
    }

    /// Foreground and background colours, 0…1.
    var colors: (fg: [Double], bg: [Double]) {
        let s = probe("session.inspect")
        return (s["foreground"] as? [Double] ?? [], s["background"] as? [Double] ?? [])
    }

    var brush: [String: Any] { probe("brush.get") }

    func typeInfo(_ name: String) -> [String: Any] {
        guard let id = layer(named: name)?["id"] else { XCTFail("no layer \(name)"); return [:] }
        return probe("type.info", ["layer": id])
    }

    /// Luminance of an RGB(A) mean.
    func lum(_ c: [Double]) -> Double { c.count >= 3 ? 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2] : 0 }

    /// A key on the hardware keyboard, sent to the canvas.
    func key(_ k: String, _ flags: XCUIElement.KeyModifierFlags = []) {
        canvas.typeKey(k, modifierFlags: flags)
    }

    /// The colour on screen at a canvas point, 0…1.
    func screenColor(_ c: XCUICoordinate) -> [Double] {
        let shot = XCUIScreen.main.screenshot().image
        guard let cg = shot.cgImage else { return [] }
        let scale = Double(cg.width) / Double(shot.size.width)
        let (x, y) = (Int(c.screenPoint.x * scale), Int(c.screenPoint.y * scale))
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(cg, in: CGRect(x: -x, y: y - cg.height + 1, width: cg.width, height: cg.height))
        return px.prefix(3).map { Double($0) / 255 }
    }

    /// Open Layers, select the layer (its pixels, not its mask), close.
    func selectLayer(_ name: String) {
        app.buttons["layers"].tap()
        tapLayer(name)
        closeSheet()
    }

    /// In the open History panel, tap the step before the latest one. The list only builds the
    /// rows on screen: scroll until it shows.
    func historyBackOne() {
        let steps = (inspect["history"] as? [String])?.count ?? 0
        guard steps > 1 else { return XCTFail("no history to go back in") }
        let row = app.buttons["history.\(steps - 2)"]
        XCTAssert(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'history.'")).firstMatch.waitForExistence(timeout: 5))
        for _ in 0..<6 where !row.isHittable { app.collectionViews.firstMatch.swipeUp() }
        row.tap()
    }

    func newLayer() {
        app.buttons["layers"].tap()
        app.buttons["layers.new"].tap()
        closeSheet()
    }

    /// Wait for a toast that starts with `text`.
    /// A toast beginning with `text` shown since the last one found. Read through the probe:
    /// on iOS 27 a 2.5 s toast can be gone before a tap returns.
    func toast(_ text: String) -> Bool {
        let end = Date().addingTimeInterval(15)
        while Date() < end {
            let all = probe("app.toasts")["toasts"] as? [String] ?? []
            if let i = all.indices.dropFirst(toastsSeen).first(where: { all[$0].hasPrefix(text) }) {
                toastsSeen = i + 1
                return true
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    /// Set a percentage slider in the options row to `percent`, within 1 (an iOS 27 option slider
    /// has about half a point of travel per percent).
    func option(_ title: String, percent: Int) {
        let s = app.sliders["option.\(title)"].firstMatch
        XCTAssert(s.waitForExistence(timeout: 5), "option \(title)")
        // Halve the gap each time: some sliders aren't linear in their position.
        var (low, high, position) = (0.0, 1.0, Double(percent) / 100)
        for _ in 0..<12 {
            s.slide(to: position)
            // iOS 27 updates the slider's accessibility value a moment after it moves.
            Thread.sleep(forTimeInterval: 0.5)
            guard let v = (s.value as? String).flatMap({ Int($0.dropLast()) }) else { return }
            if abs(v - percent) <= 1 { return }
            if v < percent { low = position } else { high = position }
            position = (low + high) / 2
        }
        XCTFail("\(title) didn't reach \(percent)%: \(s.value ?? "")")
    }

    /// Set an options-row slider (Size, Opacity, Strength, Hardness…) to a fraction of its travel.
    func option(_ title: String, _ position: Double) {
        let s = app.sliders["option.\(title)"].firstMatch
        XCTAssert(s.waitForExistence(timeout: 5), "option \(title)")
        // The row may have just changed for a new tool: let iOS 27 report where its sliders are.
        Thread.sleep(forTimeInterval: 0.5)
        s.slide(to: position)
        Thread.sleep(forTimeInterval: 0.5)
    }

    // MARK: - Files, painting and masks

    /// Touch and hold the mask button, then pick `item` (Hide Selection, Hide All…).
    func maskButton(_ item: String) {
        let button = app.buttons["layers.mask"].firstMatch
        XCTAssert(button.waitForExistence(timeout: 5))
        for _ in 0..<3 {
            button.press(forDuration: 1.0)
            let b = app.buttons.named(item)
            if b.waitForExistence(timeout: 3) {
                Thread.sleep(forTimeInterval: 0.4)
                b.tap()
                waitIdle()
                return
            }
        }
        XCTFail("no \(item) in the mask button's menu")
    }

    /// Tap a layer's row and wait for it to be selected (a row answers a single tap late).
    func select(_ name: String) {
        tapLayer(name)
        let end = Date().addingTimeInterval(5)
        while activeLayerName != name, Date() < end { Thread.sleep(forTimeInterval: 0.3) }
        XCTAssertEqual(activeLayerName, name)
    }

    /// Home, from the top bar when a document is in front.
    func goHome() {
        if !app.buttons["home.open"].waitForExistence(timeout: 2), app.buttons["home"].exists { app.buttons["home"].tap() }
        XCTAssert(app.buttons["home.open"].waitForExistence(timeout: 10), "Home")
    }

    /// Home › Open: the app's folder.
    func openFromHome() {
        goHome()
        app.buttons["home.open"].tap()
    }

    /// Open `file` from the app's folder (Home › Open).
    func openSample(_ file: String) {
        openFromHome()
        pickFile(file)
        waitForCanvas()
        waitIdle()
    }

    /// File › Place Embedded: the picture, sized to the canvas, then Commit.
    func place(_ file: String, move: ((Double, Double), (Double, Double))? = nil) {
        menu("File", "Place Embedded…")
        pickFile(file)
        XCTAssert(app.buttons["Commit"].waitForExistence(timeout: 20), "the placed picture's transform box")
        if let move {
            // Right after the Place sheet closes, a drag can be lost: let it settle.
            Thread.sleep(forTimeInterval: 1.5)
            drag(doc: move.0, to: move.1)
        }
        tapChip(app.buttons["Commit"].firstMatch)
        waitIdle()
    }

    func brush(_ tip: String, size: Double) {
        tool(group: "Brush", pick: "Brush")
        brushTip("General", tip)
        option("Size", size)
    }

    func swapColors() {
        app.buttons["colors.swap"].firstMatch.tap()
    }

    /// Black (or white) in front, swapping if needed. A selected mask has its own pair, white
    /// in front and black behind, as in Photoshop.
    func foreground(black: Bool) {
        if (lum(colors.fg) < 0.5) != black { swapColors() }
        XCTAssertEqual(lum(colors.fg) < 0.5, black, black ? "black in front" : "white in front")
    }

    /// Select the subject of the photo on the active layer (Object Selection › Subject).
    func selectSubject() {
        tool(group: "Object Selection", pick: "Object Selection")
        app.buttons["Subject"].firstMatch.tap()
        XCTAssert(app.buttons["Deselect"].waitForExistence(timeout: 60), "the subject is selected")
        waitIdle()
    }

    func freeTransform(drag from: (Double, Double), to: (Double, Double)) {
        menu("Edit", "Free Transform")
        XCTAssert(app.buttons["Commit"].waitForExistence(timeout: 5), "the transform box")
        drag(doc: from, to: to)
        tapChip(app.buttons["Commit"].firstMatch)
        waitIdle()
    }

    /// Scroll the context bar sideways until `chip` is on screen, then tap it.
    func tapChip(_ chip: XCUIElement) {
        XCTAssert(chip.waitForExistence(timeout: 5), "\(chip)")
        let width = app.windows.firstMatch.frame.width
        for _ in 0..<5 where chip.frame.maxX > width - 8 || chip.frame.minX < 8 {
            let y = chip.frame.midY
            let left = chip.frame.minX > width / 2
            let from = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: left ? width * 0.8 : width * 0.2, dy: y))
            // Slowly: a fast drag flings the row to its end.
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: left ? -width * 0.5 : width * 0.5, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.2)
            Thread.sleep(forTimeInterval: 0.4)
        }
        chip.tap()
    }

    // MARK: - Layer Style

    var blendIfRanges: [String: [Int]] { blendIfRanges("gray") }

    /// `thisLayer` and `underlying` of one Blend If channel.
    func blendIfRanges(_ channel: String) -> [String: [Int]] {
        let b = (probe("layer.layerStyle.get")["blending"] as? [String: Any])?["blendIf"] as? [String: Any] ?? [:]
        let entry = (b["channels"] as? [[String: Any]])?.first { $0["channel"] as? String == channel } ?? [:]
        return entry.compactMapValues { $0 as? [Int] }
    }

    /// Layer Style for `name`: double-tap the right of its row, as in Photoshop.
    func openStyle(_ name: String) {
        if !app.buttons["layers.fx"].exists { app.buttons["layers"].tap() }
        let right = show(app.descendants(matching: .any)["layer.style.\(name)"].firstMatch, "the right of \(name)")
        right.doubleTap()
        XCTAssert(app.navigationBars["Layer Style"].waitForExistence(timeout: 8), "Layer Style")
    }

    /// Drag a Blend If handle (0, 1 black; 2, 3 white) to `value` (0–255).
    func blendIf(_ which: String, handle: Int, to value: Double, channel: String = "gray") {
        let bar = show(app.otherElements["style.blendIf.\(which)"].firstMatch, "Blend If \(which)")
        let r = blendIfRanges(channel)[which] ?? [0, 0, 255, 255]
        guard r.count == 4 else { return XCTFail("no Blend If: \(r)") }
        let f = bar.frame
        let x = { (v: Double) in v / 255 * f.width }
        let origin = bar.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: x(Double(r[handle])), dy: f.height * 0.7))
            .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: x(value), dy: f.height * 0.7)), withVelocity: .slow, thenHoldForDuration: 0.1)
        waitIdle()
    }

    // MARK: - Helpers

    var canvas: XCUIElement { app.otherElements["canvas"].firstMatch }

    var statusBar: String {
        let s = app.buttons["statusBar"]
        return s.waitForExistence(timeout: 5) ? s.label : ""
    }

    var zoomPercent: Int { Int(statusBar.split(separator: "%").first.map(String.init) ?? "") ?? 0 }

    var layerCount: Int {
        app.buttons["statusBar"].tap()
        app.buttons["Layer Count"].tap()
        let text = statusBar
        app.buttons["statusBar"].tap()
        app.buttons["Document Dimensions"].tap()
        return Int(text.split(separator: " ").dropFirst().first.map(String.init) ?? "") ?? -1
    }

    func step(_ name: String, _ body: () -> Void) {
        XCTContext.runActivity(named: name) { activity in
            body()
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            activity.add(shot)
        }
    }

    func drag(from a: (Double, Double), to b: (Double, Double)) {
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: a.0, dy: a.1))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: b.0, dy: b.1))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.05)
    }

    func replace(_ field: XCUIElement, with text: String) {
        XCTAssert(field.waitForExistence(timeout: 5), "\(field)")
        // Focus it (again if a sheet was still moving), go to the end, delete what is there.
        // A tap on a focused field would undo the app's select-all; only tap to focus.
        for _ in 0..<5 {
            if (field.value(forKey: "hasKeyboardFocus") as? Bool) == true { break }
            field.tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
        // The app selects a field's text on focus: one delete clears it.
        Thread.sleep(forTimeInterval: 0.3)
        if let old = field.value as? String, !old.isEmpty, old != field.placeholderValue {
            field.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        field.typeText(text)
    }

    /// Open the menu bar and follow `path` (File › Save As…).
    func menu(_ path: String...) {
        // Inside the open menu, not a toolbar button with the same name (Filter › Blur, the Blur tool).
        let item = { (name: String) in self.app.collectionViews.buttons.named(name) }
        let menu = app.buttons["menu"]
        XCTAssert(menu.waitForExistence(timeout: 5), "the menu button")
        // The menu can open where it was left (File already expanded): start from the deepest
        // item of the path that shows.
        func shown() -> Int? { path.indices.reversed().first { item(path[$0]).exists } }
        var start: Int?
        // By position: XCUITest can't always tell the menu button is on screen. Right after a
        // sheet or Home closes the tap can be lost: try again until the menu opens.
        for _ in 0..<3 {
            tapAt(menu)
            let end = Date().addingTimeInterval(3)
            while start == nil, Date() < end {
                start = shown()
                if start == nil { Thread.sleep(forTimeInterval: 0.2) }
            }
            if start != nil { break }
        }
        guard let first = start else { return XCTFail("the menu didn't open for \(path.joined(separator: " › "))") }
        for i in first..<path.count {
            let button = item(path[i])
            XCTAssert(button.waitForExistence(timeout: 5), "menu item \(path[i])")
            // Taps while the menu is still opening are lost.
            Thread.sleep(forTimeInterval: 0.5)
            button.tap()
            // A busy app (a big document still drawing) can lose taps: retry until the submenu opens.
            for _ in 0..<3 where i + 1 < path.count && !item(path[i + 1]).waitForExistence(timeout: 3) && button.exists {
                // Long menus build only the rows on screen: the item may be further down. Scroll
                // first, since a second tap would close the submenu.
                if scrollMenu(to: item(path[i + 1])) { break }
                button.tap()
            }
            // The last item: tap again if the menu is still open. One quick look: waiting longer
            // misses the short message the item shows.
            if i + 1 == path.count {
                Thread.sleep(forTimeInterval: 0.8)
                if button.exists, button.isHittable { button.tap() }
            }
        }
    }


    /// Scroll the open menu down until `row` shows.
    private func scrollMenu(to row: XCUIElement) -> Bool {
        for _ in 0..<10 {
            let lists = app.collectionViews
            lists.element(boundBy: max(lists.count - 1, 0)).swipeUp()
            if row.waitForExistence(timeout: 1) {
                // Let the list stop coasting before the row is tapped.
                Thread.sleep(forTimeInterval: 1)
                return row.exists
            }
        }
        return false
    }

    /// Tap a tool group, and pick a tool from the row it shows.
    func tool(group: String, pick: String?) {
        let toolbar = app.descendants(matching: .any)["group.\(group)"].firstMatch
        XCTAssert(toolbar.waitForExistence(timeout: 5), "tool group \(group)")
        // Scroll the toolbar until the group is on screen.
        let bar = app.scrollViews["toolbar"]
        let width = app.windows.firstMatch.frame.width
        // A swipe flings the toolbar to one end, past the groups in the middle: drag slowly by
        // the distance to the middle of the screen, without momentum.
        for _ in 0..<6 {
            let f = toolbar.frame
            if f.minX >= 0 && f.maxX <= width - 50 { break }
            let dx = max(min(f.midX - width / 2, width * 0.6), -width * 0.6)
            let from = bar.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: width / 2, dy: 0))
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: -dx, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        toolbar.tap()
        if let pick {
            let button = app.buttons["row.\(pick)"].firstMatch
            XCTAssert(button.waitForExistence(timeout: 5), "tool \(pick)")
            button.tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// Open a "…" menu button and pick `name`; taps while the menu opens are lost.
    func pick(menu button: String, _ name: String) {
        let item = app.collectionViews.buttons.named(name)
        for _ in 0..<3 where !item.exists {
            tapAt(app.buttons[button])
            _ = item.waitForExistence(timeout: 3)
        }
        XCTAssert(item.exists, "menu item \(name)")
        Thread.sleep(forTimeInterval: 0.5)
        for _ in 0..<3 where item.exists {
            item.tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    func tapAt(_ e: XCUIElement) {
        XCTAssert(e.waitForExistence(timeout: 5), "\(e)")
        let f = e.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY)).tap()
    }

    /// No error message is showing.
    func noErrorToast() {
        let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'not available' OR label CONTAINS 'need'")).firstMatch
        XCTAssertFalse(error.exists, error.exists ? error.label : "")
    }

    /// Pick a swatch in the system colour picker from the colour well.
    func pickColor(containing name: String) {
        let well = app.buttons["Foreground"].firstMatch.exists ? app.buttons["Foreground"].firstMatch : app.colorWells.firstMatch
        XCTAssert(well.waitForExistence(timeout: 5), "colour well")
        well.tap()
        // A tap while something animates is lost: open the picker again if no swatch shows.
        let swatch = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        if !swatch.waitForExistence(timeout: 8) { well.tap() }
        chooseColor(containing: name)
    }

    /// In the open system colour picker: tap a swatch, then close it.
    func chooseColor(containing name: String) {
        let starts = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        // The picker is another process: slow to show its swatches when simulators share the CPU.
        let swatch = starts.waitForExistence(timeout: 15) ? starts : app.otherElements.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        tapAt(swatch)
        tapAt(app.buttons["close"])
    }

    /// Pick `option` in a picker shown as a menu.
    func pick(_ picker: XCUIElement, _ option: String) {
        XCTAssert(picker.waitForExistence(timeout: 5), "\(picker)")
        picker.tap()
        let button = app.buttons.named(option)
        XCTAssert(button.waitForExistence(timeout: 5), "option \(option)")
        button.tap()
    }

    /// Pick a brush tip from the Brush Tip menu.
    func brushTip(_ group: String, _ name: String) {
        app.buttons["brush.tips"].firstMatch.tap()
        let (folder, tip) = (app.buttons.named(group), app.buttons.named(name))
        XCTAssert(folder.waitForExistence(timeout: 5), "brush tip folder \(group)")
        // Taps while the menu is still opening are lost: tap the folder until its tips show.
        Thread.sleep(forTimeInterval: 0.5)
        for _ in 0..<3 where !tip.exists {
            folder.tap()
            _ = tip.waitForExistence(timeout: 3)
        }
        XCTAssert(tip.exists, "brush tip \(name)")
        tip.tap()
    }

    /// Close the sheet in front with Done (every sheet has a navigation bar; the workspace has none).
    func closeSheet() {
        for _ in 0..<3 {
            let bar = app.navigationBars.firstMatch
            guard bar.exists else { return }
            // A sheet over a sheet: the Done of the one in front (the last bar).
            let bars = app.navigationBars
            let front = bars.element(boundBy: max(bars.count - 1, 0)).buttons["sheet.done"]
            let done = front.exists ? front : app.buttons["sheet.done"].firstMatch
            if done.exists { done.tap() } else { bar.swipeDown(velocity: .fast) }
            let gone = NSPredicate(format: "exists == false")
            if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: gone, object: bar)], timeout: 3) == .completed { return }
        }
        XCTFail("a sheet stayed open")
    }

    /// Whether a document called `name` is open (its tab, or the only document when the tab row
    /// is hidden), waiting up to `timeout` seconds.
    func docOpen(_ name: String, timeout: TimeInterval = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if (probe("app.documents")["names"] as? [String])?.contains(name) == true { return true }
            if timeout > 0 { Thread.sleep(forTimeInterval: 0.3) }
        } while Date() < end
        return false
    }

    /// Close document `name`: its tab's ✕, or File › Close when it's the only one.
    func closeDoc(_ name: String) {
        let x = app.buttons["Close \(name)"]
        if x.exists { x.tap() } else { menu("File", "Close") }
    }

    /// Wait for the workspace: a document open and the Home screen gone (the workspace stays
    /// in the hierarchy under Home, so its status bar alone doesn't say it's showing).
    func waitForCanvas() {
        XCTAssert(app.buttons["statusBar"].waitForExistence(timeout: 20))
        let home = app.buttons["home.new"]
        let gone = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: gone, object: home)], timeout: 10), .completed, "the Home screen closed")
    }

    /// Home's Workspace button, tapped again if Home is still fading in and the tap is lost.
    func backToWorkspace() {
        let button = app.buttons["home.workspace"]
        for _ in 0..<3 where button.exists {
            button.tap()
            let gone = NSPredicate(format: "exists == false")
            if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: gone, object: button)], timeout: 2) == .completed { break }
        }
        waitForCanvas()
    }

    /// Wait for background work (the spinner) to finish.
    func waitIdle() {
        let spinner = app.activityIndicators.firstMatch
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: spinner)
        waitForExpectations(timeout: 60)
    }

    /// Pick `name` in the Open / Place sheet (On My iPhone › PhotoWagon).
    func pickFile(_ name: String) {
        let file = app.buttons["file.\(name)"]
        // The list only builds the rows on screen: scroll until it shows.
        _ = file.waitForExistence(timeout: 3)
        show(file, "file \(name) in the Open sheet")
        // A tap on a list that's still coasting only stops it: tap until the sheet goes.
        let gone = NSPredicate(format: "exists == false")
        for _ in 0..<3 where file.exists {
            Thread.sleep(forTimeInterval: 0.5)
            file.tap()
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: gone, object: file)], timeout: 3)
        }
    }
}

extension XCUIElement {
    /// Drag a slider's thumb to `position` (0…1). On iOS 27 `adjust(toNormalizedSliderPosition:)`
    /// only reaches the ends of a short slider: its thumb is about 37 points wide.
    func slide(to position: Double) {
        let thumb = min(37.0, frame.width / 2)
        let track = frame.width - thumb
        // Where the thumb is, to grab it; a target at an end goes past the track so the thumb lands
        // on it exactly.
        let x = { (p: Double) in thumb / 2 + max(0, min(1, p)) * track }
        let to = { (p: Double) in p <= 0 ? -20 : p >= 1 ? self.frame.width + 20 : x(p) }
        let origin = coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
        let drag = { (from: Double, target: Double) in
            origin.withOffset(CGVector(dx: x(from), dy: 0))
                .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: to(target), dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        // iOS 27 reports a slider's position a moment after it scrolls into view.
        Thread.sleep(forTimeInterval: 0.4)
        // The thumb doesn't land exactly where the finger stops: aim again by the difference.
        var aim = position
        for _ in 0..<8 {
            var from = normalizedSliderPosition
            if abs(from - position) < 0.008 { return }
            // A drag of a few points doesn't move the thumb: go the other way first.
            if abs(aim - from) * track < 12 {
                let away = aim < 0.5 ? 1.0 : 0.0
                drag(from, away)
                from = away
            }
            drag(from, aim)
            Thread.sleep(forTimeInterval: 0.4)
            if position <= 0 || position >= 1 { continue }
            aim = max(0.001, min(0.999, aim + position - normalizedSliderPosition))
        }
    }
}

extension XCUIElementQuery {
    /// The element labelled `name`. iOS 27 adds a menu item's description to its label
    /// ("Pencil, Paint hard-edged lines."), so that counts too.
    func named(_ name: String) -> XCUIElement {
        matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ", ")).firstMatch
    }
}

extension XCUIElement {
    func waitForHittable(timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if exists && isHittable { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }
}
