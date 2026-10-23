import ImageIO
import XCTest
@testable import PhotoWagon

/// Export As at several sizes, Quick Export of layers, and recovery copies (SaveExportTests' model side).
@MainActor
final class ExportTests: XCTestCase {
    private func pixelWidth(_ url: URL) -> Int? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        return props[kCGImagePropertyPixelWidth] as? Int
    }

    private func remove(_ files: [String]) {
        for f in files { try? FileManager.default.removeItem(at: AppFolder.url.appendingPathComponent(f)) }
    }

    func testExportFileNamesBySize() {
        XCTAssertEqual(EditorModel.exportFileName("logo", scale: 1, ext: "png"), "logo.png")
        XCTAssertEqual(EditorModel.exportFileName("logo", scale: 2, ext: "png"), "logo@2x.png")
        XCTAssertEqual(EditorModel.exportFileName("logo", scale: 0.5, ext: "jpg"), "logo@0.5x.jpg")
    }

    func testExportAsWritesOneFilePerSize() {
        let model = makeModel(width: 200, height: 100)
        let files = ["sizes-test.png", "sizes-test@2x.png", "sizes-test@0.5x.png"]
        remove(files)
        addTeardownBlock { [files] in Task { @MainActor in self.remove(files) } }
        model.exportAs(name: "sizes-test", prefs: ["quickExportFormat": "png"], width: 300, scales: [1, 2, 0.5], transparency: true)
        idle(model)
        let widths = files.map { pixelWidth(AppFolder.url.appendingPathComponent($0)) }
        XCTAssertEqual(widths, [300, 600, 150])
        XCTAssertEqual(model.doc?.width, 200, "the document keeps its size")
    }

    func testExportAsJPEGXLWritesOneFilePerSizeThatOpensAgain() throws {
        let model = makeModel(width: 120, height: 80)
        model.exportAs(name: "jxl-test", prefs: ["quickExportFormat": "jxl", "jxlLossless": true, "convertToSrgb": true], width: 120, scales: [1, 0.5], transparency: true)
        idle(model)
        for (file, width) in [("jxl-test.jxl", 120), ("jxl-test@0.5x.jxl", 60)] {
            let url = AppFolder.url.appendingPathComponent(file)
            let data = try Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
            let reopened = makeModel()
            XCTAssertNil(try EditorModel.load(reopened.editor, data, file), "\(file) opens in our own engine (libjxl)")
            XCTAssertEqual(reopened.editor.document()?.width, UInt32(width), file)
        }
    }

    func testSaveACopyAsJPEGXLKeepsTheDepthAndPixels() throws {
        let model = makeModel(width: 40, height: 30)
        model.run("image.mode.bits16")
        model.run("select.rect", ["x": 0, "y": 0, "width": 20, "height": 30])
        model.run("edit.fill", ["contents": "black"])
        let data = try XCTUnwrap(model.exportJXL(lossless: true, quality: 90, effort: 3))
        let lossy = try XCTUnwrap(model.exportJXL(lossless: false, quality: 50, effort: 3))
        XCTAssertLessThan(lossy.count, data.count * 2, "lossy at 50 is no bigger than about the lossless file")
        let reopened = makeModel()
        XCTAssertNil(try EditorModel.load(reopened.editor, data, "copy.jxl"))
        reopened.sync()
        XCTAssertEqual((reopened.query("document.inspect") as? [String: Any])?["depth"] as? Int, 16, "16-bit stays 16-bit")
        let mean = { (rect: [Int]) in ((reopened.query("document.stats", ["rect": rect]) as? [String: Any]).flatMap { numbers($0["mean"]) })?.first ?? -1 }
        XCTAssertEqual(mean([2, 2, 18, 28]), 0, accuracy: 0.0001, "black where it was filled")
        XCTAssertEqual(mean([22, 2, 38, 28]), 1, accuracy: 0.0001, "white elsewhere")
    }

    func testQuickExportLayersWritesEachLayer() throws {
        let model = makeModel(width: 100, height: 100)
        for name in ["cake-test", "teapot-test"] {
            model.run("layer.new.layer", ["name": name])
            model.run("edit.fill")
        }
        let files = ["cake-test.png", "teapot-test.png"]
        remove(files)
        addTeardownBlock { [files] in Task { @MainActor in self.remove(files) } }
        model.exportLayers([try XCTUnwrap(model.row("cake-test")?.id), try XCTUnwrap(model.row("teapot-test")?.id)])
        idle(model)
        XCTAssertEqual(files.map { FileManager.default.fileExists(atPath: AppFolder.url.appendingPathComponent($0).path) }, [true, true])
    }

    func testRecoveryCopiesComeBackAfterARunEndsAndGoWhenSaved() throws {
        let root = try tempFolder()
        let first = makeModel(width: 120, height: 80)
        first.recoveryRoot = root
        first.saveRecovery(wait: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 0, "nothing new to keep")

        first.run("edit.fill")
        first.recoveryMinutes = 0
        first.saveRecovery(wait: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 0, "off")
        first.recoveryMinutes = 5
        first.lastRecovery = Date()
        first.recoveryTick()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 0, "not five minutes yet")
        first.recoveryTick(now: Date().addingTimeInterval(301))
        wait("the copy is written") { (try? FileManager.default.subpathsOfDirectory(atPath: root.path))?.contains { $0.hasSuffix(".pcraft") } == true }

        // The next run lists it; opening it brings the image back and drops the copy.
        let next = makeModel()
        next.recoveryRoot = root
        next.loadRecovered()
        let r = try XCTUnwrap(next.recovered.first)
        XCTAssertEqual(next.recovered.count, 1)
        next.openRecovered(r)
        wait("opened") { next.doc != nil && !next.busy }
        XCTAssertEqual(next.doc?.width, 120)
        XCTAssert(next.recovered.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.url.path))

        // Closing (or saving) a document removes its copy.
        first.run("edit.fill")
        first.saveRecovery(wait: true)
        first.closeActive()
        XCTAssertNil((try? FileManager.default.subpathsOfDirectory(atPath: root.path))?.first { $0.hasSuffix(".pcraft") })
    }

    func testHomeKeepsTheNewestTenRecoveryCopies() throws {
        let root = try tempFolder()
        let next = makeModel()
        next.recoveryRoot = root
        for i in 0..<12 {
            let run = root.appendingPathComponent("old-\(i)")
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
            let f = run.appendingPathComponent("doc.pcraft")
            try Data([0]).write(to: f)
            try "doc \(i)".write(to: f.appendingPathExtension("name"), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(-i * 60))], ofItemAtPath: f.path)
        }
        next.loadRecovered()
        XCTAssertEqual(next.recovered.map(\.name), (0..<10).map { "doc \($0)" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("old-11").path), "the oldest is gone")

    }
}
