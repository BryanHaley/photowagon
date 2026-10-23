import XCTest
@testable import PhotoWagon

/// The Remove tool's options and straight brush lines, through the canvas's gesture code.
@MainActor
final class RemoveTests: XCTestCase {
    private func canvas(tool: Tool) -> (EditorModel, CanvasUIView) {
        let model = makeModel(width: 400, height: 400)
        model.tool = tool
        let canvas = CanvasUIView(model: model)
        canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        model.setBrush("size", 12)
        return (model, canvas)
    }

    private func dark(_ model: EditorModel, _ x: Int, _ y: Int) -> Bool { (model.pixel(x, y).first ?? 1) < 0.5 }

    func testRemoveWithoutEachStrokeWaitsForCommitAndFillsTheEmptyLayer() {
        let (model, canvas) = canvas(tool: .brush)
        canvas.drag(pt(200, 60), pt(200, 340), steps: 12)
        XCTAssert(dark(model, 200, 200), "a black line")
        model.run("layer.new.layer", ["name": "fix"])
        model.tool = .remove
        model.setBrush("size", 30)
        model.sampleAllLayers = true
        model.removeEachStroke = false
        canvas.drag(pt(200, 50), pt(200, 200), steps: 6)
        canvas.drag(pt(200, 200), pt(200, 350), steps: 6)
        XCTAssertEqual(model.removeStrokes.count, 2)
        XCTAssert(model.hasPending)
        XCTAssert(dark(model, 200, 200), "nothing removed before Commit")
        model.commitPending()
        idle(model)
        XCTAssert(model.removeStrokes.isEmpty)
        XCTAssertFalse(dark(model, 200, 120))
        XCTAssertFalse(dark(model, 200, 280))
        XCTAssertEqual(model.historyNames.filter { $0 == "Quick Fill" }.count, 1, "one step: \(model.historyNames)")
        model.run("layer.setProps", ["layer": model.row("fix")?.id ?? 0, "visible": false])
        XCTAssert(dark(model, 200, 200), "the fill is on the new layer; the photo is as it was")
    }

    func testCancelDropsTheWaitingStrokes() {
        let (model, canvas) = canvas(tool: .remove)
        model.removeEachStroke = false
        canvas.tap(pt(100, 100))
        XCTAssertEqual(model.removeStrokes.count, 1)
        model.cancelPending()
        XCTAssert(model.removeStrokes.isEmpty)
        XCTAssertFalse(model.hasPending)
    }

    func testATapWithShiftOrStraightLineJoinsTheLastStroke() {
        let (model, canvas) = canvas(tool: .brush)
        canvas.tap(pt(60, 60))
        canvas.tap(pt(340, 340), modifiers: .shift)
        XCTAssert(dark(model, 200, 200), "⇧-tap: a line from the last dab")
        model.straightLine = true
        canvas.tap(pt(340, 60))
        XCTAssert(dark(model, 340, 200), "Straight Line: a line from the last end")
        XCTAssertFalse(dark(model, 100, 300))
    }

    func testShiftDragStaysLevel() {
        XCTAssertEqual(EditorModel.axisLocked(pt(200, 130), from: pt(100, 100)), pt(200, 100))
        XCTAssertEqual(EditorModel.axisLocked(pt(120, 300), from: pt(100, 100)), pt(100, 300))
        let (model, canvas) = canvas(tool: .brush)
        canvas.drag(pt(100, 100), pt(300, 160), steps: 8, modifiers: .shift)
        XCTAssert(dark(model, 290, 100))
        XCTAssertFalse(dark(model, 290, 157))
    }

    /// Fills every hole green.
    private struct Green: Inpainter {
        let side: Int
        func fill(image: Data, mask: Data) throws -> Data { Data((0..<side * side).flatMap { _ in [UInt8(0), 255, 0] }) }
    }

