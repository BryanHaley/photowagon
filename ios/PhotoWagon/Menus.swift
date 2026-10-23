import SwiftUI

/// Photoshop's menu bar in one button: File, Edit, Image, Layer, Type, Select, Filter, View,
/// Window. The engine's commands fill each menu by their menu path; items with a screen of their
/// own (New, Save As, Place, …) open it, and "…" items ask for their settings first. Each submenu
/// is built when it opens, so what's enabled is current and nothing is built while you paint.
struct MainMenu: UIViewRepresentable {
    @ObservedObject var model: EditorModel

    func makeUIView(context: Context) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: "line.3.horizontal", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
        b.tintColor = .white
        b.showsMenuAsPrimaryAction = true
        b.accessibilityLabel = "Menu"
        b.accessibilityIdentifier = "menu"
        let share = UIAction(title: "Quick Share as PNG…", image: UIImage(systemName: "square.and.arrow.up")) { [model] _ in model.request = .share("png") }
        share.accessibilityIdentifier = "menu.share"
        b.menu = UIMenu(children: [UIMenu(options: .displayInline, children: [share])] + MenuTree.order.map { name in
            UIMenu(title: name, children: [UIDeferredMenuElement.uncached { done in done(items(name)) }])
        })
        return b
    }

    func updateUIView(_ b: UIButton, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        CGSize(width: 42, height: 38)
    }

    /// One top-level menu: the app's own items, then the engine's.
    @MainActor
    func items(_ menu: String) -> [UIMenuElement] {
        let tree = MenuTree(model.editor.commands())
        guard let node = tree.top.first(where: { $0.name == menu }) else { return [] }
        return extras(menu) + elements(node, in: menu)
    }

    @MainActor
    private func elements(_ node: MenuTree.Node, in parent: String = "") -> [UIMenuElement] {
        let submenus = node.children.map { UIMenu(title: $0.name, children: elements($0, in: node.name)) as UIMenuElement }
        let commands: [UIMenuElement] = node.commands.filter { !Self.atTop.contains($0.id) }.map { c in
            let a = UIAction(title: c.label, subtitle: c.reason) { _ in run(c) }
            if !c.enabled { a.attributes = .disabled }
            return a
        }
        // Photoshop's Filter menu lists its own filters (Camera Raw, Liquify…) above the groups.
        if node.name == "Filter" { return [UIMenu(options: .displayInline, children: commands)] + submenus }
        // Select › Load Selection: the saved selections by name, as Photoshop's dialog lists them.
        if node.name == "Select", parent == "Select" {
            return submenus + commands + [section([loadSelectionMenu])]
        }
        // Layer › New: a layer from a picture too.
        if parent == "Layer", node.name == "New" {
            let open = model.doc != nil
            return submenus + commands + [section([
                action("From Photos…", "photo.on.rectangle", enabled: open) { model.request = .layerFromPhotos },
                action("From Files…", "folder", enabled: open) { model.request = .layerFromFiles },
            ])]
        }
        return submenus + commands
    }

    @MainActor
    private func action(_ title: String, _ symbol: String, enabled: Bool = true, _ run: @escaping () -> Void) -> UIAction {
        let a = UIAction(title: title, image: UIImage(systemName: symbol)) { _ in run() }
        if !enabled { a.attributes = .disabled }
        return a
    }

    @MainActor
    private func section(_ children: [UIMenuElement]) -> UIMenu { UIMenu(options: .displayInline, children: children) }

    /// Engine commands the app lists at the top of their menu instead.
    static let atTop: Set<String> = ["edit.puppetWarp"]

    /// The app's own items at the top of a menu.
    @MainActor
    private func extras(_ menu: String) -> [UIMenuElement] {
        let open = model.doc != nil
        switch menu {
        case "File":
            // New, Open and the recent files are on Home.
            return [
                section([
                    action("Close", "xmark.square", enabled: open) { model.request = .close },
                    action("Save", "square.and.arrow.down", enabled: open) { model.request = .save },
                    action("Save As…", "square.and.arrow.down.on.square", enabled: open) { model.request = .saveAs },
                    action("Save a Copy…", "doc.on.doc", enabled: open) { model.request = .saveCopy },
                ]),
                section([
                    action("Place Embedded…", "photo.badge.plus", enabled: open) { model.request = .placeFiles },
                    action("Place from Photos…", "photo.badge.plus", enabled: open) { model.request = .placePhotos },
                    UIMenu(title: "Share", image: UIImage(systemName: "square.and.arrow.up"), children: [
                        action("JPEG", "photo", enabled: open) { model.request = .share("jpg") },
                        action("PNG", "photo", enabled: open) { model.request = .share("png") },
                    ]),
                    UIMenu(title: "Export", image: UIImage(systemName: "square.and.arrow.up.on.square"), children: [
                        action("Quick Export as PNG", "photo", enabled: open) { model.quickExport(prefs: ["quickExportFormat": "png"]) },
                        action("Export As…", "square.and.arrow.up", enabled: open) { model.request = .exportAs },
                        action("Save for Web…", "globe", enabled: open) { model.request = .saveForWeb },
                    ]),
                    action("Save to Photos", "photo", enabled: open) { model.request = .saveToPhotos },
                    action("Print…", "printer", enabled: open) { model.request = .print },
                ]),
            ]
        case "Edit":
            return [section([
                action("Free Transform", "arrow.up.left.and.arrow.down.right", enabled: open) { model.beginTransform() },
                action("Pin Warp", "figure.wave", enabled: open) { model.beginPuppet() },
                action("Define Brush Preset…", "paintbrush.pointed", enabled: open && model.doc?.hasSelection == true) { model.request = .defineBrush },
                action("Import Brush Tips…", "paintbrush.pointed") { model.request = .importBrushTips },
            ])]
        case "View":
            let colours = CanvasColor.allCases.map { c in
                let a = UIAction(title: c.title) { _ in
                    if c == .custom { model.request = .canvasColor } else { model.canvasColor = c }
                }
                a.state = model.canvasColor == c ? .on : .off
                return a
            }
            return [section([
                action("Zoom In", "plus.magnifyingglass") { model.zoom(by: 1.5) },
                action("Zoom Out", "minus.magnifyingglass") { model.zoom(by: 1 / 1.5) },
                action("Fit Layer(s) on Screen", "arrow.up.left.and.arrow.down.right", enabled: open) { model.fitLayers() },
                { let a = action("Snap", "square.and.line.vertical.and.square") { model.snap.toggle() }; a.state = model.snap ? .on : .off; return a }(),
            ] + model.viewActions.map { a in action(a.title, a.symbol, a.run) }
              + [UIMenu(title: "Canvas Colour", image: UIImage(systemName: "paintpalette"), children: colours)])]
        case "Window":
            return [section([
                action("Layers", "square.3.layers.3d") { model.request = .panel(.layers) },
                action("History", "clock.arrow.circlepath") { model.request = .panel(.history) },
                action("Properties", "slider.horizontal.below.square.filled.and.square") { model.request = .panel(.properties) },
                action("Adjustments", "slider.horizontal.3") { model.request = .panel(.adjustments) },
                action("Actions", "play.rectangle.on.rectangle") { model.request = .panel(.actions) },
                action("Brush Settings", "paintbrush") { model.showBrushSettings = true },
                { let a = action("Timeline", "film") { model.showTimeline.toggle() }; a.state = model.showTimeline ? .on : .off; return a }(),
            ])]
        case "Help":
            return [section([
                action("Manual", "book") { model.showManual = true },
                action("Tutorial", "graduationcap", enabled: open) { model.showTutorial(.toolGroups) },
                action("Acknowledgements", "doc.text") { model.showAcknowledgements = true },
            ])]
        default:
            return []
        }
    }

    @MainActor
    func run(_ c: CommandInfo) { model.perform(c) }

    @MainActor
    private var loadSelectionMenu: UIMenuElement {
        let names = model.savedSelections
        let items = names.map { n in UIAction(title: n) { _ in model.loadSelection(n) } }
            + [UIAction(title: "Layer Transparency") { _ in model.loadSelection("transparency") }]
            + (model.activeLayer?.hasMask == true ? [UIAction(title: "Layer Mask") { _ in model.loadSelection("mask") }] : [])
        return UIMenu(title: "Load Selection", image: UIImage(systemName: "square.and.arrow.down.on.square"), children: items)
    }
}

