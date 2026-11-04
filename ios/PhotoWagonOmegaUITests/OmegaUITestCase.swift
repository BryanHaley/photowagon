import XCTest

/// Tier A, the touch tier of Omega (plan/omega-e2e.md, section 7): every control by touch, in the
/// real app. Each test class is a section; results go to `$OMEGA_OUT/<setup>/<class>/results.jsonl`
/// in the same form as tier B, so the runner and report treat them alike. A failed check doesn't
/// stop the section: it's written down against the item and the next item goes on.
class OmegaUITestCase: WalkthroughTestCase {
    struct Result: Codable {
        var id: String
        var command: String
        var fixture: String
        var params: String
        var outcome: String
        var message: String?
        var problems: [String]
        var ms: Int
    }

    private var folder: URL!
    private var done = Set<String>()
    private var failed = 0
    /// What went wrong in the item being tried (XCTest failures included).
    private var problems: [String] = []
    /// While tidying up between items: what goes wrong then isn't the item's.
    private var tidying = false
    /// System alerts (Photos access and the like) belong to SpringBoard, not the app.
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    /// The device setup (the runner sets it): phone27, phone18, small18, ipad27, landscape27, darkLarge27.
    var setup: String { ProcessInfo.processInfo.environment["OMEGA_SETUP"] ?? "local" }

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        let root = ProcessInfo.processInfo.environment["OMEGA_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("omega")
        folder = root.appendingPathComponent(setup).appendingPathComponent(String(describing: type(of: self)))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for line in (try? String(contentsOf: results, encoding: .utf8))?.split(separator: "\n") ?? [] {
            if let r = try? JSONDecoder().decode(Result.self, from: Data(line.utf8)) {
                done.insert(r.id)
                if !r.problems.isEmpty { failed += 1 }
            }
        }
        if let id = try? String(contentsOf: current, encoding: .utf8), !id.isEmpty, !done.contains(id) {
            write(Result(id: id, command: id, fixture: setup, params: "", outcome: "crash", problems: ["the app or the test stopped during this item"], ms: 0))
        }
        if setup.hasPrefix("landscape") { XCUIDevice.shared.orientation = .landscapeLeft }
        _ = probe("app.reset")
        waitForCanvas()
    }

    private var results: URL { folder.appendingPathComponent("results.jsonl") }
    private var current: URL { folder.appendingPathComponent("current.txt") }
    private var priorityNotes: URL { folder.appendingPathComponent("priority-notes.txt") }

    private func write(_ r: Result) {
        done.insert(r.id)
        if !r.problems.isEmpty { failed += 1 }
        guard let data = try? JSONEncoder().encode(r) else { return }
        if let h = try? FileHandle(forWritingTo: results) {
            h.seekToEndOfFile()
            h.write(data + Data("\n".utf8))
            try? h.close()
        } else {
            try? (data + Data("\n".utf8)).write(to: results)
        }
    }

    /// An XCTest failure inside an item belongs to that item: noted, not fatal.
    override func record(_ issue: XCTIssue) {
        // iOS's thread priority notes aren't test results.
        if issue.compactDescription.contains("quality-of-service") {
            let note = Data("\((try? String(contentsOf: current, encoding: .utf8)) ?? "") \(issue.compactDescription)\n".utf8)
            if let h = try? FileHandle(forWritingTo: priorityNotes) {
                h.seekToEndOfFile()
                h.write(note)
                try? h.close()
            } else {
                try? note.write(to: priorityNotes)
            }
            return
        }
        if !tidying { problems.append(issue.compactDescription) }
    }

    /// Tries one item unless it's already done, from the same document each time.
    func item(_ id: String, command: String, _ body: (inout Result) -> Void) {
        guard !done.contains(id) else { return }
        try? Data(id.utf8).write(to: current)
        let start = Date()
        problems = []
        var r = Result(id: id, command: command, fixture: setup, params: "", outcome: "ok", problems: [], ms: 0)
        reset()
        body(&r)
        settle()
        r.problems += problems
        r.ms = Int(Date().timeIntervalSince(start) * 1000)
        write(r)
    }

    /// Ends the section: its status file, and a failure if any item had problems.
    func finish() {
        let status: [String: Any] = ["status": failed > 0 ? "fail" : "pass", "cases": done.count, "failed": failed]
        try? JSONSerialization.data(withJSONObject: status).write(to: folder.appendingPathComponent("status.json"))
        if failed > 0 {
            super.record(XCTIssue(type: .assertionFailure, compactDescription: "\(failed) items with problems: see \(results.path)"))
        }
    }