    func testAIRemoveFillsOnlyTheHoleWithTheModelsPicture() {
        let (model, canvas) = canvas(tool: .aiRemove)
        model.inpainterOverride = Green(side: 200)
        // Match Colour would blend the flat green away.
        model.aiMatchColor = false
        canvas.drag(pt(200, 160), pt(200, 240), steps: 6)
        idle(model)
        let px = model.pixel(200, 200)
        XCTAssertEqual(px.first ?? 1, 0, accuracy: 0.01)
        XCTAssertEqual(px.dropFirst().first ?? 0, 1, accuracy: 0.01, "the model's green, in the hole")
        XCTAssertEqual(model.pixel(150, 200).dropFirst().first ?? 0, 1, accuracy: 0.01, "white beside it")
        XCTAssertEqual(model.pixel(150, 200).first ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(model.historyNames.last, "AI Remove")

        model.removeEachStroke = false
        canvas.drag(pt(300, 300), pt(320, 300), steps: 3)
        XCTAssertEqual(model.pixel(310, 300).first ?? 0, 1, accuracy: 0.01, "waits for Commit")
        model.commitPending()
        idle(model)
        XCTAssertEqual(model.pixel(310, 300).first ?? 1, 0, accuracy: 0.01, "then fills with AI too")

        model.run("select.rect", ["x": 50, "y": 50, "width": 40, "height": 40])
        model.aiRemove(.selection)
        idle(model)
        XCTAssertEqual(model.pixel(70, 70).first ?? 1, 0, accuracy: 0.01, "the selection, filled")
        XCTAssertEqual(model.pixel(120, 70).first ?? 0, 1, accuracy: 0.01, "and only the selection")

        model.tool = .remove
        model.run("select.deselect")
        model.removeEachStroke = true
        canvas.drag(pt(100, 330), pt(140, 330), steps: 3)
        idle(model)
        XCTAssertEqual(model.pixel(120, 330).first ?? 0, 1, accuracy: 0.01, "the Remove tool still fills from the surroundings")
    }

    func testAIRemoveOffersTheDownloadFirst() throws {
        try XCTSkipIf(ModelDownload.shared.state == .ready, "the model is on this simulator")
        let (model, _) = canvas(tool: .aiRemove)
        let steps = model.historyNames.count
        model.aiRemove(.strokes([[Point(x: 100, y: 100)]]))
        XCTAssertEqual(model.aiRemoveWaiting, .strokes([[Point(x: 100, y: 100)]]), "the strokes wait for the download")
        XCTAssertEqual(model.historyNames.count, steps)
    }

    func testADamagedDownloadIsRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = dir.appendingPathComponent("model.zip")
        try Data("not a model".utf8).write(to: zip)
        XCTAssertThrowsError(try ModelDownload.install(zip: zip, into: dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("MIGAN.mlmodelc").path))
    }

    /// The real model, from a downloaded zip: `TEST_RUNNER_MODEL_ZIP=<path> xcodebuild test …`.
    func testTheRealModelRemovesThePerson() throws {
        guard let path = ProcessInfo.processInfo.environment["MODEL_ZIP"] else { throw XCTSkip("set TEST_RUNNER_MODEL_ZIP") }
        let dir = try tempFolder()
        let zip = URL(fileURLWithPath: path)
        try ModelDownload.install(zip: zip, into: dir)
        let model = makeModel()
        model.inpainterOverride = CoreMLInpainter(url: dir.appendingPathComponent("MIGAN.mlmodelc"), side: ModelDownload.side)
        let photo = dir.appendingPathComponent("seaside.jpg")
        try FileManager.default.copyItem(at: sample("seaside.jpg"), to: photo)
        model.open(url: photo)
        wait("opened") { model.doc?.name == "seaside.jpg" && !model.busy }
        XCTAssertLessThan(model.pixel(700, 700).first ?? 1, 0.4, "the dark shorts")
        // Wide enough to be scaled down to the model's square and back.
        model.setBrush("size", 400)
        model.aiRemove(.strokes([[Point(x: 700, y: 330), Point(x: 700, y: 800)]]))
        wait("filled", timeout: 120) { !model.busy && model.historyNames.last == "AI Remove" }
        XCTAssertGreaterThan(model.pixel(700, 700).first ?? 0, 0.5, "sand and water instead")
        if let out = ProcessInfo.processInfo.environment["MODEL_OUT"], let png = try? model.editor.export(format: "png", quality: nil) {
            try png.write(to: URL(fileURLWithPath: out))
        }

        // A person filling most of a sky: scaled down, and the fill takes the sky's colour.
        let portrait = dir.appendingPathComponent("red-hair.jpg")
        try FileManager.default.copyItem(at: sample("red-hair.jpg"), to: portrait)
        model.open(url: portrait)
        wait("opened") { model.doc?.name == "red-hair.jpg" && !model.busy }
        let skin = model.pixel(700, 1300)
        XCTAssertGreaterThan(skin[0], skin[2], "skin: redder than it's blue")
        model.run("select.lasso", ["points": [[413, 1033], [465, 654], [671, 482], [912, 482], [981, 878], [1153, 1084], [1212, 1618], [516, 1618], [482, 1205]]])
        model.aiRemove(.selection)
        wait("filled", timeout: 120) { !model.busy && model.historyNames.last == "AI Remove" }
        let filled = model.pixel(700, 1300)
        XCTAssertGreaterThan(filled[2], filled[0] + 0.3, "blue sky instead: \(filled)")
        if let out = ProcessInfo.processInfo.environment["MODEL_OUT2"], let png = try? model.editor.export(format: "png", quality: nil) {
            try png.write(to: URL(fileURLWithPath: out))
        }
    }

