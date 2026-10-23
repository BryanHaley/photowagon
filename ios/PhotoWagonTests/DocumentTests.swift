import UIKit
import XCTest
@testable import PhotoWagon

/// Documents as tabs, closing, Save / Save As and Recent (GettingStartedTests' workspace and
/// files walkthrough, without the sheets).
@MainActor
final class DocumentTests: XCTestCase {
    private func copy(_ name: String, to dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: sample(name), to: url)
        return url
    }

    func testEachDocumentKeepsItsOwnView() {
        let model = makeModel(width: 400, height: 300)
        XCTAssertFalse(model.showHome, "a new document goes to the workspace")
        model.zoom(by: 3, at: CGPoint(x: 100, y: 100))
        let first = model.view
        model.newDocument(["width": 2000, "height": 1000, "name": "second"])
        XCTAssertEqual(model.documents.count, 2)
        XCTAssertEqual(model.doc?.name, "second")
        XCTAssertEqual(model.view.zoom, model.fitZoom, accuracy: 0.0001, "the new document is fitted")
        model.activate(0)
        XCTAssertEqual(model.doc?.width, 400)
        XCTAssertEqual(model.view.zoom, first.zoom)
        XCTAssertEqual(model.view.centerX, first.centerX)
        XCTAssertEqual(model.view.centerY, first.centerY)
    }

    func testClosingAsksFirstOnlyWithUnsavedChanges() throws {
        let model = makeModel(width: 64, height: 64)
        let d = try XCTUnwrap(model.doc)
        XCTAssertFalse(model.isDirty(d), "an untouched new document closes without asking")
        model.closeActive()
        XCTAssertNil(model.doc)
        XCTAssertTrue(model.showHome, "nothing left open: Home")

        let dir = try tempFolder()
        model.open(url: try copy("subject.jpg", to: dir))
        wait("opened") { model.doc != nil && !model.busy }
        XCTAssertFalse(model.isDirty(try XCTUnwrap(model.doc)), "just opened")
        XCTAssertEqual(model.recents.first?.name, "subject.jpg", "opening a file lists it under Recent")
        model.newDocument(["width": 32, "height": 32])
        model.requestClose(0)
        XCTAssertNil(model.confirmClose)
        XCTAssertEqual(model.documents.map(\.name), ["Untitled"], "closed without asking")

        model.run("layer.new.layer")
        model.requestClose(0)
        XCTAssertEqual(model.confirmClose?.name, "Untitled", "asks first")
        XCTAssertEqual(model.documents.count, 1)
    }

    func testSaveGoesBackIntoAFileThatCanHoldTheDocument() throws {
        let model = makeModel(width: 64, height: 64)
        XCTAssertFalse(model.save(), "a new document asks where (Save As)")

        let dir = try tempFolder()
        let url = try copy("subject.jpg", to: dir)
        model.open(url: url)
        wait("opened") { model.doc?.name == "subject.jpg" && !model.busy }
        model.run("image.adjustments.invert")
        XCTAssertTrue(model.isDirty(try XCTUnwrap(model.doc)))
        let before = try Data(contentsOf: url)
        XCTAssertTrue(model.save(), "a one-layer JPEG saves in place")
        XCTAssertEqual(model.toast, "Saved subject.jpg")
        XCTAssertFalse(model.isDirty(try XCTUnwrap(model.doc)))
        XCTAssertNotEqual(try Data(contentsOf: url), before, "the file changed")

        model.run("layer.new.layer")
        XCTAssertFalse(model.save(), "layers don't fit in a JPEG: Save As")
    }

    func testSaveAsThenSaveInPlaceThenReopenFromRecent() throws {
        let model = makeModel(width: 64, height: 64)
        model.run("layer.new.layer")
        model.run("type.create", ["x": 10, "y": 40, "text": "link", "size": 12])
        let dir = try tempFolder()
        let url = dir.appendingPathComponent("poster.psd")
        try XCTUnwrap(model.export("psd")).write(to: url)
        model.savedAs(url)
        XCTAssertEqual(model.doc?.name, "poster.psd", "the tab shows the file name")
        XCTAssertEqual(model.toast, "Saved poster.psd")
        XCTAssertFalse(model.isDirty(try XCTUnwrap(model.doc)))
        XCTAssertEqual(model.recents.first?.name, "poster.psd")

        let text = try XCTUnwrap(model.row("link"))
        model.run("type.edit", ["layer": text.id, "text": "updated link"])
        model.closeAfterSave = true
        XCTAssertTrue(model.save(), "the second Save updates the file in place")
        XCTAssertNil(model.doc, "Save from the close prompt closes it")
        XCTAssertFalse(model.closeAfterSave)

        model.openRecent(try XCTUnwrap(model.recents.first))
        wait("reopened") { model.doc?.name == "poster.psd" && !model.busy }
        XCTAssertEqual(model.layerCount, 3, "the layers are intact: \(model.layers.map(\.name))")
        let id = try XCTUnwrap(model.layers.first { $0.kind == "Type" }?.id)
        XCTAssertEqual((model.query("type.info", ["layer": id]) as? [String: Any])?["text"] as? String, "updated link", "the edit was saved")
    }

    func testRecentIsDeduplicatedCappedAndKept() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "tests.\(UUID().uuidString)"))
        let model = EditorModel(defaults: defaults)
        model.newDocument(["width": 8, "height": 8])
        let dir = try tempFolder()
        for i in 0..<22 {
            let url = dir.appendingPathComponent("file\(i).png")
            try Data([0]).write(to: url)
            model.savedAs(url)
        }
        model.savedAs(dir.appendingPathComponent("file5.png"))
        XCTAssertEqual(model.recents.count, 20)
        XCTAssertEqual(model.recents.first?.name, "file5.png", "the latest first")
        XCTAssertEqual(model.recents.filter { $0.name == "file5.png" }.count, 1, "listed once")
        XCTAssertFalse(model.recents.contains { $0.name == "file0.png" }, "the oldest drop off")
        XCTAssertEqual(EditorModel(defaults: defaults).recents.map(\.name), model.recents.map(\.name), "kept for the next launch")
    }

    func testMissingFilesSaySo() {
        let model = makeModel()
        model.openRecent(RecentFile(name: "gone.psd", bookmark: Data([1, 2, 3]), date: Date()))
        XCTAssertEqual(model.toast, "gone.psd can't be found")
        model.open(url: URL(fileURLWithPath: "/nonexistent/missing.png"))
        XCTAssertEqual(model.toast, "Can't read missing.png")
        XCTAssertNil(model.doc)
    }

    func testApplesDecoderKeepsAPhotosOwnColours() throws {
        // CIRAWFilter also takes JPEG (and HEIC, AVIF, JPEG XL): it must not develop them like a raw.
        let jpeg = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { ctx in
            UIColor(red: 0.5, green: 0.47, blue: 0.25, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.jpegData(compressionQuality: 1))
        let tiff = try XCTUnwrap(AppleDecoder.tiff(jpeg, name: "photo.jpg"))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(tiff as CFData, nil))
        let profile = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyProfileName] as? String
        XCTAssertFalse(profile?.contains("ROMM") ?? false, "not developed into ProPhoto: \(profile ?? "no profile")")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var px = [UInt16](repeating: 0, count: 4)
        let ctx = try XCTUnwrap(CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 16, bytesPerRow: 8, space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(Double(px[0]) / 65535, 0.5, accuracy: 0.02, "red as stored, no raw tone curve")
    }

    func testAFileNoDecoderReadsSaysWhy() {
        let model = makeModel()
        model.open(data: Data("not an image".utf8), name: "broken.png")
        wait("tried") { !model.busy }
        XCTAssertNil(model.doc)
        XCTAssertNotNil(model.toast)
    }
    func testAppleDecodesWhatTheEngineCant() throws {
        // A HEIC photo: the engine has no HEIC decoder, Apple's opens it.
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { c in
            UIColor.systemRed.setFill()
            c.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        let heic = try XCTUnwrap(image.heicData())
        let model = makeModel()
        model.open(data: heic, name: "photo.heic")
        wait("opened") { model.doc != nil && !model.busy }
        XCTAssertEqual(model.toast, "Opened with Apple's decoder")
        XCTAssertEqual(model.doc?.width, 40)
        XCTAssertNil(AppleDecoder.tiff(Data("junk".utf8), name: "x.heic"))
    }

    func testNewDocumentSizesAndLimits() {
        XCTAssertEqual(NewDocumentSheet.pixels("1,920", unit: .pixels, resolution: "72"), 1920)
        XCTAssertEqual(NewDocumentSheet.pixels("6", unit: .inches, resolution: "300"), 1800, "the 6 × 4 in preset")
        XCTAssertEqual(NewDocumentSheet.pixels("2.54", unit: .centimeters, resolution: "100"), 100)
        XCTAssertEqual(NewDocumentSheet.pixels("abc", unit: .pixels, resolution: "72"), 0)
        XCTAssertEqual(NewDocumentSheet.problem(width: 0, height: 10), "Width and height must be at least 1 pixel.")
        XCTAssertEqual(NewDocumentSheet.problem(width: 300_001, height: 10), "Width and height can be at most 300,000 pixels.")
        XCTAssertNil(NewDocumentSheet.problem(width: 6000, height: 4000))
        XCTAssertTrue(NewDocumentSheet.presets.flatMap(\.1).contains { $0.name == "Landscape 6 × 4 in" && $0.width == 1800 && $0.height == 1200 })
        XCTAssertEqual(NewDocumentSheet.profiles["rgb"]?.first?.0, "srgb")
    }

    func testSaveAsOffersOnlyLayeredFormatsForSeveralLayers() {
        // GettingStartedTests: one layer offers every format; two only those that keep layers.
        XCTAssertTrue(SaveFormat.offered(copy: false, layerCount: 1).contains { $0.ext == "jpg" })
        let layered = SaveFormat.offered(copy: false, layerCount: 2).map(\.title)
        XCTAssertEqual(layered, ["PhotoCraft (default)", "Photoshop® (PSD)", "TIFF"])
        XCTAssertTrue(SaveFormat.offered(copy: true, layerCount: 2).contains { $0.ext == "jpg" }, "Save a Copy offers JPEG")
    }
}