    /// The ☰ menu along `path`, waiting for each row instead of fixed pauses; the walkthroughs'
    /// `menu(path:)` when a row doesn't show.
    func quickMenu(_ path: [String]) {
        let row = { (name: String) in self.app.collectionViews.buttons.named(name) }
        let button = app.buttons["menu"]
        for _ in 0..<3 {
            button.tap()
            // Open, though the row may be below the fold (Help): another tap would close it.
            if let first = path.first, Self.shows(row(first), within: 2) || app.collectionViews.count > 0 { break }
        }
        for (i, name) in path.enumerated() {
            var b = row(name)
            // Filter › Blur › Blur: the open submenu's own row comes first.
            if i > 0, path[i - 1] == name {
                let rows = app.collectionViews.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ", "))
                _ = Self.shows(b, within: 1.5)
                b = rows.element(boundBy: max(rows.count - 1, 0))
            }
            // A long menu builds only the rows on screen: scroll it until the row shows and can be tapped.
            if !Self.shows(b, within: 1.5) || !b.isHittable { _ = Self.scrolls(app, to: b, hittable: true) }
            guard b.exists else { return fallback(path) }
            Thread.sleep(forTimeInterval: 0.25)
            // A row partly above the screen in a short menu: touch the part that shows.
            let touch = { (b: XCUIElement) in
                // Cut off at the bottom: a tap there can be lost.
                if b.frame.maxY > self.app.windows.firstMatch.frame.maxY {
                    Self.scrollMenu(self.app)
                    Thread.sleep(forTimeInterval: 0.4)
                }
                let shown = b.frame.intersection(self.app.windows.firstMatch.frame)
                if !self.app.windows.firstMatch.frame.contains(b.frame) || !b.isHittable, shown.height > 8 {
                    // From the row, not the app: an app offset lands elsewhere in landscape.
                    b.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: (shown.midY - b.frame.minY) / b.frame.height)).tap()
                } else {
                    b.tap()
                }
            }
            touch(b)
            // Scroll before tapping again: on iOS 18 the open submenu's header has the same name,
            // and a second tap closes it.
            if i + 1 < path.count, !Self.shows(row(path[i + 1]), within: 2), !Self.scrolls(app, to: row(path[i + 1])) {
                if b.exists { touch(b) }
                if !Self.shows(row(path[i + 1]), within: 2), !(Self.scrolls(app, to: row(path[i + 1]))) { return fallback(path) }
            }
        }
    }

    /// The walkthroughs' slower `menu(path:)`, from the top: close what's open first.
    private func fallback(_ path: [String]) {
        settle()
        menu(path: path)
    }

    /// Scrolls the menu in front down until `e` shows.
    /// Toward a row above the part on screen (a short landscape menu scrolled down), else down;
    /// one not built yet: down first, then up.
    static func scrolls(_ app: XCUIApplication, to e: XCUIElement, hittable: Bool = false) -> Bool {
        let there = { e.exists && (!hittable || e.isHittable) }
        // A landscape drag moves the list about half its travel: Edit takes a dozen to its end.
        for i in 0..<24 where !there() {
            let top = menuList(app)?.frame.intersection(app.windows.firstMatch.frame).minY ?? 0
            scrollMenu(app, up: e.exists ? e.frame.midY < top + 22 : i >= 12)
            Thread.sleep(forTimeInterval: 0.4)
        }
        return there()
    }

    /// The menu in front. A closed folder picker or share sheet leaves a list behind, off screen or
    /// as wide as the screen.
    static func menuList(_ app: XCUIApplication) -> XCUIElement? {
        let lists = app.collectionViews
        let window = app.windows.firstMatch.frame
        let all = (0..<lists.count).map { lists.element(boundBy: $0) }
        let shown = all.filter { !$0.frame.intersection(window).isEmpty && $0.identifier != "activityCollectionView" }
        return shown.last { $0.frame.width < window.width * 0.9 } ?? shown.last
    }

    /// Drags the menu in front up, inside the part of it on screen: on iPad a long submenu runs
    /// past the bottom, and XCUITest won't swipe an element whose middle is off screen.
    static func scrollMenu(_ app: XCUIApplication, up: Bool = false) {
        guard let list = menuList(app) else { return }
        let window = app.windows.firstMatch.frame
        // A swipe where XCUITest can: on iOS 18 a drag picks the row it's let go on, and one
        // starting below the rows closes the open submenu.
        if window.height >= 500, window.contains(list.frame) {
            if up { list.swipeDown(velocity: .slow) } else { list.swipeUp(velocity: .slow) }
            return
        }
        let shown = list.frame.intersection(window)
        guard shown.height > 100 else { return }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        // From the top: the list's frame can run below the menu, and a drag starting off the menu
        // closes it. A long one scrolls past rows.
        let travel = min(shown.height - 80, window.height < 500 ? 200 : 360)
        let (low, high) = (origin.withOffset(CGVector(dx: shown.midX, dy: shown.minY + 40 + travel)), origin.withOffset(CGVector(dx: shown.midX, dy: shown.minY + 40)))
        let (from, to) = up ? (high, low) : (low, high)
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    /// `waitForExistence` takes a second even when the element is already there: look first.
    static func shows(_ e: XCUIElement, within seconds: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if e.exists { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < end
        return false
    }

    // MARK: - State

    var state: [String: Any] { probe("app.state") }

    /// The same document (the item before tidied up after itself).
    func reset() {
        _ = probe("app.reset")
        Thread.sleep(forTimeInterval: 0.2)
    }

    /// Waits for background work, then closes whatever is open over the workspace: alerts,
    /// sheets, full-screen screens, system pickers. Starts the app again if that doesn't work.
    func settle() {
        tidying = true
        defer { tidying = false }
        let end = Date().addingTimeInterval(60)
        while (state["busy"] as? Bool) == true, Date() < end { Thread.sleep(forTimeInterval: 0.3) }
        for _ in 0..<6 {
            if !covered { return }
            _ = Self.shows(app.buttons["Cancel"].firstMatch, within: (state["presented"] as? String ?? "").contains("DocumentPicker") ? 4 : 0)
            let share = app.collectionViews["activityCollectionView"]
            if share.exists {
                // The system share sheet: its own close button, else a swipe down on it.
                let close = app.buttons.matching(NSPredicate(format: "label == 'Close' OR identifier == 'Close'")).firstMatch
                if close.exists, close.isHittable { close.tap() } else { app.windows.firstMatch.swipeDown(velocity: .fast) }
            } else if springboard.alerts.firstMatch.exists {
                // Keep the privacy-preserving answer.
                let a = springboard.alerts.firstMatch
                let no = a.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Don'")).firstMatch
                (no.exists ? no : a.buttons.element(boundBy: 0)).tap()
            } else if app.sheets.firstMatch.exists {
                let sheet = app.sheets.firstMatch
                let cancel = sheet.buttons["Cancel"]
                (cancel.exists ? cancel : sheet.buttons.element(boundBy: max(sheet.buttons.count - 1, 0))).tap()
            } else if app.alerts.firstMatch.exists {
                let a = app.alerts.firstMatch
                let cancel = a.buttons["Cancel"]
                (cancel.exists ? cancel : a.buttons.element(boundBy: max(a.buttons.count - 1, 0))).tap()
            } else if let cancel = ["Cancel", "pick.cancel", "Close", "close", "Done", "sheet.done"].lazy.map({ self.app.buttons[$0].firstMatch }).first(where: { $0.exists && $0.isHittable }) {
                cancel.tap()
            } else if app.navigationBars.firstMatch.exists, app.navigationBars.firstMatch.frame.height > 0 {
                app.navigationBars.firstMatch.swipeDown(velocity: .fast)
            } else if app.keyboards.firstMatch.exists {
                app.typeText("\n")
            } else {
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
            }
            Thread.sleep(forTimeInterval: 0.6)
        }
        // Home in front is fine: the next item's reset opens a document there.
        if covered || (!app.buttons["menu"].isHittable && !app.buttons["home.new"].exists) {
            writeRustCoverage()
            app.terminate()
            app.launch()
            if setup.hasPrefix("landscape") { XCUIDevice.shared.orientation = .landscapeLeft }
            _ = probe("app.reset")
            waitForCanvas()
        }
    }

    /// Something over the workspace: a sheet, alert or choice, a keyboard, a system alert. One
    /// query: each XCUITest query takes a snapshot of the whole app.
    var covered: Bool {
        let kinds: [XCUIElement.ElementType] = [.navigationBar, .alert, .sheet, .keyboard]
        let over = app.descendants(matching: .any).matching(NSPredicate(format: "elementType IN %@", kinds.map(\.rawValue)))
        // The system colour picker shows no navigation bar: its close button tells (on iPad, its popover).
        // Nor does the Files picker in landscape, and its Cancel comes late: the app knows.
        return over.count > 0 || springboard.alerts.count > 0 || app.collectionViews["activityCollectionView"].exists || app.buttons["close"].exists
            || (state["presented"] as? String ?? "").contains("DocumentPicker")
            || app.otherElements["PopoverDismissRegion"].exists
    }

    /// Whether the app did something between two states: a history step, a screen, a message,
    /// a document opened or closed, or a command sent.
    static func changed(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        for k in ["tutorial", "history", "request", "settings", "toast", "documents", "tool", "mode", "revision", "view", "canvas", "session", "presented", "timeline", "snap"] where "\(a[k] ?? "")" != "\(b[k] ?? "")" { return true }
        return (b["dispatched"] as? [String])?.count != (a["dispatched"] as? [String])?.count
            || (b["dispatched"] as? [String])?.last != (a["dispatched"] as? [String])?.last
    }

    /// A message a person sees must read as one.
    static func messageProblems(_ m: String?) -> [String] {
        guard let m else { return [] }
        var p: [String] = []
        if m.contains("panic") { p.append("panic: \(m)") }
        if m.contains("Some(") || m.contains("Err(") || m.range(of: #"`[a-z]+\.[A-Za-z.]+`"#, options: .regularExpression) != nil {
            p.append("developer text in the message: \(m)")
        }
        return p
    }
}