    /// Compares inpainting models on the same removals:
    /// `TEST_RUNNER_AB_MODELS="lama=<LaMa.mlmodelc>@800;migan=<MIGAN.mlmodelc>@512" TEST_RUNNER_AB_OUT=<folder>`.
    func testCompareInpaintingModels() throws {
        let env = ProcessInfo.processInfo.environment
        guard let spec = env["AB_MODELS"], let out = env["AB_OUT"] else { throw XCTSkip("set TEST_RUNNER_AB_MODELS and TEST_RUNNER_AB_OUT") }
        let dir = try tempFolder()
        // Each object covered whole, as a careful person would paint or lasso it.
        let lasso = { (points: [[Int]]) in { (m: EditorModel) -> AIRemoveRequest in m.run("select.lasso", ["points": points]); return .selection } }
        let cases: [(name: String, photo: String, remove: (EditorModel) -> AIRemoveRequest)] = [
            ("beach-person", "seaside.jpg", { m in
                m.setBrush("size", 200)
                let body = [Point(x: 705, y: 320), Point(x: 705, y: 870)]
                return .strokes([body, [Point(x: 520, y: 615), Point(x: 705, y: 470), Point(x: 925, y: 620)]])
            }),
            ("sky-balloon", "seaside.jpg", lasso([[1180, 120], [1400, 120], [1400, 300], [1180, 300]])),
            ("skin-patch", "red-hair.jpg", { m in m.setBrush("size", 22); return .strokes([[Point(x: 690, y: 1270), Point(x: 705, y: 1330)]]) }),
            ("people-on-sand", "beach.jpg", { m in m.setBrush("size", 95); return .strokes([[Point(x: 525, y: 395), Point(x: 525, y: 605)], [Point(x: 830, y: 400), Point(x: 830, y: 590)]]) }),
            ("red-hair", "red-hair.jpg", lasso([[396, 1033], [441, 637], [661, 454], [929, 465], [998, 861], [1170, 1067], [1226, 1618], [499, 1618], [458, 1205]])),
            ("dog-on-grass", "subject.jpg", lasso([[330, 40], [430, 50], [480, 90], [580, 90], [620, 80], [740, 110], [720, 220], [690, 400], [660, 560], [660, 760], [700, 860], [770, 920], [760, 960], [690, 1000], [690, 1160], [580, 1180], [540, 1080], [450, 1040], [410, 1120], [300, 1130], [280, 960], [230, 840], [120, 800], [50, 680], [100, 610], [200, 620], [260, 500], [300, 340], [320, 180]])),
        ]
        for entry in spec.split(separator: ";") {
            let parts = entry.split(separator: "=", maxSplits: 1)
            let (name, rest) = (String(parts[0]), parts[1].split(separator: "@"))
            for c in cases {
                let model = makeModel()
                model.aiMatchColor = env["AB_MATCH"] != "0"
                model.inpainterOverride = CoreMLInpainter(url: URL(fileURLWithPath: String(rest[0])), side: Int(rest[1]) ?? 512)
                let photo = dir.appendingPathComponent(c.photo)
                if !FileManager.default.fileExists(atPath: photo.path) { try FileManager.default.copyItem(at: sample(c.photo), to: photo) }
                model.open(url: photo)
                wait("opened") { model.doc?.name == c.photo && !model.busy }
                let what = c.remove(model)
                let start = Date()
                model.aiRemove(what)
                wait("filled", timeout: 180) { !model.busy && model.historyNames.last == "AI Remove" }
                print("AB \(name) \(c.name): \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
                let png = try model.editor.export(format: "png", quality: nil)
                try png.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name)-\(c.name).png"))
            }
        }
    }
}
