import CoreImage
import CoreText
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum SelectionMode: String, CaseIterable, Identifiable {
    case replace, add, subtract
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .replace: "square"
        case .add: "plus.square"
        case .subtract: "minus.square"
        }
    }
}

/// A path knot in document pixels: the anchor and its two handles.
struct Knot: Equatable {
    var anchor: Point
    var inHandle: Point
    var outHandle: Point
    init(_ p: Point) { (anchor, inHandle, outHandle) = (p, p, p) }
    init(anchor: Point, in i: Point, out o: Point) { (self.anchor, inHandle, outHandle) = (anchor, i, o) }
    var json: [String: Any] {
        ["anchor": [anchor.x, anchor.y], "in": [inHandle.x, inHandle.y], "out": [outHandle.x, outHandle.y]]
    }
}

struct Subpath: Equatable {
    var knots: [Knot]
    var closed: Bool
}

/// Puppet Warp's pins and options, as `edit.puppetWarp` takes them.
struct Puppet: Equatable {
    struct Pin: Equatable {
        var src: Point
        var dst: Point
        /// Degrees; `nil` turns with the mesh.
        var rotate: Double?
    }

    let layer: UInt64
    var pins: [Pin] = []
    var selected: Int?
    var mode = "normal"
    var density = "fewer"
    var expansion: Double = 2
    var showMesh = true

    /// Showing or selecting doesn't change the warp.
    func sameWarp(_ o: Puppet?) -> Bool {
        guard let o else { return false }
        return pins == o.pins && mode == o.mode && density == o.density && expansion == o.expansion
    }

    var warpParams: [String: Any] {
        var out: [String: Any] = ["layer": layer, "mode": mode, "density": density, "expansion": expansion]
        out["pins"] = pins.map { p -> [String: Any] in
            var d: [String: Any] = ["src": [Double(p.src.x), Double(p.src.y)], "dst": [Double(p.dst.x), Double(p.dst.y)]]
            if let r = p.rotate { d["rotate"] = r }
            return d
        }
        return out
    }
}

/// Where an eyedropper picks: the preview above the settings (a phone: hold, then let go on the
/// spot), or the canvas (an iPad, Window › Properties).
enum PickSurface { case preview, canvas }

/// A point to pick on the canvas for a settings screen (an eyedropper).
struct CanvasPick: Identifiable, Equatable {
    let id = UUID()
    let prompt: String
    /// 0…1 across the image.
    let pick: (CGPoint) -> Void

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

/// The Free Transform box: the source frame and how it is moved, scaled and turned about its
/// reference point.
struct TransformBox: Equatable {
    /// Source frame corners, document pixels.
    var x0, y0, x1, y1: Float
    var dx: Float = 0, dy: Float = 0, sx: Float = 1, sy: Float = 1, angle: Float = 0
    /// The reference point in the source frame; the centre unless moved.
    var pivot: Point?

    var center: Point { Point(x: (x0 + x1) / 2, y: (y0 + y1) / 2) }
    var origin: Point { pivot ?? center }
    var corners: [Point] { [Point(x: x0, y: y0), Point(x: x1, y: y0), Point(x: x1, y: y1), Point(x: x0, y: y1)] }

    /// Where source point `q` goes.
    func map(_ q: Point) -> Point {
        let c = origin
        let (lx, ly) = ((q.x - c.x) * sx, (q.y - c.y) * sy)
        let (cs, sn) = (cos(angle), sin(angle))
        return Point(x: c.x + dx + lx * cs - ly * sn, y: c.y + dy + lx * sn + ly * cs)
    }

    var quad: [Point] { corners.map(map) }

    /// Move the reference point to source point `p`, keeping the box where it is.
    mutating func setPivot(_ p: Point) {
        let target = map(p)
        pivot = p
        (dx, dy) = (target.x - p.x, target.y - p.y)
    }

    /// Source point of the reference point grid cell `(col, row)` (0…2 each).
    func gridPoint(_ col: Int, _ row: Int) -> Point {
        Point(x: x0 + (x1 - x0) * Float(col) / 2, y: y0 + (y1 - y0) * Float(row) / 2)
    }
}

extension EditorModel {
    /// Free Transform: turn the box by `degrees` (positive clockwise, as on screen).
    func rotateTransform(by degrees: Float) {
        guard var t = transform else { return }
        t.angle += degrees * .pi / 180
        // Whole quarter turns stay exact.
        let quarter = Float.pi / 2
        if abs(t.angle / quarter - (t.angle / quarter).rounded()) < 1e-4 { t.angle = (t.angle / quarter).rounded() * quarter }
        transform = t
    }
}

/// A text prompt the app shows (Type and Note tools).
struct TextPrompt: Identifiable {
    let id = UUID()
    let title: String
    var text: String
    let done: (String) -> Void
}

struct LayerRow: Identifiable, Equatable {
    let id: UInt64
    let name: String
    let kind: String
    let visible: Bool
    let opacity: Double
    let blend: String
    let selected: Bool
    var locked = false
    var hasMask = false
    var isBackground = false
    var fill: Double = 1
    /// How deep in groups (0 = top level).
    var depth = 0
    var expanded = true
    var clipped = false
    var active = false
    /// The adjustment's kind (`hueSaturation`, …) and its settings.
    var adjustment: (kind: String, params: [String: Any])?
    var smartFilters: [SmartFilterRow] = []
    /// Layer styles (the "fx" rows) and the list's own eye.
    var effects: [EffectRow] = []
    var effectsVisible = true
    /// Content bounds [x, y, width, height].
    var bounds: [Double]?
    var mask: MaskInfo?

    var isGroup: Bool { kind == "Group" }

    static func == (a: LayerRow, b: LayerRow) -> Bool {
        a.id == b.id && a.name == b.name && a.kind == b.kind && a.visible == b.visible && a.opacity == b.opacity && a.blend == b.blend
            && a.selected == b.selected && a.locked == b.locked && a.hasMask == b.hasMask && a.isBackground == b.isBackground && a.fill == b.fill
            && a.depth == b.depth && a.expanded == b.expanded && a.clipped == b.clipped && a.active == b.active && a.smartFilters == b.smartFilters
            && a.effects == b.effects && a.effectsVisible == b.effectsVisible && a.bounds == b.bounds && a.mask == b.mask && a.adjustment?.kind == b.adjustment?.kind
            && NSDictionary(dictionary: a.adjustment?.params ?? [:]).isEqual(to: b.adjustment?.params ?? [:])
    }
}

/// A layer mask's properties: density 0–100 %, feather in pixels.
struct MaskInfo: Equatable {
    var enabled = true
    var linked = true
    var density: Double = 100
    var feather: Double = 0

    init?(_ v: Any?) {
        guard let m = v as? [String: Any] else { return nil }
        enabled = m["enabled"] as? Bool ?? true
        linked = m["linked"] as? Bool ?? true
        density = (m["density"] as? NSNumber)?.doubleValue ?? 100
        feather = (m["feather"] as? NSNumber)?.doubleValue ?? 0
    }
}

/// One layer style under a layer's row.
struct EffectRow: Identifiable, Equatable {
    let index: Int
    let name: String
    let visible: Bool
    var id: Int { index }
}

/// A drag on the canvas while a sheet beside it is open (a drop shadow, a gradient): the document
/// points where it began and where it is now.
struct SheetDrag {
    let moved: (_ began: Bool, _ from: Point, _ to: Point) -> Void
}

/// A smart filter under a smart object's row.
struct SmartFilterRow: Identifiable, Equatable {
    let index: Int
    let command: String
    let name: String
    let visible: Bool
    var params: [String: Any] = [:]
    var blend = "Normal"
    var opacity = 1.0
    var id: Int { index }

    static func == (a: SmartFilterRow, b: SmartFilterRow) -> Bool {
        a.index == b.index && a.command == b.command && a.visible == b.visible && a.blend == b.blend && a.opacity == b.opacity
            && NSDictionary(dictionary: a.params).isEqual(to: b.params)
    }
}

/// Prints through the system print dialog for the engine's File › Print.
final class AppHost: Host, @unchecked Sendable {
    func print(pdf: Data, title: String) -> String {
        DispatchQueue.main.async {
            let controller = UIPrintInteractionController.shared
            let info = UIPrintInfo(dictionary: nil)
            info.jobName = title
            info.outputType = .photo
            controller.printInfo = info
            controller.printingItem = pdf
            controller.present(animated: true)
        }
        return "the system print dialog"
    }
}

@MainActor
final class EditorModel: ObservableObject {
    let editor = Editor(host: AppHost())

    @Published private(set) var doc: DocInfo?
    @Published var tool: Tool = .brush {
        didSet {
            overlayDirty = true
            guard tool != oldValue else { return }
            previousTool = oldValue
            hint = tool.title
            // A half-made crop, polygon or measurement belongs to its tool.
            if oldValue == .crop { cropRect = nil }
            if oldValue == .perspectiveCrop || oldValue == .polygonLasso { quad = [] }
            if oldValue == .ruler { ruler = nil }
            marqueeBox = nil
            if tool.pathTool || tool.shapeTool { loadWorkPath() }
            if let g = pickingGroup, !Tool.groups[g].contains(tool) { pickingGroup = nil }
            if tool == .objectSelect { showObjects(at: nil) } else { clearObjectHighlight() }
        }
    }
    /// The tool before this one (a Pencil double-tap's Previous Tool), and before the Eraser.
    var previousTool: Tool?
    var toolBeforeEraser: Tool?
    /// The squeeze palette, at this canvas point.
    @Published var pencilPalette: CGPoint?
    /// Window › Brush Settings.
    @Published var showBrushSettings = false
    /// The painting cursor is a crosshair only (Caps Lock).
    @Published var preciseCursor = false
    /// The tool group whose tools the context bar lists (its button was just tapped); `nil`
    /// shows the current tool's options.
    @Published var pickingGroup: Int?
    /// Help › Manual is open.
    @Published var showManual = false
    @Published var showAcknowledgements = false
    /// The first-time tour's tip on screen.
    @Published var tutorialStep: TutorialStep?
    // The engine's brush: keys like `[` and `]` change it there.
    @Published private(set) var brushSize: Double = 40
    @Published private(set) var opacity: Double = 1
    @Published private(set) var hardness: Double = 0.7
    @Published private(set) var flow: Double = 1
    @Published private(set) var smoothing: Double = 0
    /// The brush's blend mode, as the engine names it (`Normal`, `LinearDodge`…).
    @Published private(set) var brushMode = "Normal"
    @Published private(set) var pressureSize = false
    @Published private(set) var pressureOpacity = false
    /// Painting erases: the brush held as an eraser (` on a keyboard).
    @Published private(set) var brushErases = false
    /// Painting symmetry (`vertical`, `horizontal`, `dual`, `diagonal`, `path`), "" when off,
    /// and its axes in document pixels.
    @Published private(set) var symmetry = ""
    @Published private(set) var symmetryLines: [Double] = []
    @Published var selectionMode: SelectionMode = .replace
    @Published private(set) var foreground = UIColor.black
    @Published private(set) var backgroundColor = UIColor.white
    @Published private(set) var layers: [LayerRow] = []
    /// Painting goes to the active layer's mask.
    @Published private(set) var maskTarget = false
    /// The layer whose mask the canvas shows alone (View Mask), if any.
    @Published private(set) var maskView: UInt64?
    /// History panel: past steps (the last is the current state), then the steps Redo brings back.
    @Published private(set) var history: (past: [String], redo: [String]) = ([], [])
    @Published var toast: String?
    /// A short-lived name in the same bubble: the tool just picked, a button held down.
    @Published var hint: String?
    @Published private(set) var busy = false
    @Published var showSizePreview = false
    private var sizePreviewHide: Task<Void, Never>?
    /// Something the app shell shows, asked for from the keyboard.
    @Published var request: Request?

