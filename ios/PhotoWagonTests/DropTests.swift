import UIKit
import XCTest
@testable import PhotoWagon

/// Dropping a file on the app. A UI test can't drag
/// a file in from another app, so this drops a file-backed item on the model directly.
@MainActor
final class DropTests: XCTestCase {
    private func photo(_ name: String, _ size: CGSize) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        let png = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).pngData { c in
            UIColor.systemTeal.setFill()
            c.fill(CGRect(origin: .zero, size: size))
        }
        try png.write(to: url)
        return url
    }

    func testDroppingAFileOpensItThenDroppingOnTheCanvasPlacesIt() throws {
        let model = EditorModel()
        let first = try XCTUnwrap(NSItemProvider(contentsOf: try photo("dropped", CGSize(width: 64, height: 48))))
        XCTAssert(model.drop([first], place: false))
        wait("the dropped file opened") { model.doc?.width == 64 }
        XCTAssertEqual(model.doc?.height, 48)

        let second = try XCTUnwrap(NSItemProvider(contentsOf: try photo("layer", CGSize(width: 32, height: 32))))
        XCTAssert(model.drop([second], place: true))
        wait("the second file is placed, ready to transform") { model.transform != nil }
        model.commitPending()
        wait("as a layer of the same document") { model.layers.count == 2 }
        XCTAssertEqual(model.documents.count, 1, "not a second document")
    }
}
