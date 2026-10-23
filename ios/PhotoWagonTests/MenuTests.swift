import SwiftUI
import XCTest
@testable import PhotoWagon

/// The ☰ menu built from the engine's commands, what its items open, and a command's settings
/// screen (GettingStartedTests' menu bar steps).
@MainActor
final class MenuTests: XCTestCase {
    private func command(_ id: String, label: String = "", menu: String = "", params: String = "") -> CommandInfo {
        CommandInfo(id: id, label: label, menu: menu, enabled: true, reason: nil, params: params)
    }

    private func titles(_ e: [UIMenuElement]) -> [String] { e.compactMap { ($0 as? UIMenu)?.title ?? ($0 as? UIAction)?.title } }

    private func flat(_ e: [UIMenuElement]) -> [UIMenuElement] {
        e.flatMap { ($0 as? UIMenu).map { [$0] + flat($0.children) } ?? [$0] }
    }

    func testTheMenusFollowPhotoshopsOrderAndHideWhatCantRunHere() throws {
        let model = makeModel()
        let all = model.editor.commands()
        let tree = MenuTree(all)
        XCTAssertEqual(tree.top.map(\.name), MenuTree.order)
        let blur = try XCTUnwrap(tree.top.first { $0.name == "Filter" }?.children.first { $0.name == "Blur" })
        XCTAssertTrue(blur.commands.contains { $0.id == "filter.blur.gaussianBlur" })
        let file = try XCTUnwrap(tree.top.first { $0.name == "File" })
        func ids(_ n: MenuTree.Node) -> [String] { n.commands.map(\.id) + n.children.flatMap(ids) }
        XCTAssertFalse(ids(file).contains("file.new"), "the app lists its own New")
        XCTAssertFalse(ids(file).contains("file.saveAs"))

        XCTAssertTrue(MenuTree.shows(command("layer.layerStyle.dropShadow")), "Layer Style keeps its place")
        XCTAssertTrue(MenuTree.shows(command("filter.cameraRaw")))
        XCTAssertTrue(MenuTree.shows(command("edit.preferences.general")), "Preferences › General keeps its place")
        XCTAssertFalse(MenuTree.shows(command("file.closeAll")))
        XCTAssertFalse(MenuTree.shows(command("file.export.layersToFiles", params: #"{"dir":folder}"#)), "needs a desktop folder")
        XCTAssertTrue(MenuTree.shows(command("file.importX", params: #"{"path":str,"data":b64}"#)), "takes the file's data too")
        XCTAssertTrue(all.filter(MenuTree.shows).allSatisfy { !$0.params.contains(#""path":str"#) || $0.params.contains(#""data""#) })
    }

    func testCommandsWithAScreenOfTheirOwn() {
        XCTAssertEqual(EditorModel.request(for: "file.new"), .newDocument)
        XCTAssertEqual(EditorModel.request(for: "file.placeLinked"), .placeFiles)
        XCTAssertEqual(EditorModel.request(for: "window.toggle.history"), .panel(.history))
        XCTAssertEqual(EditorModel.request(for: "layer.layerStyle.dropShadow"), .layerStyle("dropShadow"))
        XCTAssertEqual(EditorModel.request(for: "layer.layerStyle.blendingOptions"), .layerStyle("blendingOptions"))
        XCTAssertNil(EditorModel.request(for: "layer.layerStyle.clear"))
        XCTAssertNil(EditorModel.request(for: "filter.blur.gaussianBlur"))
        XCTAssertTrue(ContentView.isLive(command("filter.blur.gaussianBlur", menu: "Filter > Blur")))
        XCTAssertTrue(ContentView.isLive(command("image.adjustments.levels", menu: "Image > Adjustments")))
        XCTAssertFalse(ContentView.isLive(command("image.imageSize", menu: "Image")))
    }

    func testTheAppsOwnItemsAndWhatTheyOpen() throws {
        let model = makeModel()
        let menu = MainMenu(model: model)
        let file = flat(menu.items("File"))
        let close = try XCTUnwrap(file.compactMap { $0 as? UIAction }.first { $0.title == "Close" })
        XCTAssertTrue(close.attributes.contains(.disabled), "nothing open")

        let dir = try tempFolder()
        let url = dir.appendingPathComponent("a.png")
        try Data([0]).write(to: url)
        model.newDocument(["width": 8, "height": 8])
        model.savedAs(url)
        let again = flat(menu.items("File"))
        XCTAssertTrue(Set(titles(again)).isDisjoint(with: ["New…", "Open…", "Open from Photos…", "Open Recent"]), "those are on Home")
        XCTAssertFalse(try XCTUnwrap(again.compactMap { $0 as? UIAction }.first { $0.title == "Close" }).attributes.contains(.disabled))

        let filter = menu.items("Filter")
        XCTAssertEqual((filter.first as? UIMenu)?.options.contains(.displayInline), true, "Filter's own filters first")
        XCTAssertTrue(titles(flat(menu.items("Edit"))).contains("Free Transform"))
        XCTAssertTrue(titles(flat(menu.items("View"))).contains("Canvas Colour"))
        XCTAssertEqual(titles(menu.items("Window")).count, 1)
        XCTAssertTrue(menu.items("Nothing").isEmpty)

        menu.run(command("file.new", label: "New…"))
        XCTAssertEqual(model.request, .newDocument)
        menu.run(try XCTUnwrap(model.editor.commands().first { $0.id == "filter.blur.gaussianBlur" }))
        XCTAssertEqual(model.commandSettings?.id, "filter.blur.gaussianBlur", "… asks for its settings")
        model.run("layer.new.layer")
        menu.run(command("edit.puppetWarp"))
        XCTAssertNotNil(model.puppet)
        model.cancelPending()
        menu.run(try XCTUnwrap(model.editor.commands().first { $0.id == "image.adjustments.invert" }))
        idle(model)
        XCTAssertEqual(model.historyNames.last, "Invert", "no settings: it runs")
    }

    func testSettingsStartFromTheFieldsAndGiveWholeNumbersAsIntegers() {
        let fields = [
            ParamField(name: "radius", kind: .number(min: 0, max: 1000, value: 2.5, whole: false)),
            ParamField(name: "amount", kind: .number(min: 0, max: 100, value: 10, whole: true)),
            ParamField(name: "distribution", kind: .choice(options: ["uniform", "gaussian"], value: "uniform")),
            ParamField(name: "monochromatic", kind: .toggle(value: false)),
            ParamField(name: "name", kind: .text(value: "")),
        ]
        let d = CommandSettings.defaults(fields: fields, initial: ["amount": 40, "distribution": "gaussian"])
        XCTAssertEqual(d.numbers, ["radius": 2.5, "amount": 40])
        XCTAssertEqual(d.choices, ["distribution": "gaussian"])
        XCTAssertEqual(d.toggles, ["monochromatic": false])
        let p = CommandSettings.params(numbers: d.numbers, choices: d.choices, toggles: d.toggles, texts: d.texts)
        XCTAssertEqual(p["amount"] as? Int, 40, "a whole number goes as an integer")
        XCTAssertEqual(p["radius"] as? Double, 2.5)
        XCTAssertNil(p["name"], "an empty text is left out")
        XCTAssertEqual(p["monochromatic"] as? Bool, false)
        XCTAssertEqual(CommandSettings.title("preserveLuminosity"), "Preserve luminosity")
        XCTAssertEqual(CommandSettings.title("radius"), "Radius")
    }

    func testWideSlidersGiveSmallValuesMoreTravel() {
        var value = 10.0
        let binding = Binding(get: { value }, set: { value = $0 })
        let wide = CommandSettings.curved(binding, 0, 1000)
        XCTAssertEqual(wide.wrappedValue, pow(0.01, 1.0 / 3), accuracy: 0.0001)
        wide.wrappedValue = 0.5
        XCTAssertEqual(value, 125, accuracy: 0.0001)
        let narrow = CommandSettings.curved(binding, -100, 100)
        narrow.wrappedValue = 0.75
        XCTAssertEqual(value, 50, accuracy: 0.0001, "straight when the range crosses zero")
        value = 5000
        XCTAssertEqual(wide.wrappedValue, 1, "kept on the slider")
    }
}