    // Tool options
    @Published var tolerance: Double = 32
    @Published var contiguous = true
    @Published var sampleAllLayers = false
    /// Marquee and Lasso options: Feather (pixels) and Anti-alias for the next selection.
    @Published var selectionFeather: Double = 0
    @Published var antiAlias = true
    /// Quick Selection's Enhance Edge.
    @Published var enhanceEdge = false
    /// Remove: off collects strokes until Commit.
    @Published var removeEachStroke = true
    /// AI Remove: blend the fill in so it takes the colour round it.
    @Published var aiMatchColor = true
    /// What AI Remove waits to remove while its download is offered.
    @Published var aiRemoveWaiting: AIRemoveRequest?
    var inpainterOverride: (any Inpainter)?
    /// Remove strokes waiting for Commit, document pixels.
    @Published var removeStrokes: [[Point]] = [] {
        didSet { overlayDirty = true }
    }
    /// A tap draws a straight line from where the last stroke ended (⇧-tap on a keyboard).
    @Published var straightLine = false
    var lastStrokeEnd: Point?

    /// The Marquee and Lasso tools' Feather and Anti-alias, as their commands take them.
    var edgeParams: [String: Any] { ["feather": min(max(selectionFeather, 0), 1000), "antiAlias": antiAlias] }
    @Published var gradientStyle = GradientStyle.linear
    @Published var gradientPreset = "Foreground to Background"
    @Published var gradientReverse = false
    /// Move tool: pick the layer under the finger.
    @Published var autoSelect = false
    /// Move tool: dragging moves a copy (⌥-drag in Photoshop).
    @Published var moveCopies = false
    /// View › Snap: moved layers snap to the canvas edges and centre, with guides.
    @Published var snap = UserDefaults.standard.object(forKey: "snap") as? Bool ?? true {
        didSet { UserDefaults.standard.set(snap, forKey: "snap") }
    }
    /// Smart guides while a layer moves: lines in document pixels.
    var smartGuides: [(Point, Point)] = [] { didSet { overlayDirty = true } }
    /// Zoom tool: drag right to zoom in, left to zoom out.
    @Published var scrubbyZoom = true
    /// Free Transform: corners keep the proportions (⇧ flips this, as in Photoshop).
    @Published var keepProportions = true
    /// Free Transform turns in 15° steps (⇧ swaps it for a drag).
    @Published var snapRotation = false
    /// Free Transform: corners scale about the reference point (⌥ in Photoshop).
    @Published var scaleFromPivot = false
    // Type tool
    @Published var typeFont = ""
    @Published var typeSize = 0.0
    @Published var typeAlign = "left"
    @Published var typeLeading = 0.0
    @Published var typeTracking = 0.0

    /// The size a new text layer gets when Size is left automatic: about a twelfth of the
    /// document's height, in points.
    var defaultTypeSize: Double {
        max(6, (Double(doc?.height ?? 1000) / 12 * 72 / resolution).rounded())
    }

    /// Show a text layer's style in the Type options (as Photoshop's options bar does).
    func loadTypeOptions(layer: UInt64) {
        guard let out = try? editor.execute(id: "type.info", params: json(["layer": layer])),
              let i = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] else { return }
        if let c = ((i["runs"] as? [[String: Any]])?.first?["style"]) as? [String: Any] {
            typeFont = c["font_family"] as? String ?? typeFont
            typeSize = c["size_pt"] as? Double ?? typeSize
            typeTracking = c["tracking"] as? Double ?? 0
            typeLeading = c["leading_pt"] as? Double ?? 0
        }
        if let p = ((i["paragraphs"] as? [[String: Any]])?.first?["style"]) as? [String: Any], let a = p["align"] as? String {
            typeAlign = a.hasSuffix("Center") || a == "Center" ? "center" : a.hasSuffix("Right") || a == "Right" ? "right" : "left"
        }
    }
    @Published var polygonSides = 6

    // Work in progress that a Commit or Cancel ends.
    @Published var cropRect: (Point, Point)? {
        didSet { overlayDirty = true }
    }
    /// Hue/Saturation: dragging on the canvas adjusts the colours under the finger.
    @Published var targetedAdjust: TargetedAdjust?
    /// A sheet beside the canvas takes drags on it (Layer Style's shadow, a gradient fill).
    @Published var sheetDrag: SheetDrag?
    /// A painting tool met a layer that has to be rasterized first: ask.
    @Published var rasterizePrompt: LayerRow?

    /// The rasterize alert's title and message.
    var rasterizePromptText: (title: String, message: String)? {
        guard let l = rasterizePrompt else { return nil }
        let kind = l.kind == "Embedded" ? "embedded layer" : l.kind.lowercased()
        let what = l.kind == "Type" ? "text" : l.kind == "Embedded" ? "an embedded layer" : l.kind.lowercased()
        return ("This \(kind) must be rasterized before proceeding.", "Its contents will no longer be editable as \(what).")
    }

    func rasterizePromptAnswered(rasterize: Bool) {
        if rasterize, let l = rasterizePrompt { run("layer.rasterize.layer", ["layer": l.id]) }
        rasterizePrompt = nil
    }
    /// Crop: the frame's turn (Straighten), degrees clockwise.
    @Published var cropAngle: Double = 0 {
        didSet { overlayDirty = true }
    }
    /// Crop › Straighten: the next drag draws the line to level.
    @Published var straightening = false
    /// Crop › Delete Cropped Pixels: off keeps what's outside the frame, to move it back later.
    @Published var deleteCroppedPixels = true
    /// Perspective Crop corners or Polygonal Lasso points, document pixels.
    @Published var quad: [Point] = [] {
        didSet { overlayDirty = true }
    }
    /// The marquee's adjustable box, while its selection is the last step.
    @Published var marqueeBox: MarqueeBox? {
        didSet { overlayDirty = true }
    }

    /// Select the marquee `r` (`[x, y, w, h]`) and show its box.
    func selectMarquee(_ r: [Int], ellipse: Bool, mode: String) {
        guard r.count == 4 else { return }
        let before = doc?.revision
        run("select.rect", ["x": r[0], "y": r[1], "width": r[2], "height": r[3], "ellipse": ellipse, "mode": mode].merging(edgeParams) { a, _ in a })
        guard let d = doc, d.revision != before, d.canUndo else { return }
        marqueeBox = MarqueeBox(x: r[0], y: r[1], w: r[2], h: r[3], ellipse: ellipse, mode: mode, doc: d.id, revision: d.revision)
    }

    /// Select the box as it is now, in place of its last selection (one step, not another).
    func applyMarqueeBox() {
        guard let b = marqueeBox else { return }
        guard let d = doc, d.id == b.doc, d.revision == b.revision, b.w >= 1, b.h >= 1 else {
            marqueeBox = nil
            return
        }
        run("edit.undo")
        selectMarquee(b.rect, ellipse: b.ellipse, mode: b.mode)
    }

    /// Set one of the box's X, Y, W, H (the options bar) and select it.
    /// The marquee box keeps its width-to-height ratio when resized.
    @Published var marqueeLockRatio = false

    func setMarquee(_ field: WritableKeyPath<MarqueeBox, Int>, _ value: Int) {
        guard var b = marqueeBox, b[keyPath: field] != value else { return }
        let ratio = Double(b.w) / Double(max(b.h, 1))
        b[keyPath: field] = field == \MarqueeBox.w || field == \MarqueeBox.h ? max(value, 1) : value
        if marqueeLockRatio, field == \MarqueeBox.w { b.h = max(Int((Double(b.w) / ratio).rounded()), 1) }
        if marqueeLockRatio, field == \MarqueeBox.h { b.w = max(Int((Double(b.h) * ratio).rounded()), 1) }
        marqueeBox = b
        applyMarqueeBox()
    }