/// The engine's menu commands as Photoshop's menus.
struct MenuTree {
    final class Node {
        let name: String
        var children: [Node] = []
        var commands: [CommandInfo] = []
        init(_ name: String) { self.name = name }

        func child(_ name: String) -> Node {
            if let n = children.first(where: { $0.name == name }) { return n }
            let n = Node(name)
            children.append(n)
            return n
        }
    }

    static let order = ["File", "Edit", "Image", "Layer", "Type", "Select", "Filter", "View", "Window", "Help"]
    let top: [Node]

    init(_ commands: [CommandInfo]) {
        let root = Node("")
        for name in Self.order { _ = root.child(name) }
        for c in commands where Self.shows(c) {
            let path = c.menu.components(separatedBy: " > ")
            guard let first = path.first, Self.order.contains(first) else { continue }
            path.reduce(root) { $0.child($1) }.commands.append(c)
        }
        top = root.children
    }

    /// Hidden: the app's own File items, and commands that need a desktop file or folder path.
    static func shows(_ c: CommandInfo) -> Bool {
        // Screens of the app's own that it lists among its items; Camera Raw, New Layer, Layer
        // Style and Preferences › General keep their place in the engine's menus.
        if let r = EditorModel.request(for: c.id), r != .cameraRaw, r != .newLayer, r != .generalPreferences {
            if case .layerStyle = r { return true }
            return false
        }
        // Load Selection is a submenu of the saved selections (MenuBar).
        return !["file.new", "file.close", "file.closeAll", "file.closeOthers", "select.loadSelection"].contains(c.id) && !needsPath(c)
    }

    private static func needsPath(_ c: CommandInfo) -> Bool {
        ["\"path\":str", "\"path\":text", "\"dir\":folder", "\"input\":folder", "\"paths\":[str]"].contains { c.params.contains($0) }
            && !c.params.contains("\"data\"")
    }
}

enum CanvasColor: String, CaseIterable, Identifiable {
    case standard, black, darkGray, mediumGray, lightGray, white, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: "Default"
        case .black: "Black"
        case .darkGray: "Dark Gray"
        case .mediumGray: "Medium Gray"
        case .lightGray: "Light Gray"
        case .white: "White"
        case .custom: "Custom…"
        }
    }
    var rgb: [Float] {
        switch self {
        case .standard: [0.09, 0.09, 0.1]
        case .black: [0, 0, 0]
        case .darkGray: [0.16, 0.16, 0.16]
        case .mediumGray: [0.4, 0.4, 0.4]
        case .lightGray: [0.75, 0.75, 0.75]
        case .white: [1, 1, 1]
        case .custom: Self.customRGB
        }
    }
}

extension CanvasColor {
    static var customRGB: [Float] {
        get { (UserDefaults.standard.array(forKey: "canvasCustom") as? [Float]).flatMap { $0.count == 3 ? $0 : nil } ?? [0.3, 0.3, 0.32] }
        set { UserDefaults.standard.set(newValue, forKey: "canvasCustom") }
    }
}

extension CommandInfo: Identifiable {}
