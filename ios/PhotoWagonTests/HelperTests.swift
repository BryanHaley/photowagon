import SwiftUI
import XCTest
@testable import PhotoWagon

/// Small pieces the panels lean on.
@MainActor
final class HelperTests: XCTestCase {
    func testTheAppCarriesEveryLicence() throws {
        let ack = try XCTUnwrap(Acknowledgements.load(), "Acknowledgements.json is in the app")
        let entries = ack.groups.flatMap(\.entries)
        let libRaw = try XCTUnwrap(entries.first { $0.name == "LibRaw" })
        XCTAssertEqual(libRaw.license, "CDDL 1.0")
        XCTAssertTrue(libRaw.note.contains("submodules/LibRaw"))
        XCTAssertTrue(ack.texts(of: libRaw).contains { $0.contains("COMMON DEVELOPMENT AND DISTRIBUTION LICENSE") })
        XCTAssertTrue(ack.texts(of: libRaw).contains { $0.contains("Roland Karlsson") }, "X3F's BSD terms")
        for name in ["PhotoCraft", "libjxl", "MI-GAN", "X.Org colour names", "Rust standard library"] {
            XCTAssertNotNil(entries.first { $0.name == name }, name)
        }
        XCTAssertNotNil(entries.first { $0.name.hasPrefix("uniffi ") })
        XCTAssertTrue(entries.allSatisfy { !$0.texts.isEmpty && $0.texts.allSatisfy(ack.texts.indices.contains) }, "every entry has its texts")
    }

    func testLicenceTextsReflowIntoParagraphs() {
        let mit = "MIT License\n\nCopyright (c) A\nCopyright (c) B\n\nPermission is hereby granted, to any\nperson obtaining a copy.\n"
        XCTAssertEqual(Acknowledgements.reflow(mit), "MIT License\n\nCopyright (c) A\nCopyright (c) B\n\nPermission is hereby granted, to any person obtaining a copy.\n")
        let numbered = "                  Apache License\n            Version 2.0\n\n   1. Definitions.\n      \"License\" shall\n      mean.\n   2. Grant.\n"
        XCTAssertEqual(Acknowledgements.reflow(numbered), "Apache License\nVersion 2.0\n\n1. Definitions. \"License\" shall mean.\n2. Grant.\n")
        XCTAssertEqual(Acknowledgements.reflow("1. Definitions\n--------------\n1.1. Contributor\n"), "1. Definitions\n1.1. Contributor\n", "rules dropped")
    }

    func testColoursAsHex() {
        XCTAssertEqual(UIColor(red: 1, green: 0.5, blue: 0, alpha: 1).hex, "#ff8000")
        XCTAssertEqual(UIColor(red: 1.2, green: -0.1, blue: 0, alpha: 1).hex, "#ff0000", "clamped")
        XCTAssertEqual(UIColor(rgba: [0, 0, 1]).hex, "#0000ff", "a missing alpha is opaque")
        var a: CGFloat = 0
        UIColor(rgba: [0, 0, 1]).getRed(nil, green: nil, blue: nil, alpha: &a)
        XCTAssertEqual(a, 1)
        XCTAssertEqual(UIColor(Color(hex: "#336699")).hex, "#336699")
        XCTAssertEqual(UIColor(Color(hex: "nonsense")).hex, "#000000")
    }

    func testAdjustmentNamesAndNeutralFills() {
        XCTAssertEqual(AdjustmentKinds.label("hueSaturation"), "Hue/Saturation")
        XCTAssertEqual(AdjustmentKinds.label("future"), "Adjustment")
        XCTAssertEqual(AdjustmentKinds.symbol("exposure"), "sun.max")
        XCTAssertEqual(AdjustmentKinds.symbol("future"), "circle.righthalf.filled")
        // LayersTests: New Layer, Overlay, filled with 50% gray.
        XCTAssertTrue(NewLayerSheet.hasNeutral("Overlay"))
        XCTAssertFalse(NewLayerSheet.hasNeutral("Normal"))
    }

    func testEveryToolIsInOneGroup() {
        let grouped = Tool.groups.flatMap { $0 }
        XCTAssertEqual(grouped.count, Tool.allCases.count)
        XCTAssertEqual(Set(grouped), Set(Tool.allCases), "each tool once in the toolbox")
        // Tools with a key: the key picks them (Single Row, Blur and a few others have none).
        let keyed = Set(makeModel().editor.keyBindings().filter { $0.kind == "tool" }.map(\.id))
        XCTAssertTrue([Tool.move, .brush, .type, .eraser, .crop, .lasso].allSatisfy { keyed.contains($0.engineId) })
        XCTAssertTrue(Tool.allCases.allSatisfy { !$0.title.isEmpty && !$0.help.isEmpty })
    }

    func testTheAppFolderListsOpenableFilesNewestFirst() throws {
        let names = ["old-\(UUID().uuidString).png", "new-\(UUID().uuidString).psd", "notes-\(UUID().uuidString).txt"]
        let urls = names.map { AppFolder.url.appendingPathComponent($0) }
        addTeardownBlock { for u in urls { try? FileManager.default.removeItem(at: u) } }
        for (i, u) in urls.enumerated() {
            try Data([0]).write(to: u)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(i) * 60)], ofItemAtPath: u.path)
        }
        let listed = AppFolder.files().map(\.lastPathComponent).filter(names.contains)
        XCTAssertEqual(listed, [names[1], names[0]], "newest first, no .txt")
        XCTAssertEqual(AppFolder.files(["txt"]).map(\.lastPathComponent).filter(names.contains), [names[2]])
    }

    func testCanvasColour() {
        let model = makeModel()
        let saved = model.canvasColor
        addTeardownBlock { @MainActor in model.canvasColor = saved }
        // GettingStartedTests picks Light Gray; the custom colour is tested here.
        model.canvasColor = .lightGray
        XCTAssertEqual(UserDefaults.standard.string(forKey: "canvasColor"), "lightGray", "kept for the next launch")
        let custom = CanvasColor.customRGB
        addTeardownBlock { CanvasColor.customRGB = custom }
        model.setCustomCanvas([0.2, 0.4, 0.6])
        XCTAssertEqual(model.canvasColor, .custom)
        XCTAssertEqual(CanvasColor.custom.rgb, [0.2, 0.4, 0.6])
        XCTAssertEqual(CanvasColor.allCases.map(\.title).last, "Custom…")
    }

    /// Picking a tool says its name for a moment.
    func testPickingAToolNamesIt() {
        let model = makeModel(width: 40, height: 30)
        model.tool = .polygonLasso
        XCTAssertEqual(model.hint, "Polygonal Lasso")
        model.hint = nil
        model.tool = .polygonLasso
        XCTAssertNil(model.hint, "the same tool again says nothing")
    }
}