    /// Polygonal Lasso and Perspective Crop: take back the last point.
    func undoLastPoint() {
        if !quad.isEmpty { quad.removeLast() }
    }
    @Published var transform: TransformBox? {
        didSet {
            overlayDirty = true
            if transform != oldValue { previewTransform() }
        }
    }
    /// Edit › Puppet Warp while it is open: pins and options.
    @Published var puppet: Puppet? {
        didSet {
            overlayDirty = true
            if let p = puppet, !p.sameWarp(oldValue) { previewPuppet() }
        }
    }
    /// Filter › Fluid Warp while it's open on the canvas.
    @Published var fluidWarp: FluidWarp? {
        didSet {
            overlayDirty = true
            if let w = fluidWarp, w.strokes.count != oldValue?.strokes.count || w.amount != oldValue?.amount { previewFluidWarp() }
        }
    }
    var fluidRunning = false
    var fluidNext: String?
    /// The puppet mesh's edges as the preview bends them, `[x0, y0, x1, y1, …]` document pixels.
    private(set) var puppetMesh: [Float] = []
    private var puppetRunning = false
    private var puppetNext: String?
    /// The work path as the pen tools show it.
    @Published var workPath: [Subpath] = [] {
        didSet { overlayDirty = true }
    }
    /// Ruler: from, to.
    @Published var ruler: (Point, Point)? {
        didSet { overlayDirty = true }
    }
    var samplers: [Point] = []
    var countMarks: [Point] = []
    @Published var prompt: TextPrompt?
    private(set) var resolution: Double = 72
    lazy var firstShapePreset: String? = {
        guard let out = try? editor.execute(id: "shape.presets.list", params: "{}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let groups = obj["groups"] as? [[String: Any]],
              let shapes = groups.first?["shapes"] as? [[String: Any]]
        else { return nil }
        return shapes.first?["name"] as? String
    }()

    /// Something waits for Commit (Return) or Cancel (Esc).
    var hasPending: Bool { cropRect != nil || !quad.isEmpty || transform != nil || puppet != nil || !removeStrokes.isEmpty || fluidWarp != nil }

    /// Something the app shell shows or does, asked for from a menu, key or button.
    enum Request: Equatable {
        case openFiles, openPhotos, placeFiles, placePhotos, layerFromFiles, layerFromPhotos, search, newDocument
        case save, saveAs, saveCopy, close, share(String), saveToPhotos, print, canvasColor, importBrushTips
        case panel(Panel)
        /// Close the open panel (to show a document that just opened).
        case closePanels
        case cameraRaw, newLayer, exportAs, saveForWeb, generalPreferences, defineBrush
        /// Layer Style, at Blending Options or an effect kind.
        case layerStyle(String)
    }

    enum Panel: String, Identifiable {
        case layers, history, properties, adjustments, actions
        var id: String { rawValue }
    }

    /// The app's own screen for engine command `id`, where it has one (New asks for a size, Save
    /// for a file, …).
    nonisolated static func request(for id: String) -> Request? {
        switch id {
        case "file.new": .newDocument
        case "file.export.saveForWebLegacy": .saveForWeb
        case "edit.preferences.general": .generalPreferences
        case "file.open": .openFiles
        case "file.close": .close
        case "file.save": .save
        case "file.saveAs": .saveAs
        case "file.saveACopy": .saveCopy
        case "file.placeEmbedded", "file.placeLinked": .placeFiles
        case "file.print", "file.printOneCopy": .print
        case "edit.search": .search
        case "window.toggle.layers": .panel(.layers)
        case "window.toggle.history": .panel(.history)
        case "window.toggle.actions": .panel(.actions)
        case "filter.cameraRaw": .cameraRaw
        case "layer.new.layer": .newLayer
        case _ where id.hasPrefix("layer.layerStyle.") && (LayerStyle.kinds.contains { $0.kind == id.dropFirst(17) } || id.hasSuffix(".blendingOptions")):
            .layerStyle(String(id.dropFirst(17)))
        default: nil
        }
    }

    // MARK: - Open documents

    @Published private(set) var documents: [DocInfo] = []
    /// The Home screen is in front.
    @Published var showHome = true
    @Published private(set) var recents: [RecentFile]
    /// Where Recent is kept.
    let defaults: UserDefaults
    /// Recovery copies (`Recovery.swift`): one folder per run.
    @Published var recovered: [RecoveredFile] = []
    /// A file just opened, waiting in Develop for Open, Done or Cancel.
    @Published var developOpen: DevelopOpen?
    /// A Develop live filter being changed.
    @Published var developEdit: DevelopEdit?
    var recoveryRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Recovery", isDirectory: true)
    let recoveryRun = UUID().uuidString
    var lastRecovery = Date()
    private var recoveryTimer: Timer?
    /// Zoom for the status bar, in percent.
    @Published private(set) var zoomPercent = 100
    /// Around the image on the canvas (View › Canvas Colour).
    @Published var canvasColor = CanvasColor(rawValue: UserDefaults.standard.string(forKey: "canvasColor") ?? "") ?? .standard {
        didSet {
            UserDefaults.standard.set(canvasColor.rawValue, forKey: "canvasColor")
            editor.setCanvasColor(rgb: canvasColor.rgb)
            needsDraw = true
        }
    }

    func setCustomCanvas(_ rgb: [Float]) {
        CanvasColor.customRGB = rgb
        if canvasColor == .custom {
            editor.setCanvasColor(rgb: rgb)
            needsDraw = true
        } else {
            canvasColor = .custom
        }
    }
    /// The engine command whose settings are being asked for (from a menu).
    @Published var commandSettings: CommandInfo?
    /// Window › Timeline is showing, and the document's frame animation (if it has one).
    @Published var showTimeline = false
    @Published var animation: AnimationInfo?
    /// Frames picked in the Timeline (frame delays apply to them).
    @Published var selectedFrames: Set<Int> = []
    @Published var playing = false
    var played = 0
    var playTimer: Timer?
    /// Picks on a settings screen's preview, 0…1 across the image (the eyedroppers).
    @Published var previewTap: ((CGPoint) -> Void)?
    /// A point to pick on the canvas for a settings screen; the settings step aside until then.
    @Published var canvasPick: CanvasPick?
    /// The Eyedropper's Sample Size ("point", "3", "5", …) and Sample (which layers).
    @Published var sampleSize = "point"
    @Published var sampleLayers = "all"
    /// Outline what clips to black or white on the preview (Levels and Curves' Show Clipping).
    @Published var previewClipping = false

    /// Start an eyedropper: `pick` gets the point, 0…1 across the image.
    func beginPick(_ surface: PickSurface, prompt: String, _ pick: @escaping (CGPoint) -> Void) {
        switch surface {
        case .preview: previewTap = pick
        case .canvas: canvasPick = CanvasPick(prompt: prompt, pick: pick)
        }
    }

    func endPick() {
        previewTap = nil
        canvasPick = nil
    }

    /// The canvas picked document point `p`; outside the image it waits for another.
    func canvasPicked(_ p: Point) {
        guard let c = canvasPick, let d = doc, p.x >= 0, p.y >= 0, p.x < Float(d.width), p.y < Float(d.height) else { return }
        canvasPick = nil
        c.pick(CGPoint(x: CGFloat(p.x) / CGFloat(d.width), y: CGFloat(p.y) / CGFloat(d.height)))
    }
    /// The file each document lives in, and the revision last saved there.
    private var files: [UInt64: (url: URL?, saved: UInt64)] = [:]
    /// Each document's view while another one is in front.
    private var views: [UInt64: ViewState] = [:]
    /// Close the document once Save As finishes.
    var closeAfterSave = false

    func isDirty(_ d: DocInfo) -> Bool { files[d.id]?.saved != d.revision }

    func activate(_ index: Int) {
        do { _ = try editor.activate(index: UInt32(index)) } catch { show(error) }
        showHome = false
        sync()
    }

    /// Close the front document, asking first when it has unsaved changes (`confirmClose`).
    @Published var confirmClose: DocInfo?

    func requestClose(_ index: Int) {
        activate(index)
        guard let d = doc else { return }
        if isDirty(d) { confirmClose = d } else { closeActive() }
    }

    func closeActive() {
        guard let d = doc, let i = documents.firstIndex(where: { $0.id == d.id }) else { return }
        editor.close(index: UInt32(i))
        clearRecovery(d.id)
        files[d.id] = nil
        views[d.id] = nil
        cancelPending()
        sync()
        if doc == nil { showHome = true }
    }

    func newDocument(_ params: [String: Any]) {
        do { _ = try editor.execute(id: "file.new", params: json(params)) } catch { show(error) }
        opened(url: nil)
    }

    /// A document just opened or was created: remember its file and go to the workspace.
    private func opened(url: URL?) {
        sync()
        guard let d = doc else { return }
        files[d.id] = (url, d.revision)
        if let url { remember(url) }
        showHome = false
    }

    /// File › Place: the image as a new layer, then Free Transform to size it. `embedded` false
    /// (Layer › New › From Photos or From Files) makes a plain pixel layer.
    func place(data: Data, name: String, embedded: Bool? = nil) {
        // The layer is named after the file: keep its name, in a folder of its own.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url)
        } catch { show(error); return }
        var params: [String: Any] = ["path": url.path]
        if let embedded { params["smartObject"] = embedded }
        let p = json(params)
        whileBusy({ editor in _ = try editor.execute(id: "file.placeEmbedded", params: p) }, then: { [weak self] in
            try? FileManager.default.removeItem(at: dir)
            self?.beginTransform()
        })
    }

