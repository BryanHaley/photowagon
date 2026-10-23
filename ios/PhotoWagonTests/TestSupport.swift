import UIKit
import XCTest
@testable import PhotoWagon

extension XCTestCase {
    /// Spin the main run loop until `done`, for work the model finishes off the main thread.
    @MainActor
    func wait(_ what: String, timeout: TimeInterval = 20, _ done: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssert(done(), what)
    }

    /// Wait for background work and live tries to finish.
    @MainActor
    func idle(_ model: EditorModel) {
        wait("the model is idle") { !model.busy && !model.liveBusy }
    }

    /// A file from the UI tests' samples.
    func sample(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PhotoWagonUITests/Samples/\(name)")
    }

    /// A model whose Recent list doesn't touch the app's.
    @MainActor
    func makeModel() -> EditorModel {
        let defaults = UserDefaults(suiteName: "tests.\(UUID().uuidString)") ?? .standard
        return EditorModel(defaults: defaults)
    }

    /// A model with a new document and a canvas of `canvas` pixels, fitted.
    @MainActor
    func makeModel(width: Int, height: Int, canvas: UInt32 = 1200) -> EditorModel {
        let model = makeModel()
        model.newDocument(["width": width, "height": height])
        model.canvasResized(width: canvas, height: canvas, scale: 3)
        return model
    }

    /// Open a sample file and wait for it.
    @MainActor
    func open(_ name: String, in model: EditorModel) {
        let before = model.documents.count
        model.open(url: sample(name))
        wait("\(name) opened") { model.documents.count > before && !model.busy }
    }

    /// A temporary folder of its own.
    func tempFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
}

@MainActor
extension EditorModel {
    var inspect: [String: Any] { query("document.inspect") as? [String: Any] ?? [:] }

    /// Every layer as `document.inspect` lists it, groups' layers after their group.
    var allLayerInfo: [[String: Any]] {
        func walk(_ l: [[String: Any]]) -> [[String: Any]] { l.flatMap { [$0] + walk($0["children"] as? [[String: Any]] ?? []) } }
        return walk(inspect["layers"] as? [[String: Any]] ?? [])
    }

    func info(_ name: String) -> [String: Any]? { allLayerInfo.first { $0["name"] as? String == name } }

    func row(_ name: String) -> LayerRow? { layers.first { $0.name == name } }

    /// Mean colour of the composite (or `rect` of it).
    func mean(_ rect: [Int]? = nil) -> [Double] {
        var p: [String: Any] = ["of": "composite"]
        if let rect { p["rect"] = rect }
        return (query("document.stats", p) as? [String: Any])?["mean"] as? [Double] ?? []
    }

    func stddev(_ rect: [Int]? = nil) -> Double {
        var p: [String: Any] = ["of": "composite"]
        if let rect { p["rect"] = rect }
        return ((query("document.stats", p) as? [String: Any])?["stddev"] as? [Double])?.first ?? -1
    }

    func pixel(_ x: Int, _ y: Int) -> [Double] {
        query("document.pixel", ["x": x, "y": y]) as? [Double] ?? []
    }

    var historyNames: [String] { inspect["history"] as? [String] ?? [] }
}

@MainActor
extension CanvasUIView {
    /// One finger from document point `a` to `b` with the current tool, in `steps` moves.
    func drag(_ a: Point, _ b: Point, steps: Int = 4, modifiers: UIKeyModifierFlags = [], alt: Bool = false) {
        gesture = (1, 0, false)
        let (p, q) = (toScreen(a), toScreen(b))
        var time = 100.0
        toolBegan(ToolTouch(p, time: time), modifiers: modifiers, alt: alt)
        for i in 1...max(steps, 1) {
            time += 0.1
            let f = CGFloat(i) / CGFloat(max(steps, 1))
            toolMoved(ToolTouch(CGPoint(x: p.x + (q.x - p.x) * f, y: p.y + (q.y - p.y) * f), time: time), modifiers: modifiers)
        }
        toolEnded(ToolTouch(q, time: time + 0.1), modifiers: modifiers)
    }

    /// A tap at document point `a`.
    func tap(_ a: Point, modifiers: UIKeyModifierFlags = [], alt: Bool = false) {
        gesture = (1, 0, false)
        let p = toScreen(a)
        toolBegan(ToolTouch(p, time: 100), modifiers: modifiers, alt: alt)
        toolEnded(ToolTouch(p, time: 100.1), modifiers: modifiers)
    }
}

func pt(_ x: Float, _ y: Float) -> Point { Point(x: x, y: y) }

/// Points equal to within `accuracy` (document points that went to the screen and back).
func XCTAssertNear(_ a: Point?, _ b: Point, accuracy: Float = 0.01, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard let a else { return XCTFail("nil, not \(b) \(message)", file: file, line: line) }
    XCTAssert(abs(a.x - b.x) <= accuracy && abs(a.y - b.y) <= accuracy, "\(a) is not \(b) \(message)", file: file, line: line)
}

extension Array {
    /// `nil` out of range, so a wrong result fails the test instead of crashing the app.
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
