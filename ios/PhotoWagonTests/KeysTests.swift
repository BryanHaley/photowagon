import UIKit
import XCTest
@testable import PhotoWagon

/// Keyboard shortcuts (GettingStartedTests' testKeyboardShortcuts and its V, B, T, X steps).
@MainActor
final class KeysTests: XCTestCase {
    private func key(_ value: String, shift: Bool = false) -> UIKeyCommand {
        UIKeyCommand(title: "", action: #selector(CanvasUIView.keyPressed(_:)), input: "x", modifierFlags: shift ? .shift : [], propertyList: value)
    }

    func testShortcutsParse() throws {
        let plus = try XCTUnwrap(Keys.parse("Cmd++"))
        XCTAssertEqual(plus.input, "+")
        XCTAssertEqual(plus.flags, .command)
        let f5 = try XCTUnwrap(Keys.parse("Shift+F5"))
        XCTAssertEqual(f5.input, UIKeyCommand.f5)
        XCTAssertEqual(f5.flags, .shift)
        XCTAssertEqual(Keys.parse("Ctrl+Alt+Shift+N")?.input, "n")
        XCTAssertEqual(Keys.parse("Ctrl+Alt+Shift+N")?.flags, [.control, .alternate, .shift])
        XCTAssertEqual(Keys.parse("Escape")?.input, UIKeyCommand.inputEscape)
        XCTAssertNil(Keys.parse("Hyper+K"), "an unknown modifier")
        XCTAssertNil(Keys.parse("Cmd+Fn"), "an unknown key name")
    }

    func testEachKeyGoesToTheFirstBindingWithItsShiftVariantForTools() {
        let bindings = [
            KeyBinding(id: "tools.select.move", label: "Move", shortcut: "V", kind: "tool"),
            KeyBinding(id: "tools.select.artboard", label: "Artboard", shortcut: "V", kind: "tool"),
            KeyBinding(id: "view.zoomIn", label: "Zoom In", shortcut: "Cmd++", kind: "command"),
            KeyBinding(id: "edit.undo", label: "Undo", shortcut: "Cmd+Z", kind: "command"),
            KeyBinding(id: "edit.other", label: "Other", shortcut: "Cmd+Z", kind: "command"),
            KeyBinding(id: "tools.select.unknown", label: "Unknown", shortcut: "Q", kind: "tool"),
            KeyBinding(id: "x", label: "Panel", shortcut: "F7", kind: "panel"),
        ]
        let keys = Keys.commands(bindings, action: #selector(CanvasUIView.keyPressed(_:)))
        let values = keys.compactMap { $0.propertyList as? String }
        XCTAssertEqual(values, ["app:commit", "app:cancel", "tool:tools.select.move", "tool:tools.select.move", "shell:view.zoomIn", "command:edit.undo"])
        XCTAssertEqual(keys[safe: 3]?.modifierFlags, .shift, "⇧V steps through the V tools")
        XCTAssertTrue(keys.allSatisfy(\.wantsPriorityOverSystemBehavior))
    }

    func testToolKeysPickAndCycleTheirGroup() {
        let model = makeModel(width: 100, height: 100)
        let canvas = CanvasUIView(model: model)
        canvas.keyPressed(key("tool:tools.select.move"))
        XCTAssertEqual(model.tool, .move)
        canvas.keyPressed(key("tool:tools.select.brush"))
        XCTAssertEqual(model.tool, .brush)
        canvas.keyPressed(key("tool:tools.select.brush"))
        XCTAssertEqual(model.tool, .brush, "the key again keeps the tool")
        canvas.keyPressed(key("tool:tools.select.brush", shift: true))
        XCTAssertNotEqual(model.tool, .brush, "⇧ steps to the next tool on the key")
        let shared = Tool.groups.first { $0.contains(.brush) } ?? []
        XCTAssertTrue(shared.contains(model.tool), "\(model.tool)")
        canvas.keyPressed(key("tool:tools.select.type"))
        XCTAssertEqual(model.tool, .type)
        canvas.selectTool("tools.select.nothing", next: false)
        XCTAssertEqual(model.tool, .type)
    }

    func testCommandAndShellKeys() {
        let model = makeModel(width: 400, height: 400)
        let canvas = CanvasUIView(model: model)
        let fit = model.view.zoom
        canvas.keyPressed(key("shell:view.zoomIn"))
        XCTAssertEqual(model.view.zoom, fit * 1.5, accuracy: 0.0001, "⌘+")
        canvas.keyPressed(key("shell:view.zoomOut"))
        canvas.keyPressed(key("shell:view.zoomOut"))
        XCTAssertLessThan(model.view.zoom, fit)
        canvas.keyPressed(key("shell:view.fitOnScreen"))
        XCTAssertEqual(model.view.zoom, fit, "⌘0 fits")
        canvas.keyPressed(key("shell:view.actualPixels"))
        XCTAssertEqual(model.view.zoom, 1, accuracy: 0.0001)

        model.run("layer.new.layer")
        canvas.keyPressed(key("command:edit.undo"))
        XCTAssertEqual(model.layerCount, 1, "⌘Z")
        canvas.keyPressed(key("command:edit.redo"))
        XCTAssertEqual(model.layerCount, 2, "⇧⌘Z")
        canvas.keyPressed(key("command:file.save"))
        XCTAssertEqual(model.request, .save, "keys for the app's screens open them")
        canvas.keyPressed(key("shell:file.open"))
        XCTAssertEqual(model.request, .openFiles)

        model.run("select.all")
        model.run("edit.fill")
        canvas.keyPressed(key("shell:edit.freeTransform"))
        XCTAssertNotNil(model.transform, "⌘T")
        canvas.keyPressed(key("app:cancel"))
        XCTAssertNil(model.transform, "Esc")
        canvas.keyPressed(key("shell:edit.puppetWarp"))
        XCTAssertNotNil(model.puppet)
        canvas.keyPressed(key("app:commit"))
        XCTAssertNil(model.puppet, "Return")
        idle(model)
    }

    func testXSwapsTheColours() {
        let model = makeModel(width: 100, height: 100)
        model.setForeground(UIColor(red: 1, green: 0, blue: 0, alpha: 1))
        model.swapColors()
        XCTAssertEqual(model.foreground.hex, "#ffffff")
        XCTAssertEqual(model.backgroundColor.hex, "#ff0000")
    }

    func testNumberKeysSetTheBrushOpacityAndFlow() {
        // LayersTests: with the Brush, the numbers set the brush's opacity instead.
        let model = makeModel(width: 100, height: 100)
        model.run("layer.new.layer")
        let canvas = CanvasUIView(model: model)
        model.tool = .brush
        canvas.opacityKey(3, shift: false, time: 0)
        XCTAssertEqual(model.opacity, 0.3, accuracy: 0.001)
        canvas.opacityKey(5, shift: true, time: 5)
        XCTAssertEqual((model.query("brush.get") as? [String: Any]).flatMap { $0["flow"] as? Double } ?? -1, 0.5, accuracy: 0.001, "⇧: flow")
        XCTAssertEqual(model.info("Layer 1")?["opacity"] as? Double, 1, "the layer is left alone")
        model.tool = .dodge
        canvas.opacityKey(2, shift: false, time: 10)
        XCTAssertEqual(model.opacity, 0.3, accuracy: 0.001, "exposure tools are left alone")
        model.tool = .move
        canvas.opacityKey(5, shift: true, time: 20)
        XCTAssertEqual(model.info("Layer 1")?["fill"] as? Double ?? -1, 0.5, accuracy: 0.001, "⇧: the layer's fill")
    }
}