    /// Several files placed at once, each a layer named after it, committed as they land (no
    /// transform box), bottom first.
    func placeAll(_ urls: [URL], embedded: Bool? = nil) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var paths: [String] = []
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for u in urls {
                let access = u.startAccessingSecurityScopedResource()
                defer { if access { u.stopAccessingSecurityScopedResource() } }
                let copy = dir.appendingPathComponent(u.lastPathComponent)
                try Data(contentsOf: u).write(to: copy)
                paths.append(copy.path)
            }
        } catch { show(error); return }
        let ps = paths.map { p -> String in
            var params: [String: Any] = ["path": p]
            if let embedded { params["smartObject"] = embedded }
            return json(params)
        }
        let box = ResultBox()
        whileBusy({ editor in
            for p in ps { _ = try editor.execute(id: "file.placeEmbedded", params: p) }
            box.out = "done"
        }, then: { [weak self] in
            try? FileManager.default.removeItem(at: dir)
            // A failure has shown its own message.
            if box.out != nil { self?.toast = "Placed \(ps.count) files" }
        })
    }

    // MARK: - Saving

    private static let layeredFormats: Set<String> = ["psd", "psb", "pcraft", "tif", "tiff"]

    /// File › Save: back into the document's own file when it can hold the document. False when
    /// it can't (a new document, or layers in a flat file): the caller opens Save As.
    @discardableResult
    func save() -> Bool {
        guard let d = doc else { return true }
        // An Edit Contents document saves back into its smart object.
        if editor.commandEnabled(id: "layer.smartObjects.saveContents") {
            runInBackground("layer.smartObjects.saveContents") { [weak self] out in
                if out != nil { self?.toast = "Saved the embedded layer's contents" }
            }
            return true
        }
        guard let url = files[d.id]?.url else { return false }
        let ext = url.pathExtension.lowercased()
        guard Self.layeredFormats.contains(ext) || layers.count == 1, let data = export(ext) else { return false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            try data.write(to: url)
            files[d.id] = (url, d.revision)
            clearRecovery(d.id)
            remember(url)
            toast = "Saved \(url.lastPathComponent)"
            objectWillChange.send()
            if closeAfterSave { closeAfterSave = false; closeActive() }
        } catch {
            return false
        }
        return true
    }

    /// Save As finished: the document now lives in `url` (and takes its name).
    func savedAs(_ url: URL) {
        guard doc != nil else { return }
        editor.renameDocument(name: url.lastPathComponent)
        sync()
        guard let d = doc else { return }
        files[d.id] = (url, d.revision)
        clearRecovery(d.id)
        toast = "Saved \(url.lastPathComponent)"
        remember(url)
        objectWillChange.send()
        if closeAfterSave { closeAfterSave = false; closeActive() }
    }

    // MARK: - Recent files

    private func remember(_ url: URL) {
        guard let mark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        recents.removeAll { $0.name == url.lastPathComponent }
        recents.insert(RecentFile(name: url.lastPathComponent, bookmark: mark, date: Date()), at: 0)
        recents = Array(recents.prefix(20))
        RecentFile.save(recents, defaults)
    }

    func openRecent(_ r: RecentFile) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: r.bookmark, bookmarkDataIsStale: &stale) else {
            toast = "\(r.name) can't be found"
            return
        }
        open(url: url)
    }

    /// Open a file from Files (or Recent), remembering where it lives for Save.
    func open(url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { toast = "Can't read \(url.lastPathComponent)"; return }
        open(data: data, name: url.lastPathComponent, url: url)
    }

    /// Gradient presets by group.
    lazy var gradientPresets: [(String, [String])] = {
        guard let out = try? editor.execute(id: "gradient.presets.list", params: "{}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let groups = obj["groups"] as? [[String: Any]] else { return [] }
        return groups.map { g in (g["name"] as? String ?? "", (g["presets"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }) }
    }()

    /// A file dropped on the app: opened as a document, or placed as a layer when dropped on
    /// the canvas of an open document.
    @discardableResult
    func drop(_ providers: [NSItemProvider], place: Bool) -> Bool {
        guard let p = providers.first, let type = p.registeredTypeIdentifiers.first else { return false }
        p.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
            guard let data else { return }
            let name = p.suggestedName.map { $0 + "." + (UTType(type)?.preferredFilenameExtension ?? "png") } ?? "Dropped.png"
            Task { @MainActor in
                if place, self.doc != nil { self.place(data: data, name: name) } else { self.open(data: data, name: name) }
            }
        }
        return true
    }

    /// The action being recorded (Window › Actions), shown in the status bar too.
    @Published var recordingAction: String?

    /// Brush tip presets by group, in library order.
    @Published private(set) var brushGroups: [(name: String, presets: [String])] = []

    func reloadBrushPresets() {
        guard let out = try? editor.execute(id: "brush.presets.list", params: "{}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let list = obj["presets"] as? [[String: Any]] else { return }
        var groups: [(name: String, presets: [String])] = []
        for p in list {
            guard let name = p["name"] as? String else { continue }
            let g = (p["group"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Other"
            if let i = groups.firstIndex(where: { $0.name == g }) { groups[i].presets.append(name) } else { groups.append((g, [name])) }
        }
        brushGroups = groups
    }

    /// Add the tips in a brush file (Photoshop .abr, GIMP .gbr/.gih/.vbr, Krita .bundle, or an image).
    /// Load Actions: a Photoshop .atn file's actions, as a set.
    func loadActions(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let out = run("actions.load", ["data": data.base64EncodedString(), "set": url.deletingPathExtension().lastPathComponent]) as? [String: Any] else { return }
            let names = out["actions"] as? [String] ?? []
            toast = "Loaded \(names.count) action\(names.count == 1 ? "" : "s")"
        } catch {
            show(error)
        }
    }

    func importBrushTips(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let out = run("brush.presets.importFile", ["data": data.base64EncodedString(), "fileName": url.lastPathComponent, "select": true]) as? [String: Any]
            guard let out else { return }
            reloadBrushPresets()
            let count = out["count"] as? Int ?? 1
            toast = "Added \(count) brush tip\(count == 1 ? "" : "s")"
        } catch {
            show(error)
        }
    }


    /// Note the view: the status bar shows its zoom.
    func noteView() {
        let z = Int((view.zoom * 100).rounded())
        if z != zoomPercent { zoomPercent = z }
    }

    /// The canvas view (screen pixels), changed by gestures; not published.
    var view = ViewState(width: 1, height: 1, zoom: 1, centerX: 0, centerY: 0, rotation: 0, pixelsPerPoint: 1)
    var needsDraw = true
    /// Something the canvas overlays depend on changed.
    var overlayDirty = true
    private var fitPending = true
    private var layersRevision: UInt64?
    private var previewRunning = false
    private var previewNext: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recents = RecentFile.load(defaults)
        editor.setCanvasColor(rgb: canvasColor.rgb)
        _ = try? editor.execute(id: "tools.setBrush", params: json(["size": 40, "hardness": 0.7]))
        sync()
        if let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Presets", isDirectory: true) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            _ = editor.openPresets(dir: dir.path)
        }
        reloadBrushPresets()
        loadRecovered()
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recoveryTick() }
        }
        Task.detached(priority: .utility) { _ = addFonts(paths: EditorModel.installedFontFiles()) }
    }

    /// Files of the fonts installed on this device.
    nonisolated static func installedFontFiles() -> [String] {
        let all = CTFontCollectionCreateFromAvailableFonts(nil)
        let descriptors = CTFontCollectionCreateMatchingFontDescriptors(all) as? [CTFontDescriptor] ?? []
        return Array(Set(descriptors.compactMap { (CTFontDescriptorCopyAttribute($0, kCTFontURLAttribute) as? URL)?.path }))
    }

    // MARK: - Running commands

    /// Run an engine command now; failures show as a toast.
    @discardableResult
    /// A read-only command's result, or `nil` (no message) when it doesn't apply.
    func query(_ id: String, _ params: [String: Any] = [:]) -> Any? {
        guard let out = try? editor.execute(id: id, params: json(params)) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(out.utf8), options: [.fragmentsAllowed])
    }

    func run(_ id: String, _ params: [String: Any] = [:]) -> Any? {
        do {
            let out = try editor.execute(id: id, params: json(params))
            sync()
            return try? JSONSerialization.jsonObject(with: Data(out.utf8), options: [.fragmentsAllowed])
        } catch {
            show(error)
            sync()
            return nil
        }
    }

    /// Run slow work off the main thread; the canvas waits.
    func whileBusy(_ work: @escaping @Sendable (Editor) throws -> Void, then: (() -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        let editor = editor
        Task.detached {
            let failure: Error? = {
                do { try work(editor); return nil } catch { return error }
            }()
            await MainActor.run {
                self.busy = false
                if let failure { self.show(failure) }
                self.sync()
                then?()
            }
        }
    }

    // MARK: - Develop presets

    /// Develop's own looks, then the ones saved with Save Preset.
    static let developLooks: [(name: String, values: [String: Double])] = [
        ("Bright", ["exposure": 0.4, "highlights": -30, "shadows": 30, "vibrance": 15]),
        ("Warm Matte", ["temperature": 15, "contrast": -15, "blacks": 25, "saturation": -10]),
        ("Punchy", ["contrast": 25, "clarity": 20, "vibrance": 25, "dehaze": 10]),
        ("Black & White", ["saturation": -100, "contrast": 20]),
    ]

    var developPresets: [(name: String, values: [String: Double])] {
        let saved = defaults.array(forKey: "developPresets") as? [[String: Any]] ?? []
        return saved.compactMap { d in
            guard let name = d["name"] as? String, let v = d["values"] as? [String: Double] else { return nil }
            return (name, v)
        }
    }

    /// Save `values` as `name`, replacing a saved preset of that name.
    func saveDevelopPreset(_ name: String, _ values: [String: Double]) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var saved = (defaults.array(forKey: "developPresets") as? [[String: Any]] ?? []).filter { $0["name"] as? String != name }
        saved.append(["name": name, "values": values.filter { $0.value != 0 }])
        defaults.set(saved, forKey: "developPresets")
        objectWillChange.send()
    }

    // MARK: - Live settings

    /// A settings screen applying its command as you change it (on release, not mid-drag): the
    /// last try is undone before the next. Runs off the main thread, latest settings first.
    @Published private(set) var liveBusy = false
    private var liveApplied = false
    /// The command and params of the try that's applied.
    private var liveLast = ""
    private var liveRunning = false
    private var liveKeepWhenDone = false
    private var liveOpen = false
    private var livePending: (id: String, params: [String: Any]?, finish: Bool)?
    private var liveThen: [() -> Void] = []

    /// The settings screen's Preview switch: off shows the image without the latest try.
    @Published private(set) var livePreview = true
    private var liveWanted: (id: String, params: [String: Any])?

    /// A settings screen opened.
    func liveBegin() {
        liveOpen = true
        livePreview = true
        liveWanted = nil
    }

    /// Try `id` with `params`.
    func live(_ id: String, _ params: [String: Any]) {
        // A field losing focus as its screen closes isn't a new try.
        guard liveOpen else { return }
        liveWanted = (id, params)
        if livePreview { queueLive(id, params, finish: false) }
    }

    func setLivePreview(_ on: Bool) {
        livePreview = on
        guard liveOpen else { return }
        if !on {
            queueLive("", nil, finish: false)
        } else if let w = liveWanted {
            queueLive(w.id, w.params, finish: false)
        }
    }

    /// OK: keep `params` applied.
    func liveFinish(_ id: String, _ params: [String: Any]) {
        liveOpen = false
        queueLive(id, params, finish: true)
    }

    /// Cancel: take the last try back.
    func liveCancel() {
        liveOpen = false
        queueLive("", nil, finish: true)
    }

    /// The screen closed some other way (Done): keep what's applied.
    func liveKeep() {
        liveOpen = false
        if livePending != nil {
            livePending?.finish = true
        } else if liveRunning {
            liveKeepWhenDone = true
        } else {
            liveApplied = false
        }
    }

    /// Run `f` once the tries waiting have run.
    func afterLive(_ f: @escaping () -> Void) {
        if liveRunning || livePending != nil { liveThen.append(f) } else { f() }
    }

    private func queueLive(_ id: String, _ params: [String: Any]?, finish: Bool) {
        livePending = (id, params, finish)
        if !liveRunning { nextLive() }
    }

    private func nextLive() {
        guard let job = livePending else {
            liveRunning = false
            liveBusy = false
            let then = liveThen
            liveThen = []
            then.forEach { $0() }
            return
        }
        livePending = nil
        liveRunning = true
        liveBusy = true
        let p = job.params.map(json)
        let key = job.id + (p ?? "")
        // The settings that are showing already: nothing to run (OK keeps them).
        if liveApplied, key == liveLast {
            if job.finish { liveApplied = false }
            nextLive()
            return
        }
        let undo = liveApplied
        let editor = editor
        Task.detached {
            var failure: Error?
            var applied = false
            do {
                if undo { _ = try editor.execute(id: "edit.undo", params: "{}") }
                if let p { _ = try editor.execute(id: job.id, params: p); applied = true }
            } catch { failure = error }
            await MainActor.run {
                self.liveApplied = applied && !job.finish && !self.liveKeepWhenDone
                self.liveKeepWhenDone = false
                self.liveLast = applied ? key : ""
                if let failure { self.show(failure) }
                self.sync()
                self.nextLive()
            }
        }
    }

    /// Run a slow command off the main thread; `then` gets its JSON result.
    func runInBackground(_ id: String, _ params: [String: Any] = [:], then: (([String: Any]?) -> Void)? = nil) {
        let p = json(params)
        let box = ResultBox()
        whileBusy({ editor in box.out = try editor.execute(id: id, params: p) }, then: {
            let obj = box.out.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            then?(obj)
        })
    }

    // MARK: - Objects (Vision first, the engine's own selection as the fallback)

    /// Vision; tests swap in one that finds nothing.
    var objects = ObjectFinder()

    private func parse(_ out: String?) -> [String: Any]? {
        out.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    /// Object Selection tap: the whole object under the point.
    func selectObject(at p: Point, mode: String) {
        if previewingObject {
            queuedObject = (p, mode)
            return
        }
        clearObjectHighlight()
        guard let d = doc else { return }
        let (finder, all) = (objects, sampleAllLayers)
        let layer = all ? nil : activeLayer?.id
        let (fx, fy) = (Double(p.x) / Double(d.width), Double(p.y) / Double(d.height))
        let point = [Double(p.x), Double(p.y)]
        let box = ResultBox()
        whileBusy({ editor in
            if let f = finder.objects(editor, layer: layer), let i = finder.instance(f, x: fx, y: fy), let m = finder.mask(f, instances: IndexSet(integer: i)) {
                box.out = try editor.execute(id: "select.fromMask", params: json(m.params.merging(["mode": mode, "refine": true, "sampleAllLayers": all, "label": "Object Selection"]) { a, _ in a }))
            } else {
                box.out = try editor.execute(id: "select.object", params: json(["point": point, "mode": mode, "sampleAllLayers": all]))
            }
        }, then: { [weak self] in
            if self?.parse(box.out)?["selected"] as? Bool == false { self?.toast = "No object found there. Drag a box around it." }
        })
    }

    // MARK: Object Finder

    /// Object Selection highlights the object under a hovering Pencil or a held finger.
    @Published var objectFinder = true { didSet { showObjects(at: nil) } }
    @Published var showAllObjects = false { didSet { showObjects(at: nil) } }
    /// The highlight: an image stretched over `rect` (document x0, y0, x1, y1).
    private(set) var objectHighlight: (image: CGImage, rect: [Float])? { didSet { overlayDirty = true } }
    /// The last highlight shown (UI tests read it).
    private(set) var lastObjectHighlight: [Float]?
    /// What the highlight shows: Vision's object, -1 for all of them.
    private var highlighted: Int?
    private var previewingObject = false
    private var queuedObject: (Point, String)?
    /// Vision's objects for the hover or hold under way (`.some(nil)`: it found none). Dropped
    /// when that ends, so each hover or hold runs Vision once.
    private var hoverObjects: ObjectFinder.Found??
    private var hoverPoint: Point?
    private var hoverRun = 0
    private var hoverLooking = false
    private var allRun = 0

    private func setObjectHighlight(_ image: CGImage?, _ rect: [Float]) {
        objectHighlight = image.map { ($0, rect) }
        if image != nil { lastObjectHighlight = rect }
    }

    func clearObjectHighlight() {
        endHover()
        highlighted = nil
        if objectHighlight != nil { objectHighlight = nil }
    }

    private func endHover() {
        (hoverObjects, hoverPoint, hoverLooking) = (nil, nil, false)
        hoverRun += 1
    }

    /// Run Vision in the background for this hover, then highlight under the latest point.
    private func lookForHover() {
        guard doc != nil, !hoverLooking else { return }
        hoverLooking = true
        hoverRun += 1
        let (finder, editor, layer, run) = (objects, editor, sampleAllLayers ? nil : activeLayer?.id, hoverRun)
        Task.detached {
            let found = finder.objects(editor, layer: layer)
            await MainActor.run {
                guard self.hoverRun == run, let p = self.hoverPoint else { return }
                self.hoverLooking = false
                self.hoverObjects = .some(found)
                self.showObjects(at: p)
            }
        }
    }

    /// Highlight Vision's object under `p` (a hovering Pencil, a finger moving while held);
    /// `nil` ends the hover. With Show All Objects, every object when nothing is under `p`.
    func showObjects(at p: Point?) {
        guard tool == .objectSelect, objectFinder, let d = doc else { return clearObjectHighlight() }
        guard let p else {
            endHover()
            highlighted = nil
            if showAllObjects { highlightAll() } else if objectHighlight != nil { objectHighlight = nil }
            return
        }
        hoverPoint = p
        guard let found = hoverObjects else { return lookForHover() }
        guard let f = found else { return }
        let under = objects.instance(f, x: Double(p.x) / Double(d.width), y: Double(p.y) / Double(d.height))
        guard let want = under ?? (showAllObjects ? -1 : nil) else {
            highlighted = nil
            if objectHighlight != nil { objectHighlight = nil }
            return
        }
        guard highlighted != want else { return }
        highlighted = want
        setObjectHighlight(objects.highlight(f, instances: want < 0 ? nil : IndexSet(integer: want)), [0, 0, Float(d.width), Float(d.height)])
    }

    /// Show All Objects: run Vision and draw every object; nothing is kept but the drawing.
    private func highlightAll() {
        guard let d = doc else { return }
        allRun += 1
        let (finder, editor, layer, run, rect) = (objects, editor, sampleAllLayers ? nil : activeLayer?.id, allRun, [0, 0, Float(d.width), Float(d.height)])
        Task.detached {
            let image = finder.objects(editor, layer: layer).flatMap { finder.highlight($0) }
            await MainActor.run {
                guard self.allRun == run, self.showAllObjects, self.hoverPoint == nil, self.tool == .objectSelect else { return }
                self.highlighted = -1
                self.setObjectHighlight(image, rect)
            }
        }
    }

    /// A finger held on the image: highlight the object there, waiting for Vision or, where it
    /// finds nothing, the engine's Object Finder. Lifting selects it (`selectObject`).
    func holdObject(at p: Point) {
        guard doc != nil, !busy else { return }
        if case .some(.some) = hoverObjects { return showObjects(at: p) }
        let (finder, all) = (objects, sampleAllLayers)
        let layer = all ? nil : activeLayer?.id
        let params = json(["point": [Double(p.x), Double(p.y)], "sampleAllLayers": all])
        let box = ResultBox()
        let found = FoundBox()
        previewingObject = true
        whileBusy({ editor in
            found.value = finder.objects(editor, layer: layer)
            if found.value == nil {
                box.out = try editor.execute(id: "select.objectPreview", params: params)
            }
        }, then: { [weak self] in
            guard let self else { return }
            self.previewingObject = false
            if let f = found.value {
                self.hoverObjects = .some(f)
                self.showObjects(at: p)
            } else if let o = self.parse(box.out), o["found"] as? Bool == true, let w = o["width"] as? Int, let h = o["height"] as? Int,
                      let rect = o["rect"] as? [Double], rect.count == 4, let b64 = o["data"] as? String, let data = Data(base64Encoded: b64), data.count == w * h {
                self.highlighted = nil
                self.setObjectHighlight(ObjectFinder.tint(width: w, height: h) { x, y in data[y * w + x] }, rect.map(Float.init))
            }
            if let (q, mode) = self.queuedObject {
                self.queuedObject = nil
                self.selectObject(at: q, mode: mode)
            }
        })
    }

    /// Select › Subject: every object Vision finds in the image.
    func selectSubject(mode: String) {
        // As in Photoshop, the active layer's picture unless Sample All Layers is on.
        let (finder, all) = (objects, sampleAllLayers)
        let layer = all ? nil : activeLayer?.id
        let box = ResultBox()
        whileBusy({ editor in
            if let f = finder.objects(editor, layer: layer), let m = finder.mask(f) {
                box.out = try editor.execute(id: "select.fromMask", params: json(m.params.merging(["mode": mode, "refine": true, "sampleAllLayers": all, "label": "Select Subject"]) { a, _ in a }))
            } else {
                box.out = try editor.execute(id: "select.subject", params: json(["mode": mode, "sampleAllLayers": all]))
            }
        }, then: { [weak self] in
            if self?.parse(box.out)?["selected"] as? Bool == false { self?.toast = "No subject found" }
        })
    }

    /// Refine Hair: near the selection's edge, take Vision's person matte (hair and fur).
    func refineHair() {
        guard let d = doc else { return }
        let (finder, layer) = (objects, sampleAllLayers ? nil : activeLayer?.id)
        let band = max(8, Double(max(d.width, d.height)) / 50)
        let box = ResultBox()
        whileBusy({ editor in
            guard let m = finder.personMatte(editor, layer: layer) else { return }
            box.out = try editor.execute(id: "select.fromMask", params: json(m.params.merging(["band": band, "label": "Refine Hair"]) { a, _ in a }))
        }, then: { [weak self] in
            if box.out == nil { self?.toast = "No person found to refine" }
        })
    }

    /// Properties › Remove Background: mask out everything but the layer's objects.
    func removeBackground() {
        guard let layer = activeLayer?.id else { return }
        let finder = objects
        whileBusy({ editor in
            var params: [String: Any] = ["layer": layer]
            if let f = finder.objects(editor, layer: layer), let m = finder.mask(f) { params["mask"] = m.params }
            _ = try editor.execute(id: "layer.removeBackground", params: json(params))
        })
    }

    /// A selection command that may find nothing: say so instead of silently doing nothing.
    func selectInBackground(_ id: String, _ params: [String: Any], nothing: String) {
        runInBackground(id, params) { [weak self] out in
            if let out, out["selected"] as? Bool == false { self?.toast = nothing }
        }
    }

    func show(_ error: Error) {
        if case let FfiError.Failed(message) = error {
            toast = message
        } else {
            toast = error.localizedDescription
        }
    }

    /// Pick up whatever changed in the engine.
    func sync() {
        let d = editor.document()
        if d?.id != doc?.id {
            // Another document in front: keep this one's view, bring back that one's.
            if let old = doc { views[old.id] = view }
            if let d, let v = views[d.id] {
                (view.zoom, view.centerX, view.centerY, view.rotation) = (v.zoom, v.centerX, v.centerY, v.rotation)
            } else {
                fitPending = true
            }
            samplers = []
            countMarks = []
            layersRevision = nil
        } else if d?.width != doc?.width || d?.height != doc?.height {
            fitPending = true
        }
        doc = d
        documents = editor.documents()
        if fitPending { fit() }
        if let d, d.revision != layersRevision {
            layersRevision = d.revision
            loadLayers()
            animation = AnimationInfo(query("animation.info"))
            if animation == nil, playing { stopPlaying() }
            if objectHighlight != nil || showAllObjects { showObjects(at: nil) }
        } else if d == nil, !layers.isEmpty {
            animation = nil
            layers = []
            history = ([], [])
            layersRevision = nil
        }
        if let b = marqueeBox, d?.id != b.doc || d?.revision != b.revision { marqueeBox = nil }
        let t = editor.toolSettings()
        (brushSize, hardness, opacity) = (Double(t.size), Double(t.hardness), Double(t.opacity))
        (flow, smoothing, brushMode) = (Double(t.flow), Double(t.smoothing), t.mode)
        (pressureSize, pressureOpacity, brushErases) = (t.pressureSize, t.pressureOpacity, t.erase)
        if symmetry != t.symmetry || symmetryLines != t.symmetryLines {
            (symmetry, symmetryLines) = (t.symmetry, t.symmetryLines)
            overlayDirty = true
        }
        foreground = UIColor(rgba: t.foreground)
        backgroundColor = UIColor(rgba: t.background)
        needsDraw = true
        overlayDirty = true
    }

    /// Change one brush setting; a slider drag is one change (`coalesce`).
    /// The Size slider's circle: on while it's dragged, off when it's let go or `after` seconds
    /// after the last change (iOS 27's Slider doesn't always report the let-go).
    func sizePreview(editing: Bool, after: Double = 1) {
        sizePreviewHide?.cancel()
        showSizePreview = editing
        guard editing else { return }
        sizePreviewHide = Task { [weak self] in
            try? await Task.sleep(for: .seconds(after))
            guard !Task.isCancelled else { return }
            self?.showSizePreview = false
        }
    }

    func setBrush(_ field: String, _ value: Double) {
        _ = try? editor.execute(id: "tools.setBrush", params: json([field: value, "coalesce": "slider-\(field)"]))
        sync()
    }

    /// Change a brush setting at a dotted path (`shapeDynamics.size.control`).
    func setBrush(path: String, _ value: Any) {
        var p = BrushPaths.patch(path, value)
        p["coalesce"] = "slider-\(path)"
        run("tools.setBrush", p)
    }

    /// Re-read the layers (after a change that doesn't make a history step, like the mask target).
    func reloadLayers() { loadLayers() }

    /// Settings that start from the document: a width and height marked `=current` (Image Size,
    /// Canvas Size) start at its size, a layer name at the active layer's.
    func startingValues(_ fields: [ParamField]) -> [String: Any] {
        guard let d = doc else { return [:] }
        var out: [String: Any] = [:]
        for f in fields {
            switch f.kind {
            case let .number(_, _, value, _) where value == 0 && f.name == "width": out["width"] = Int(d.width)
            case let .number(_, _, value, _) where value == 0 && f.name == "height": out["height"] = Int(d.height)
            case let .text(value) where value.isEmpty && f.name == "name": if let l = activeLayer { out["name"] = l.name }
            default: break
            }
        }
        return out
    }

    /// The Layers panel's New Group: an empty group, or the selected layers grouped when several
    /// are selected (the active layer alone always counts as selected).
    func newGroup() {
        run(selectedLayers.count > 1 ? "layer.groupLayers" : "layer.new.group")
    }

    /// Select a layer from the Layers panel, painting on its pixels or its mask.
    func targetLayer(_ id: UInt64, mask: Bool = false) {
        run("layer.select", ["layer": id])
        run(mask ? "channel.target.layerMask" : "channel.target.composite")
        reloadLayers()
    }

    /// A menu item: Puppet Warp's pins, one of the app's own screens, the settings of an item
    /// that has them ("…"), or the command itself.
    func perform(_ c: CommandInfo) {
        if c.id == "edit.puppetWarp" {
            beginPuppet()
        } else if c.id == "filter.liquify" {
            beginFluidWarp()
        } else if let r = Self.request(for: c.id) {
            request = r
        } else if c.enabled, c.label.hasSuffix("…"), !editor.commandFields(id: c.id).isEmpty {
            commandSettings = c
        } else {
            runInBackground(c.id)
        }
    }

    /// A command's key does what its menu item does (⌘M opens Curves, as in Photoshop).
    func performKey(_ id: String) {
        if let r = Self.request(for: id) {
            request = r
        } else if let c = editor.commands().first(where: { $0.id == id }), c.label.hasSuffix("…") {
            perform(c)
        } else {
            run(id)
        }
    }

    /// The document's saved selections (its alpha channels), by name.
    var savedSelections: [String] {
        let channels = (query("document.inspect") as? [String: Any])?["channels"] as? [String: Any]
        return (channels?["alpha"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    /// Select › Load Selection: a saved selection by name, or "transparency" / "mask" of the active layer.
    func loadSelection(_ channel: String) {
        var p: [String: Any] = ["channel": channel]
        if let id = activeLayer?.id, ["transparency", "mask"].contains(channel) { p["layer"] = id }
        run("select.loadSelection", p)
    }

    /// The layer's mask as the selection (Photoshop's ⌘-click on the mask).
    func loadMaskAsSelection(_ id: UInt64) {
        run("select.loadSelection", ["channel": "mask", "layer": id])
    }

    /// Clip a layer to the one below, or release it.
    func toggleClip(_ id: UInt64) {
        let clipped = layers.first { $0.id == id }?.clipped == true
        run(clipped ? "layer.releaseClippingMask" : "layer.createClippingMask", ["layer": id])
    }

    /// The blend mode `by` steps after `current` in the Blend menu's order (Pass Through for a
    /// group, first), wrapping round: Photoshop's ⇧+ and ⇧−.
    nonisolated static func stepBlend(_ current: String, by: Int, group: Bool) -> String {
        let all = (group ? ["Pass Through"] : []) + blendModes.flatMap { $0 }
        guard let i = all.firstIndex(of: current) else { return all.first ?? current }
        return all[((i + by) % all.count + all.count) % all.count]
    }

    /// The Layers panel's mask button: reveal (or, `hide`, hide) the selection, or everything
    /// without one. Painting then goes on the new mask, as in Photoshop.
    func addMask(hide: Bool = false) {
        let selection = doc?.hasSelection == true
        run("layer.layerMask." + (hide ? (selection ? "hideSelection" : "hideAll") : (selection ? "revealSelection" : "revealAll")))
        run("channel.target.layerMask")
        reloadLayers()
    }

    /// See the layer's mask alone on the canvas (Photoshop's ⌥-click on the mask), or stop.
    func toggleMaskView(_ id: UInt64) {
        if maskView == id {
            run("view.layerMask", ["layer": id, "mode": "off"])
        } else {
            targetLayer(id, mask: true)
            run("view.layerMask", ["layer": id, "mode": "gray"])
        }
        reloadLayers()
    }

    /// Mask Properties' Density (0–100) and Feather (pixels); a slider's drag is one history step.
    func setMask(_ id: UInt64, density: Double? = nil, feather: Double? = nil) {
        var p: [String: Any] = ["layer": id, "coalesce": "mask-\(id)-\(density == nil ? "feather" : "density")"]
        if let density { p["density"] = min(max(density, 0), 100) }
        if let feather { p["feather"] = min(max(feather, 0), 1000) }
        run("layer.layerMask.edit", p)
    }

    /// Copy a layer's mask onto another layer (Photoshop's ⌥-drag), or move it there.
    func copyMask(from: UInt64, to: UInt64, move: Bool) {
        run("layer.layerMask.copyTo", ["layer": from, "to": to, "move": move])
    }

    /// A row dragged in the Layers panel from row `from` to before row `to` (List's onMove).
    /// Dropped right under a closed or empty group, it goes into that group; under an open
    /// group's own row it becomes that group's top layer; anywhere else it takes that place.
    func moveLayer(from: Int, to: Int) {
        guard layers.indices.contains(from), from != to, from + 1 != to else { return }
        let layer = layers[from].id
        if to > 0, layers.indices.contains(to - 1) {
            let above = layers[to - 1]
            let hasShownChildren = layers.indices.contains(to) && layers[to].depth > above.depth
            if above.isGroup, !hasShownChildren {
                run("layer.moveTo", ["layer": layer, "target": above.id, "position": "into"])
                return
            }
        }
        if to < layers.count {
            run("layer.moveTo", ["layer": layer, "target": layers[to].id, "position": "above"])
        } else if let last = layers.last {
            run("layer.moveTo", ["layer": layer, "target": last.id, "position": "below"])
        }
    }

    /// The group a shown row is in: the nearest group row above it one level up.
    func parentGroup(of id: UInt64) -> LayerRow? {
        guard let i = layers.firstIndex(where: { $0.id == id }), layers[i].depth > 0 else { return nil }
        return layers[..<i].last { $0.isGroup && $0.depth == layers[i].depth - 1 }
    }

    /// The layer's menu: Move Into a group (its top layer), or Move Out of the group it's in.
    func moveLayer(_ id: UInt64, into group: UInt64) {
        run("layer.moveTo", ["layer": id, "target": group, "position": "into"])
    }

    func moveOutOfGroup(_ id: UInt64) {
        if let parent = parentGroup(of: id) { run("layer.moveTo", ["layer": id, "target": parent.id, "position": "above"]) }
    }

    /// Open or close a group. It changes no history, so the list is reloaded here.
    func toggleGroup(_ id: UInt64) {
        run("layer.setExpanded", ["layer": id])
        reloadLayers()
    }

    private func loadLayers() {
        guard let out = try? editor.execute(id: "document.inspect", params: "{}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let rows = obj["layers"] as? [[String: Any]]
        else { layers = []; return }
        resolution = (obj["resolution"] as? NSNumber)?.doubleValue ?? 72
        maskTarget = obj["maskTarget"] as? Bool ?? false
        maskView = ((obj["layerMaskView"] as? [String: Any])?["layer"] as? NSNumber)?.uint64Value
        history = (obj["history"] as? [String] ?? [], obj["historyRedo"] as? [String] ?? [])
        let background = (obj["backgroundLayer"] as? NSNumber)?.uint64Value
        let active = (obj["activeLayer"] as? NSNumber)?.uint64Value
        let labels = commandLabels
        var all: [LayerRow] = []
        var allCount = rows.count
        // Top first, groups' layers under them; a closed group's layers are left out of `layers`.
        func add(_ rows: [[String: Any]], depth: Int, shown: Bool) {
            for r in rows {
                guard let id = (r["id"] as? NSNumber)?.uint64Value else { continue }
                var row = LayerRow(id: id, name: r["name"] as? String ?? "", kind: r["kind"] as? String ?? "",
                                   visible: r["visible"] as? Bool ?? true, opacity: (r["opacity"] as? NSNumber)?.doubleValue ?? 1,
                                   blend: r["blend"] as? String ?? "Normal", selected: r["selected"] as? Bool ?? false,
                                   locked: r["locked"] as? Bool ?? false, hasMask: r["hasMask"] as? Bool ?? false, isBackground: id == background)
                row.fill = (r["fill"] as? NSNumber)?.doubleValue ?? 1
                row.depth = depth
                row.expanded = r["expanded"] as? Bool ?? true
                row.clipped = r["clipped"] as? Bool ?? false
                row.active = id == active
                row.bounds = (r["bounds"] as? [NSNumber])?.map(\.doubleValue)
                row.mask = MaskInfo(r["mask"])
                if let a = r["adjustment"] as? [String: Any], let kind = a["kind"] as? String { row.adjustment = (kind, a["params"] as? [String: Any] ?? [:]) }
                row.smartFilters = (r["smartFilters"] as? [[String: Any]] ?? []).enumerated().map { i, f in
                    let command = f["command"] as? String ?? ""
                    return SmartFilterRow(index: i, command: command, name: labels[command] ?? command, visible: f["visible"] as? Bool ?? true,
                                          params: f["params"] as? [String: Any] ?? [:], blend: f["blend"] as? String ?? "Normal",
                                          opacity: (f["opacity"] as? NSNumber)?.doubleValue ?? 1)
                }
                if let fx = r["effects"] as? [String: Any] {
                    row.effectsVisible = fx["enabled"] as? Bool ?? true
                    row.effects = (fx["items"] as? [[String: Any]] ?? []).enumerated().map { i, e in
                        EffectRow(index: i, name: e["kind"] as? String ?? "", visible: e["enabled"] as? Bool ?? true)
                    }
                }
                if shown { all.append(row) }
                if let children = r["children"] as? [[String: Any]] {
                    allCount += children.count
                    add(children, depth: depth + 1, shown: shown && row.expanded)
                }
            }
        }
        add(rows, depth: 0, shown: true)
        layers = all
        layerCount = allCount
    }

    /// Command names by id, without "…" (they don't change; `commands()` checks every command's
    /// state, so it isn't called per change).
    private(set) lazy var commandLabels: [String: String] = Dictionary(editor.commands().map { ($0.id, $0.label.replacingOccurrences(of: "…", with: "")) },
                                                                        uniquingKeysWith: { a, _ in a })
    /// Layers › ◑: the fill and adjustment layer commands, in menu order.
    private(set) lazy var adjustmentCommands: [(id: String, label: String)] = editor.commands()
        .filter { $0.id.hasPrefix("layer.newFillLayer.") || $0.id.hasPrefix("layer.newAdjustmentLayer.") }
        .map { ($0.id, $0.label.replacingOccurrences(of: "…", with: "")) }

    /// Every layer in the document, groups' layers included.
    @Published private(set) var layerCount = 0
    /// Layers panel: taps add layers to the selection, or take them out (⌘-click in Photoshop).
    @Published var selectingLayers = false
    /// Smart objects whose filter list is folded away in the Layers panel.
    @Published private(set) var collapsedFilters: Set<UInt64> = []

    func toggleFilters(_ layer: UInt64) {
        if collapsedFilters.remove(layer) == nil { collapsedFilters.insert(layer) }
    }

    var activeLayer: LayerRow? { layers.first(where: \.active) ?? layers.first(where: \.selected) }
    var selectedLayers: [LayerRow] { layers.filter(\.selected) }

    /// View › Fit Layer(s) on Screen (⌥-click a layer's thumbnail): zoom to the selected layers' content.
    func fitLayers() {
        let boxes = selectedLayers.compactMap(\.bounds).filter { $0.count == 4 && $0[2] > 0 && $0[3] > 0 }
        guard !boxes.isEmpty, view.width > 1 else { return }
        let x0 = boxes.map { $0[0] }.min() ?? 0, y0 = boxes.map { $0[1] }.min() ?? 0
        let x1 = boxes.map { $0[0] + $0[2] }.max() ?? 1, y1 = boxes.map { $0[1] + $0[3] }.max() ?? 1
        view.zoom = min(max(min(Float(view.width) / Float(x1 - x0), Float(view.height) / Float(y1 - y0)) * 0.9, 0.01), 64)
        view.rotation = 0
        place(Point(x: Float(x0 + x1) / 2, y: Float(y0 + y1) / 2), at: CGPoint(x: CGFloat(view.width) / 2, y: CGFloat(view.height) / 2))
    }

    // MARK: - Files

    /// `develop` false skips Develop for camera raw files (and JPEG and HEIC, when set).
    func open(data: Data, name: String, url: URL? = nil, develop: Bool = true) {
        let note = ResultBox()
        let before = doc?.id
        whileBusy({ editor in note.out = try Self.load(editor, data, name) }, then: { [weak self] in
            guard let self else { return }
            if let text = note.out { self.toast = text }
            guard self.doc?.id != before else { return }
            self.opened(url: url)
            if develop, Self.opensInDevelop(name, jpeg: self.developJPEG) { self.beginDevelopOpen(Self.developKey(name, data)) }
        })
    }

    /// Opens with our own decoders, then Apple's, then LibRaw; a camera raw's embedded preview
    /// only when none of them reads the raw data. Says which decoder it took when not ours.
    nonisolated static func load(_ editor: Editor, _ data: Data, _ name: String) throws -> String? {
        var failure: Error?
        var previewOnly = false
        do {
            _ = try editor.open(name: name, bytes: data, allowPreview: false)
            return nil
        } catch FfiError.PreviewOnly {
            previewOnly = true
        } catch {
            failure = error
        }
        if let tiff = AppleDecoder.tiff(data, name: name), (try? editor.openDecoded(name: name, tiff: tiff)) != nil {
            return "Opened with Apple's decoder"
        }
        if (try? editor.openLibraw(name: name, bytes: data)) != nil {
            return "Opened with LibRaw"
        }
        if previewOnly {
            _ = try editor.open(name: name, bytes: data, allowPreview: true)
            return "Only the camera's built-in preview could be opened"
        }
        throw failure ?? FfiError.Failed(message: "Can't open \(name)")
    }

    func export(_ format: String, quality: UInt8? = nil) -> Data? {
        do { return try editor.export(format: format, quality: quality) } catch { show(error); return nil }
    }

    /// The document as JPEG XL: lossless, or lossy at `quality` (0–100), at `effort` (1–10).
    func exportJXL(lossless: Bool, quality: Int, effort: Int) -> Data? {
        do {
            return try editor.exportJxl(lossless: lossless, quality: UInt8(clamping: quality), effort: UInt8(clamping: effort), width: nil, srgb: false, transparency: true)
        } catch {
            show(error)
            return nil
        }
    }

    var fileStem: String {
        let name = doc?.name ?? "Untitled"
        return (name as NSString).deletingPathExtension
    }

    // MARK: - Colours

    func setForeground(_ c: UIColor) {
        run("tools.setColors", ["foreground": c.hex])
    }

    func swapColors() {
        run("tools.swapColors")
    }

    static let sampleSizes: [(value: String, label: String)] = [("point", "Point Sample")] + [3, 5, 11, 31, 51, 101].map { ("\($0)", "\($0) by \($0) Average") }
    static let sampleLayerChoices: [(value: String, label: String)] = [
        ("all", "All Layers"), ("current", "Current Layer"), ("currentAndBelow", "Current & Below"),
        ("allNoAdjustments", "All Layers No Adjustments"), ("currentAndBelowNoAdjustments", "Current & Below No Adjustments"),
    ]

    /// The colour under document point `p`, as the Eyedropper's Sample Size and Sample take it;
    /// nil where nothing is there.
    func sampledColor(at p: Point) -> [Double]? {
        let size: Any = Int(sampleSize) ?? "point"
        guard let out = try? editor.execute(id: "document.sampleColor", params: json(["x": p.x, "y": p.y, "size": size, "sampleLayer": sampleLayers])),
              let c = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [Double], c.count >= 3
        else { return nil }
        if c.count > 3, c[3] <= 0 { return nil }
        return Array(c.prefix(3))
    }

    /// A Color Fill layer takes the colour at `point` (0–1 across the image), with the
    /// Eyedropper's Sample Size and Sample, as Photoshop's Color Picker does on a click in the image.
    func setFillColor(_ layer: UInt64, from point: CGPoint) {
        guard let d = doc, let c = sampledColor(at: Point(x: Float(point.x) * Float(d.width), y: Float(point.y) * Float(d.height))) else { return }
        run("layer.fill.solidColor.set", ["layer": layer, "color": c + [1]])
    }

    /// Sample the image under document point `p` into the foreground colour.
    func sample(at p: Point) {
        guard let c = sampledColor(at: p) else { return }
        setForeground(UIColor(red: c[0], green: c[1], blue: c[2], alpha: 1))
    }

    // MARK: - View

    /// Called by the canvas when its size changes.
    func canvasResized(width: UInt32, height: UInt32, scale: Float) {
        // Fitted to the old size (a panel opening beside it, a turn): fit the new one.
        let fitted = doc != nil && abs(view.zoom - fitZoom) < fitZoom * 0.01
        view.width = width
        view.height = height
        if fitted, width > 0, height > 0 { fitPending = true }
        view.pixelsPerPoint = scale
        if fitPending { fit() }
        needsDraw = true
        overlayDirty = true
    }

    /// The zoom that shows the whole document.
    var fitZoom: Float {
        guard let doc, doc.width > 0, doc.height > 0 else { return 1 }
        return min(Float(view.width) / Float(doc.width), Float(view.height) / Float(doc.height)) * 0.94
    }

    /// Keep document point `anchor` under screen pixel `p` (after a zoom or rotation).
    func place(_ anchor: Point, at p: CGPoint) {
        let (sx, sy) = (Float(p.x) - Float(view.width) / 2, Float(p.y) - Float(view.height) / 2)
        let (cs, sn) = (cos(-view.rotation), sin(-view.rotation))
        view.centerX = anchor.x - (sx * cs - sy * sn) / view.zoom
        view.centerY = anchor.y - (sx * sn + sy * cs) / view.zoom
        needsDraw = true
        overlayDirty = true
    }

    /// Zoom by `factor` around screen pixel `p` (the view centre when `nil`).
    func zoom(by factor: Float, at p: CGPoint? = nil) {
        let p = p ?? CGPoint(x: CGFloat(view.width) / 2, y: CGFloat(view.height) / 2)
        let anchor = screenToDoc(view: view, x: Float(p.x), y: Float(p.y))
        view.zoom = min(max(view.zoom * factor, 0.01), 64)
        place(anchor, at: p)
        needsDraw = true
        overlayDirty = true
    }

    /// Move the view by screen pixels.
    func pan(dx: Float, dy: Float) {
        let (cs, sn) = (cos(-view.rotation), sin(-view.rotation))
        view.centerX -= (dx * cs - dy * sn) / view.zoom
        view.centerY -= (dx * sn + dy * cs) / view.zoom
        needsDraw = true
        overlayDirty = true
    }

    /// Undo the view's rotation, keeping the centre where it is.
    func straighten() {
        let mid = CGPoint(x: CGFloat(view.width) / 2, y: CGFloat(view.height) / 2)
        let anchor = screenToDoc(view: view, x: Float(mid.x), y: Float(mid.y))
        view.rotation = 0
        place(anchor, at: mid)
    }

    /// Centre the document, keeping the zoom and tilt.
    func resetPosition() {
        guard let doc, view.width > 1 else { return }
        place(Point(x: Float(doc.width) / 2, y: Float(doc.height) / 2), at: CGPoint(x: CGFloat(view.width) / 2, y: CGFloat(view.height) / 2))
    }

    /// Back to the zoom that fits the document, about the middle of the screen, keeping the tilt.
    func resetZoom() {
        guard doc != nil, view.width > 1, view.zoom > 0 else { return }
        zoom(by: fitZoom / view.zoom, at: CGPoint(x: CGFloat(view.width) / 2, y: CGFloat(view.height) / 2))
    }

    func fit() {
        guard let doc, view.width > 1 else { return }
        view.zoom = fitZoom
        view.rotation = 0
        place(Point(x: Float(doc.width) / 2, y: Float(doc.height) / 2), at: CGPoint(x: CGFloat(view.width) / 2, y: CGFloat(view.height) / 2))
        fitPending = false
    }

    /// ⇧-drag: the point moved level or upright from `start`, whichever way it went further.
    nonisolated static func axisLocked(_ p: Point, from start: Point) -> Point {
        abs(p.x - start.x) >= abs(p.y - start.y) ? Point(x: p.x, y: start.y) : Point(x: start.x, y: p.y)
    }

    /// The current tool's stroke command and its params (without points).
    func strokeParams() -> (String, [String: Any])? {
        guard let cmd = tool.strokeCommand else { return nil }
        let size = brushSize
        // The retouching commands take hardness and opacity in percent.
        let pct: [String: Any] = ["size": size, "opacity": max(opacity * 100, 1), "hardness": hardness * 100]
        let p: [String: Any] = switch tool {
        case .brush: ["size": size, "opacity": opacity, "hardness": hardness, "erase": brushErases, "zoom": Double(view.zoom)]
        case .eraser: ["size": size, "opacity": opacity, "hardness": hardness, "erase": true, "zoom": Double(view.zoom)]
        case .pencil: ["size": size, "opacity": opacity, "erase": brushErases]
        case .colorReplacement, .mixerBrush: ["size": size]
        case .backgroundEraser: ["size": size, "hardness": hardness]
        case .spotHeal, .remove, .aiRemove: ["size": size, "hardness": hardness * 100, "sampleAllLayers": sampleAllLayers]
        case .quickSelect: ["size": size, "mode": selectionMode == .subtract ? "subtract" : "add", "sampleAllLayers": sampleAllLayers, "enhanceEdge": enhanceEdge]
        default: pct
        }
        return (cmd, p)
    }

    // MARK: - Pending work

    func commitPending() {
        if fluidWarp != nil {
            commitFluidWarp()
        } else if !removeStrokes.isEmpty {
            if tool == .aiRemove {
                aiRemove(.strokes(removeStrokes))
                removeStrokes = []
                return
            }
            let strokes = removeStrokes.map { $0.map { [Double($0.x), Double($0.y)] } }
            removeStrokes = []
            runInBackground("paint.remove", ["size": brushSize, "hardness": hardness * 100, "sampleAllLayers": sampleAllLayers, "strokes": strokes])
        } else if let (a, b) = cropRect {
            cropRect = nil
            let (x0, y0, x1, y1) = (min(a.x, b.x), min(a.y, b.y), max(a.x, b.x), max(a.y, b.y))
            guard x1 - x0 >= 1, y1 - y0 >= 1 else { return }
            run("image.crop", ["x": Int(x0.rounded()), "y": Int(y0.rounded()), "width": Int((x1 - x0).rounded()), "height": Int((y1 - y0).rounded()),
                               "angle": cropAngle, "deleteCroppedPixels": deleteCroppedPixels])
            cropAngle = 0
            fitPending = true
            fit()
        } else if !quad.isEmpty {
            let pts = quad
            quad = []
            if tool == .perspectiveCrop, pts.count == 4 {
                let pts = clockwiseFromTopLeft(pts)
                let d = { (a: Point, b: Point) in Double(hypot(a.x - b.x, a.y - b.y)) }
                let w = (d(pts[0], pts[1]) + d(pts[3], pts[2])) / 2, h = (d(pts[0], pts[3]) + d(pts[1], pts[2])) / 2
                run("image.perspectiveCrop", ["corners": pts.map { [Double($0.x), Double($0.y)] }, "width": Int(w.rounded()), "height": Int(h.rounded())])
                fitPending = true
                fit()
            } else if pts.count >= 3 {
                run("select.lasso", ["points": pts.map { [Double($0.x), Double($0.y)] }, "mode": selectionMode.rawValue].merging(edgeParams) { a, _ in a })
            }
        } else if let t = transform {
            transform = nil
            run("edit.transform", transformParams(t))
        } else if let p = puppet {
            puppet = nil
            puppetMesh = []
            // On a smart object the warp becomes a smart filter.
            let smart = layers.first { $0.id == p.layer }?.kind == "Embedded"
            runInBackground(smart ? "layer.smartObjects.puppetWarp" : "edit.puppetWarp", p.warpParams) { [weak self] _ in self?.editor.endPreview() }
        }
    }

    func cancelPending() {
        cancelFluidWarp()
        removeStrokes = []
        cropRect = nil
        cropAngle = 0
        straightening = false
        quad = []
        transform = nil
        if puppet != nil {
            puppet = nil
            puppetMesh = []
            editor.endPreview()
            needsDraw = true
        }
    }

    /// File › Export › Quick Export: a flat copy in the app's folder, with the Export As settings
    /// (`prefs` changes them first).
    func quickExport(name: String? = nil, prefs: [String: Any] = [:]) {
        if !prefs.isEmpty { run("file.export.exportPreferences", prefs) }
        let ext = (query("file.export.exportPreferences") as? [String: Any]).flatMap { ($0["values"] as? [String: Any])?["quickExportFormat"] as? String } ?? "png"
        let file = "\(name.flatMap { $0.isEmpty ? nil : $0 } ?? fileStem).\(ext)"
        let path = AppFolder.url.appendingPathComponent(file).path
        runInBackground("file.export.quickExport", ["path": path]) { [weak self] out in
            if out != nil { self?.toast = "Exported \(file)" }
        }
    }

    /// Export As's file for `scale`: `name.png` at 1x, `name@2x.png`, `name@0.5x.png`…
    nonisolated static func exportFileName(_ name: String, scale: Double, ext: String) -> String {
        guard scale != 1 else { return "\(name).\(ext)" }
        let s = scale == scale.rounded() ? String(Int(scale)) : String(format: "%g", scale)
        return "\(name)@\(s)x.\(ext)"
    }

    /// File › Export › Export As: one file per scale, `width` at 1x, in the app's folder.
    func exportAs(name: String, prefs: [String: Any], width: Int, scales: [Double], transparency: Bool) {
        let ext = prefs["quickExportFormat"] as? String ?? "png"
        // The engine's Export Preferences have no JPEG XL: they keep their own format.
        if ext != "jxl" { run("file.export.exportPreferences", prefs) }
        let stem = name.isEmpty ? fileStem : name
        let jobs = scales.sorted().map { scale in
            (Self.exportFileName(stem, scale: scale, ext: ext), max(Int((Double(width) * scale).rounded()), 1))
        }
        let folder = AppFolder.url
        // JPEG XL is encoded by libjxl in the bridge, not by the engine's exporter.
        let jxl = ext == "jxl" ? (lossless: prefs["jxlLossless"] as? Bool ?? true, quality: prefs["jxlQuality"] as? Int ?? 90, srgb: prefs["convertToSrgb"] as? Bool ?? true) : nil
        whileBusy({ editor in
            for (file, w) in jobs {
                let url = folder.appendingPathComponent(file)
                if let jxl {
                    let data = try editor.exportJxl(lossless: jxl.lossless, quality: UInt8(clamping: jxl.quality), effort: 7, width: UInt32(w), srgb: jxl.srgb, transparency: transparency)
                    try data.write(to: url)
                } else {
                    _ = try editor.execute(id: "file.export.quickExport", params: json(["path": url.path, "width": w, "transparency": transparency]))
                }
            }
        }, then: { [weak self] in
            self?.toast = jobs.count == 1 ? "Exported \(jobs[0].0)" : "Exported \(jobs.count) files"
        })
    }

    /// Quick Export as PNG for each of `ids` (a layer's menu): `<layer name>.png` in the app's folder.
    func exportLayers(_ ids: [UInt64]) {
        let names = Dictionary(layers.map { ($0.id, $0.name) }) { a, _ in a }
        let folder = AppFolder.url
        let jobs = ids.map { id in (id, (names[id] ?? "Layer").replacingOccurrences(of: "/", with: "-") + ".png") }
        whileBusy({ editor in
            for (id, file) in jobs {
                _ = try editor.execute(id: "layer.exportAs", params: json(["layer": id, "path": folder.appendingPathComponent(file).path]))
            }
        }, then: { [weak self] in
            self?.toast = jobs.count == 1 ? "Exported \(jobs[0].1)" : "Exported \(jobs.count) layers"
        })
    }

    /// Crop › Straighten: turn the frame so the line from `a` to `b` is level (or upright), and
    /// shrink it to the largest frame of the image's shape that stays inside the image.
    func straighten(from a: Point, to b: Point) {
        straightening = false
        guard let d = doc, hypot(b.x - a.x, b.y - a.y) > 2 else { return }
        var angle = Double(atan2(b.y - a.y, b.x - a.x)) * 180 / .pi
        // The nearer of level and upright.
        while angle > 45 { angle -= 90 }
        while angle < -45 { angle += 90 }
        let (w, h) = (Double(d.width), Double(d.height))
        let (c, s) = (cos(abs(angle) * .pi / 180), sin(abs(angle) * .pi / 180))
        let k = min(w / (w * c + h * s), h / (w * s + h * c))
        let (fw, fh) = (w * k, h * k)
        cropRect = (Point(x: Float((w - fw) / 2), y: Float((h - fh) / 2)), Point(x: Float((w + fw) / 2), y: Float((h + fh) / 2)))
        cropAngle = (angle * 10).rounded() / 10
        toast = String(format: "Straightened %.1f°", cropAngle)
    }

    /// Edit › Puppet Warp on the active layer: tap to pin, drag a pin to bend.
    func beginPuppet() {
        guard let l = activeLayer, ["Pixel", "Embedded", "Type", "Shape"].contains(l.kind), !l.isBackground else {
            toast = activeLayer?.isBackground == true ? "Pin Warp can't bend the Background: unlock it first" : "Pick a layer with pixels to warp"
            return
        }
        puppet = Puppet(layer: l.id)
    }

    /// Show the warp while Puppet Warp is open; the latest pins win.
    private func previewPuppet() {
        guard let p = puppet else { return }
        let params = json(p.warpParams)
        if puppetRunning {
            puppetNext = params
        } else {
            startPuppet(params)
        }
    }

    private func startPuppet(_ params: String) {
        puppetRunning = true
        let editor = editor
        Task.detached {
            let mesh = try? editor.previewPuppet(params: params)
            await MainActor.run {
                self.puppetRunning = false
                if self.puppet != nil, let mesh { self.puppetMesh = mesh }
                self.needsDraw = true
                self.overlayDirty = true
                if let next = self.puppetNext {
                    self.puppetNext = nil
                    if self.puppet != nil { self.startPuppet(next) }
                }
            }
        }
    }

    /// Free Transform the active layer (inside the selection when there is one).
    func beginTransform() {
        // As in Photoshop, the locked Background transforms only inside a selection.
        if activeLayer?.isBackground == true, doc?.hasSelection != true {
            toast = "The Background is locked: tap its lock in Layers to transform it"
            return
        }
        guard let b = editor.transformBounds(mask: maskTarget)?.map(Float.init), b.count == 4 else {
            toast = "Nothing to transform on this layer"
            return
        }
        transform = TransformBox(x0: b[0], y0: b[1], x1: b[2], y1: b[3])
    }

    private func transformParams(_ t: TransformBox) -> [String: Any] {
        var p: [String: Any] = ["rect": [t.x0, t.y0, t.x1, t.y1].map { Double($0) }, "quad": t.quad.map { [Double($0.x), Double($0.y)] }]
        if maskTarget { p["target"] = "mask" }
        return p
    }

    /// Show the transform's result while the box is open; the latest box wins.
    private func previewTransform() {
        guard let t = transform, t.dx != 0 || t.dy != 0 || t.sx != 1 || t.sy != 1 || t.angle != 0 else {
            previewNext = nil
            editor.endPreview()
            needsDraw = true
            return
        }
        let p = json(transformParams(t))
        if previewRunning {
            previewNext = p
        } else {
            startPreview(p)
        }
    }

    private func startPreview(_ p: String) {
        previewRunning = true
        let editor = editor
        Task.detached {
            try? editor.previewTransform(params: p)
            await MainActor.run {
                self.previewRunning = false
                self.needsDraw = true
                if let next = self.previewNext {
                    self.previewNext = nil
                    if self.transform != nil { self.startPreview(next) }
                }
            }
        }
    }

    // MARK: - Work path

    func loadWorkPath() {
        guard let out = try? editor.execute(id: "path.info", params: json(["name": "work"])),
              let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let path = obj["path"] as? [String: Any],
              let subs = path["subpaths"] as? [[String: Any]]
        else { workPath = []; return }
        let pt = { (v: Any?) -> Point? in
            guard let a = v as? [NSNumber], a.count == 2 else { return nil }
            return Point(x: a[0].floatValue, y: a[1].floatValue)
        }
        workPath = subs.map { s in
            let knots = (s["knots"] as? [[String: Any]] ?? []).compactMap { k -> Knot? in
                guard let a = pt(k["anchor"]) else { return nil }
                return Knot(anchor: a, in: pt(k["in"]) ?? a, out: pt(k["out"]) ?? a)
            }
            return Subpath(knots: knots, closed: s["closed"] as? Bool ?? false)
        }
    }

    /// Replace the work path with `subpaths`.
    func setWorkPath(_ subpaths: [Subpath]) {
        workPath = subpaths
        let p: [String: Any] = ["subpaths": subpaths.map { ["closed": $0.closed, "knots": $0.knots.map(\.json)] }]
        _ = try? editor.execute(id: "path.set", params: json(["name": "work", "path": p]))
        sync()
    }
}

/// Apple's decoders: Core Image for camera raws, ImageIO (through Core Image) for other images.
enum AppleDecoder {
    /// The image as a 16-bit TIFF with its colour profile, or `nil` when Apple can't read it.
    static func tiff(_ data: Data, name: String) -> Data? {
        let image: CIImage
        var space: CGColorSpace?
        // Some raws (Fujifilm RAF) are only recognised with their type.
        let type = UTType(filenameExtension: (name as NSString).pathExtension)
        // CIRAWFilter also takes JPEG, HEIC, AVIF and JPEG XL, and would develop them like a raw.
        let isRaw = type?.conforms(to: .rawImage) == true || CIImage(data: data) == nil
        // A camera Apple doesn't support gives an empty image.
        if isRaw, let raw = CIRAWFilter(imageData: data, identifierHint: type?.identifier), let out = raw.outputImage, !out.extent.isInfinite, !out.extent.isEmpty {
            image = out
            // ProPhoto, so raw colour isn't clipped.
            space = CGColorSpace(name: CGColorSpace.rommrgb)
        } else if let (cg, orientation) = redrawnHEIF(data) {
            image = CIImage(cgImage: cg).oriented(orientation)
            space = cg.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        } else if let out = CIImage(data: data, options: [.applyOrientationProperty: true]) {
            image = out
            space = out.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        } else {
            return nil
        }
        return CIContext().tiffRepresentation(of: image, format: .RGBA16, colorSpace: space ?? CGColorSpaceCreateDeviceRGB())
    }

    /// A HEIC/HEIF redrawn as 16-bit RGBA, with its orientation; `nil` for anything else. iOS 27's
    /// Core Image misreads ImageIO's HEIF pixels (10-bit packed, and 16-bit with straight alpha).
    private static func redrawnHEIF(_ data: Data) -> (CGImage, CGImagePropertyOrientation)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }), type.conforms(to: .heif) || type.conforms(to: .heic),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init) ?? .up
        let space = cg.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 16, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return ctx.makeImage().map { ($0, orientation) }
    }
}

final class ResultBox: @unchecked Sendable {
    var out: String?
}

final class FoundBox: @unchecked Sendable {
    var value: ObjectFinder.Found?
}

func json(_ params: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: params) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}

extension UIColor {
    convenience init(rgba c: [Float]) {
        let v = { (i: Int) in CGFloat(i < c.count ? c[i] : 1) }
        self.init(red: v(0), green: v(1), blue: v(2), alpha: v(3))
    }

    var hex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        let q = { (v: CGFloat) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", q(r), q(g), q(b))
    }
}

/// Four corners tapped in any order, as top-left, top-right, bottom-right, bottom-left.
func clockwiseFromTopLeft(_ pts: [Point]) -> [Point] {
    let cx = pts.map(\.x).reduce(0, +) / Float(pts.count), cy = pts.map(\.y).reduce(0, +) / Float(pts.count)
    // Clockwise on screen (y down) is increasing angle.
    let sorted = pts.sorted { atan2($0.y - cy, $0.x - cx) < atan2($1.y - cy, $1.x - cx) }
    guard let start = sorted.indices.min(by: { sorted[$0].x + sorted[$0].y < sorted[$1].x + sorted[$1].y }) else { return pts }
    return Array(sorted[start...] + sorted[..<start])
}
