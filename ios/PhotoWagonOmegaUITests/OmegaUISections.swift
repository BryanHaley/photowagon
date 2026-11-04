import XCTest

/// Every item in the ☰ menu, quick actions included, by touch. Each must do something: a history
/// step, a screen, a readable message, a document, a command sent. A screen it opens gets each of
/// its controls changed once, then Done.
final class OmegaUIMenuTests: OmegaUITestCase {
    /// Items that change nothing on the walk's fresh document: it's already that way.
    static let alreadyDone = ["View › Fit on Screen": "a document opens fitted", "View › Canvas Color › Default": "the default canvas colour is set"]

    func testEveryMenuItem() {
        let items = probe("app.menuTree")["items"] as? [[String: Any]] ?? []
        XCTAssertGreaterThan(items.count, 300, "the menu tree")
        // The main setups walk every item; the layout setups only what can look different there.
        let everything = ["phone27", "phone18", "local"].contains(setup)
        // `OMEGA_ONLY=Edit` walks only the items whose path starts with that (to look at one menu);
        // commas between several.
        let only = ProcessInfo.processInfo.environment["OMEGA_ONLY"]?.split(separator: ",").map(String.init)
        for i in items where i["deferred"] == nil {
            guard let path = i["path"] as? [String], let title = i["title"] as? String, !title.isEmpty else { continue }
            if let only, !only.contains(where: { (path + [title]).joined(separator: " › ").hasPrefix($0) }) { continue }
            if !everything, !(title.hasSuffix("…") || path.first == "Quick Actions" || path.first == "Window") { continue }
            let id = "menu|" + (path + [title]).joined(separator: " › ")
            item(id, command: (path + [title]).joined(separator: " › ")) { r in
                if i["enabled"] as? Bool == false {
                    r.outcome = "greyed out"
                    return
                }
                let before = state
                quickMenu(path.first == "Quick Actions" ? [title] : path + [title])
                Thread.sleep(forTimeInterval: 0.5)
                var after = state
                let end = Date().addingTimeInterval(30)
                while (after["busy"] as? Bool) == true, Date() < end {
                    Thread.sleep(forTimeInterval: 0.3)
                    after = state
                }
                var sheet = covered
                // A menu action runs once the menu has closed, and a screen takes a moment to come up.
                let late = Date().addingTimeInterval(3)
                while !sheet, !Self.changed(before, after), Date() < late {
                    Thread.sleep(forTimeInterval: 0.3)
                    after = state
                    sheet = covered
                }
                // The Files picker comes up seconds after the app has already changed.
                let picker = Date().addingTimeInterval(3)
                while !sheet, title.hasSuffix("…"), Date() < picker {
                    Thread.sleep(forTimeInterval: 0.3)
                    sheet = covered
                }
                r.message = after["toast"] as? String
                let sent = after["dispatched"] as? [String] ?? []
                if sent.count != (before["dispatched"] as? [String])?.count || sent.last != (before["dispatched"] as? [String])?.last { r.params = sent.last ?? "" }
                r.problems += Self.messageProblems(r.message)
                if !sheet, !Self.changed(before, after), Self.alreadyDone[r.command] == nil { r.problems.append("nothing happened") }
                if sheet, app.navigationBars.firstMatch.exists {
                    r.outcome = "screen"
                    exerciseScreen(&r)
                }
            }
        }
        finish()
    }

    /// Each switch, slider, stepper and segment of the screen in front once, then Done.
    private func exerciseScreen(_ r: inout Result) {
        let front = app.navigationBars.element(boundBy: max(app.navigationBars.count - 1, 0))
        var touched = 0
        for s in app.switches.allElementsBoundByIndex.prefix(8) where s.isHittable {
            s.tap(); touched += 1
        }
        for s in app.sliders.allElementsBoundByIndex.prefix(8) where s.isHittable {
            s.adjust(toNormalizedSliderPosition: 0.7); touched += 1
        }
        for s in app.steppers.allElementsBoundByIndex.prefix(4) where s.isHittable {
            s.buttons.element(boundBy: 1).tap(); touched += 1
        }
        for s in app.segmentedControls.allElementsBoundByIndex.prefix(4) where s.isHittable && s.buttons.count > 1 {
            s.buttons.element(boundBy: 1).tap(); touched += 1
        }
        r.params += r.params.isEmpty ? "\(touched) controls" : "; \(touched) controls"
        let before = state
        let done = front.buttons["sheet.done"].exists ? front.buttons["sheet.done"] : front.buttons["Done"]
        if done.exists, done.isHittable {
            done.tap()
            Thread.sleep(forTimeInterval: 1)
            let after = state
            r.problems += Self.messageProblems(after["toast"] as? String)
            if let t = after["toast"] as? String, t != before["toast"] as? String { r.message = t }
        }
    }
}

/// Every tool, picked from its group on the toolbar, then a drag on the canvas.
final class OmegaUIToolTests: OmegaUITestCase {
    func testEveryTool() {
        let groups = probe("app.tools")["groups"] as? [[[String: String]]] ?? []
        XCTAssertGreaterThan(groups.count, 15, "the tool groups")
        for g in groups {
            guard let first = g.first?["title"] else { continue }
            for t in g {
                guard let tid = t["id"], let title = t["title"] else { continue }
                item("tool|\(tid)", command: "tool \(title)") { r in
                    tool(group: first, pick: g.count > 1 ? title : nil)
                    let picked = state["tool"] as? String
                    if picked != tid { r.problems.append("picked \(picked ?? "nothing"), not \(tid)") }
                    let before = state
                    drag(from: (0.3, 0.4), to: (0.7, 0.6))
                    Thread.sleep(forTimeInterval: 0.8)
                    let after = state
                    r.message = after["toast"] as? String
                    r.problems += Self.messageProblems(r.message)
                    r.params = Self.changed(before, after) ? "the drag did something" : "the drag did nothing"
                }
            }
        }
        finish()
    }
}

/// Every small button (an icon, no words) on the workspace says its name when held, or opens
/// its menu.
final class OmegaUINamesTests: OmegaUITestCase {
    func testIconButtonsSayTheirNames() {
        let buttons = app.buttons.allElementsBoundByIndex.filter { $0.isHittable && $0.frame.width <= 64 && $0.frame.height <= 64 }
        let names = buttons.map { $0.identifier.isEmpty ? $0.label : $0.identifier }
        XCTAssertGreaterThan(names.count, 5, "the workspace's icon buttons")
        for name in Set(names).sorted() where !name.isEmpty {
            item("hold|\(name)", command: "hold \(name)") { r in
                let b = app.buttons[name].firstMatch
                guard b.exists, b.isHittable else { r.outcome = "not shown"; return }
                b.press(forDuration: 0.9)
                Thread.sleep(forTimeInterval: 0.3)
                let hint = state["hint"] as? String
                let opened = app.collectionViews.firstMatch.exists || app.navigationBars.firstMatch.exists || app.otherElements["hint"].exists
                r.message = hint
                if hint == nil, !opened { r.problems.append("holding it shows no name") }
            }
        }
        finish()
    }
}
