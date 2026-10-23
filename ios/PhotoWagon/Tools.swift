import Foundation

/// The toolbox. Each tool maps to the engine's tool id (its key bindings) and, for most, one
/// engine command its gesture ends in.
enum Tool: String, CaseIterable, Identifiable {
    case move, artboard
    case marquee, ellipse, singleRow, singleColumn
    case lasso, polygonLasso, magneticLasso
    case objectSelect, quickSelect, magicWand
    case crop, perspectiveCrop, slice, sliceSelect
    case frame
    case eyedropper, colorSampler, ruler, note, count
    case spotHeal, remove, aiRemove, heal, patch, contentAwareMove, redEye
    case brush, pencil, colorReplacement, mixerBrush
    case clone, patternStamp
    case historyBrush
    case eraser, backgroundEraser, magicEraser
    case gradient, paintBucket
    case blur, sharpen, smudge
    case dodge, burn, sponge
    case pen, freeformPen, curvaturePen, addAnchor, deleteAnchor, convertPoint
    case type, verticalType, typeMask, verticalTypeMask
    case pathSelect, directSelect
    case rectangle, ellipseShape, triangle, polygon, line, customShape
    case hand, rotateView
    case zoomIn, zoomOut

    var id: String { rawValue }

    /// The view tools first, then Photoshop's toolbox groups in order.
    static let groups: [[Tool]] = [
        [.hand, .rotateView, .zoomIn, .zoomOut],
        [.move, .artboard],
        [.marquee, .ellipse, .singleRow, .singleColumn],
        [.lasso, .polygonLasso, .magneticLasso],
        [.objectSelect, .quickSelect, .magicWand],
        [.crop, .perspectiveCrop, .slice, .sliceSelect],
        [.frame],
        [.eyedropper, .colorSampler, .ruler, .note, .count],
        [.spotHeal, .remove, .aiRemove, .heal, .patch, .contentAwareMove, .redEye],
        [.brush, .pencil, .colorReplacement, .mixerBrush],
        [.clone, .patternStamp],
        [.historyBrush],
        [.eraser, .backgroundEraser, .magicEraser],
        [.gradient, .paintBucket],
        [.blur, .sharpen, .smudge],
        [.dodge, .burn, .sponge],
        [.pen, .freeformPen, .curvaturePen, .addAnchor, .deleteAnchor, .convertPoint],
        [.type, .verticalType, .typeMask, .verticalTypeMask],
        [.pathSelect, .directSelect],
        [.rectangle, .ellipseShape, .triangle, .polygon, .line, .customShape],
    ]

    /// The engine's id for the tool (`shell_commands::TOOLS`).
    var engineId: String {
        let name: String = switch self {
        case .marquee: "rectMarquee"
        case .ellipse: "ellipseMarquee"
        case .singleRow: "singleRowMarquee"
        case .singleColumn: "singleColumnMarquee"
        case .polygonLasso: "polygonLasso"
        case .objectSelect: "objectSelection"
        case .quickSelect: "quickSelection"
        case .spotHeal: "spotHealing"
        case .heal: "healing"
        case .clone: "cloneStamp"
        case .ellipseShape: "ellipseShape"
        case .typeMask: "horizontalTypeMask"
        case .pathSelect: "pathSelection"
        case .directSelect: "directSelection"
        case .zoomIn, .zoomOut: "zoom"
        case .addAnchor: "addAnchorPoint"
        case .deleteAnchor: "deleteAnchorPoint"
        default: rawValue
        }
        return "tools.select.\(name)"
    }

    var title: String {
        switch self {
        case .move: "Move"
        case .artboard: "Artboard"
        case .marquee: "Rectangular Marquee"
        case .ellipse: "Elliptical Marquee"
        case .singleRow: "Single Row Marquee"
        case .singleColumn: "Single Column Marquee"
        case .lasso: "Lasso"
        case .polygonLasso: "Polygonal Lasso"
        case .magneticLasso: "Magnetic Lasso"
        case .objectSelect: "Object Selection"
        case .quickSelect: "Quick Selection"
        case .magicWand: "Magic Wand"
        case .crop: "Crop"
        case .perspectiveCrop: "Perspective Crop"
        case .slice: "Slice"
        case .sliceSelect: "Slice Select"
        case .frame: "Frame"
        case .eyedropper: "Eyedropper"
        case .colorSampler: "Color Sampler"
        case .ruler: "Ruler"
        case .note: "Note"
        case .count: "Count"
        case .spotHeal: "Spot Repair Brush"
        case .remove: "Quick Fill"
        case .aiRemove: "AI Remove"
        case .heal: "Repair Brush"
        case .patch: "Patch"
        case .contentAwareMove: "Move and Fill"
        case .redEye: "Red Eye"
        case .brush: "Brush"
        case .pencil: "Pencil"
        case .colorReplacement: "Color Replacement"
        case .mixerBrush: "Mixer Brush"
        case .clone: "Clone Stamp"
        case .patternStamp: "Pattern Stamp"
        case .historyBrush: "History Brush"
        case .eraser: "Eraser"
        case .backgroundEraser: "Background Eraser"
        case .magicEraser: "Magic Eraser"
        case .gradient: "Gradient"
        case .paintBucket: "Paint Bucket"
        case .blur: "Blur"
        case .sharpen: "Sharpen"
        case .smudge: "Smudge"
        case .dodge: "Dodge"
        case .burn: "Burn"
        case .sponge: "Sponge"
        case .pen: "Pen"
        case .freeformPen: "Freeform Pen"
        case .curvaturePen: "Curvature Pen"
        case .addAnchor: "Add Anchor Point"
        case .deleteAnchor: "Delete Anchor Point"
        case .convertPoint: "Convert Point"
        case .type: "Horizontal Type"
        case .verticalType: "Vertical Type"
        case .typeMask: "Horizontal Type Mask"
        case .verticalTypeMask: "Vertical Type Mask"
        case .pathSelect: "Path Selection"
        case .directSelect: "Direct Selection"
        case .rectangle: "Rectangle"
        case .ellipseShape: "Ellipse"
        case .triangle: "Triangle"
        case .polygon: "Polygon"
        case .line: "Line"
        case .customShape: "Custom Shape"
        case .hand: "Hand"
        case .rotateView: "Rotate View"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        }
    }

    /// What the tool does and how to use it, for its long-press tip.
    var help: String {
        switch self {
        case .move: "Drag to move the layer."
        case .artboard: "Drag to draw an artboard."
        case .marquee: "Drag to select a rectangle."
        case .ellipse: "Drag to select an ellipse."
        case .singleRow: "Tap to select one row of pixels."
        case .singleColumn: "Tap to select one column of pixels."
        case .lasso: "Draw around an area to select it."
        case .polygonLasso: "Tap the corners to select."
        case .magneticLasso: "Trace an edge; it snaps to it."
        case .objectSelect: "Tap an object, or drag a box."
        case .quickSelect: "Paint over an area to select it."
        case .magicWand: "Tap to select a similar colour."
        case .crop: "Drag the box, then tap ✓."
        case .perspectiveCrop: "Tap four corners, then ✓."
        case .slice: "Drag to cut slices for the web."
        case .sliceSelect: "Tap a slice to pick it."
        case .frame: "Drag to draw a picture frame."
        case .eyedropper: "Tap to pick a colour."
        case .colorSampler: "Tap to mark a colour to read."
        case .ruler: "Drag to measure."
        case .note: "Tap to add a note."
        case .count: "Tap to add count marks."
        case .spotHeal: "Paint over a blemish."
        case .remove: "Paint over something to fill it."
        case .aiRemove: "Paint over or select; AI fills it."
        case .heal: "Hold to set a source, then paint."
        case .patch: "Select, then drag onto clean area."
        case .contentAwareMove: "Select and drag; the hole fills."
        case .redEye: "Tap a red eye to fix it."
        case .brush: "Paint. Hold to pick a colour."
        case .pencil: "Paint hard-edged lines."
        case .colorReplacement: "Paint to change colours."
        case .mixerBrush: "Paint that mixes colours."
        case .clone: "Hold to set a source, then paint."
        case .patternStamp: "Paint with a pattern."
        case .historyBrush: "Paint back an earlier state."
        case .eraser: "Paint to erase."
        case .backgroundEraser: "Paint to erase a colour."
        case .magicEraser: "Tap to erase a similar colour."
        case .gradient: "Drag to fill with a gradient."
        case .paintBucket: "Tap to fill a similar colour."
        case .blur: "Paint to soften detail."
        case .sharpen: "Paint to sharpen detail."
        case .smudge: "Drag to smear the paint."
        case .dodge: "Paint to lighten."
        case .burn: "Paint to darken."
        case .sponge: "Paint to take colour out."
        case .pen: "Tap for corners; drag for curves."
        case .freeformPen: "Draw a path freehand."
        case .curvaturePen: "Tap points; the path curves."
        case .addAnchor: "Tap a path to add a point."
        case .deleteAnchor: "Tap a path point to delete it."
        case .convertPoint: "Tap a point: corner or smooth."
        case .type: "Tap to add text; drag for a box."
        case .verticalType: "Tap to add vertical text."
        case .typeMask: "Tap to select in text shapes."
        case .verticalTypeMask: "Tap to select in vertical text."
        case .pathSelect: "Drag to move a path."
        case .directSelect: "Drag a path point to move it."
        case .rectangle: "Drag to draw a rectangle."
        case .ellipseShape: "Drag to draw an ellipse."
        case .triangle: "Drag to draw a triangle."
        case .polygon: "Drag to draw a polygon."
        case .line: "Drag to draw a line."
        case .customShape: "Drag to draw a custom shape."
        case .hand: "Drag to move around."
        case .rotateView: "Drag to turn the view."
        case .zoomIn: "Tap or drag a box to zoom in."
        case .zoomOut: "Tap to zoom out."
        }
    }

    var symbol: String {
        switch self {
        case .move: "arrow.up.and.down.and.arrow.left.and.right"
        case .artboard: "rectangle.on.rectangle"
        case .marquee: "rectangle.dashed"
        case .ellipse: "circle.dashed"
        case .singleRow: "arrow.left.and.right"
        case .singleColumn: "arrow.up.and.down"
        case .lasso: "lasso"
        case .polygonLasso: "pentagon"
        case .magneticLasso: "lasso.badge.sparkles"
        case .objectSelect: "viewfinder"
        case .quickSelect: "wand.and.stars"
        case .magicWand: "wand.and.rays"
        case .crop: "crop"
        case .perspectiveCrop: "perspective"
        case .slice: "square.split.2x2"
        case .sliceSelect: "square.split.2x2.fill"
        case .frame: "photo.artframe"
        case .eyedropper: "eyedropper"
        case .colorSampler: "eyedropper.halffull"
        case .ruler: "ruler"
        case .note: "note.text"
        case .count: "number"
        case .spotHeal: "bandage.fill"
        case .remove: "eraser.line.dashed"
        case .aiRemove: "wand.and.sparkles"
        case .heal: "bandage"
        case .patch: "square.dashed.inset.filled"
        case .contentAwareMove: "arrow.right.square"
        case .redEye: "eye"
        case .brush: "paintbrush.pointed"
        case .pencil: "pencil"
        case .colorReplacement: "paintpalette"
        case .mixerBrush: "drop.halffull"
        case .clone: "square.on.square.dashed"
        case .patternStamp: "square.grid.3x3.fill"
        case .historyBrush: "clock.arrow.circlepath"
        case .eraser: "eraser"
        case .backgroundEraser: "eraser.fill"
        case .magicEraser: "sparkles"
        case .gradient: "square.tophalf.filled"
        case .paintBucket: "drop"
        case .blur: "aqi.medium"
        case .sharpen: "triangle"
        case .smudge: "hand.point.up"
        case .dodge: "sun.max"
        case .burn: "flame"
        case .sponge: "circle.dotted"
        case .pen: "pencil.tip"
        case .freeformPen: "scribble"
        case .curvaturePen: "point.topleft.down.to.point.bottomright.curvepath"
        case .addAnchor: "plus.circle"
        case .deleteAnchor: "minus.circle"
        case .convertPoint: "chevron.up"
        case .type: "textformat"
        case .verticalType: "textformat.alt"
        case .typeMask: "character.cursor.ibeam"
        case .verticalTypeMask: "t.circle"
        case .pathSelect: "cursorarrow"
        case .directSelect: "cursorarrow.click"
        case .rectangle: "rectangle"
        case .ellipseShape: "circle"
        case .triangle: "triangle.fill"
        case .polygon: "hexagon"
        case .line: "line.diagonal"
        case .customShape: "star"
        case .hand: "hand.raised"
        case .rotateView: "rotate.right"
        case .zoomIn: "plus.magnifyingglass"
        case .zoomOut: "minus.magnifyingglass"
        }
    }

    /// The command a painting or retouching stroke ends in.
    var strokeCommand: String? {
        switch self {
        case .brush, .eraser: "paint.stroke"
        case .pencil: "paint.pencil"
        case .colorReplacement: "paint.colorReplacement"
        case .mixerBrush: "paint.mixerBrush"
        case .clone: "paint.cloneStamp"
        case .patternStamp: "paint.patternStamp"
        case .historyBrush: "paint.historyBrush"
        case .backgroundEraser: "paint.backgroundEraser"
        case .heal: "paint.healingBrush"
        case .spotHeal: "paint.spotHealing"
        case .remove, .aiRemove: "paint.remove"
        case .blur: "paint.blur"
        case .sharpen: "paint.sharpen"
        case .smudge: "paint.smudge"
        case .dodge: "paint.dodge"
        case .burn: "paint.burn"
        case .sponge: "paint.sponge"
        case .quickSelect: "select.quick"
        default: nil
        }
    }

    /// The engine renders this stroke live; the others show a trail and run on release.
    var livePreview: Bool {
        [.brush, .eraser, .pencil, .clone, .heal, .historyBrush, .blur, .sharpen, .dodge, .burn, .sponge].contains(self)
    }

    /// Has a brush size.
    var sized: Bool { strokeCommand != nil }
    /// Has a brush hardness.
    var hasHardness: Bool { sized && ![.pencil, .colorReplacement, .mixerBrush, .quickSelect, .remove, .aiRemove].contains(self) }
    /// What the opacity setting is called for this tool.
    var opacityTitle: String {
        switch self {
        case .dodge, .burn: "Exposure"
        case .blur, .sharpen, .smudge: "Strength"
        case .sponge: "Flow"
        default: "Opacity"
        }
    }
    /// Has an opacity (or exposure, strength).
    var hasOpacity: Bool { [.brush, .eraser, .pencil, .clone, .patternStamp, .historyBrush, .heal, .blur, .sharpen, .smudge, .dodge, .burn, .sponge].contains(self) }
    var selects: Bool { [.marquee, .ellipse, .singleRow, .singleColumn, .lasso, .polygonLasso, .magneticLasso, .objectSelect, .quickSelect, .magicWand].contains(self) }
    /// Touch and hold sets the clone source instead of sampling a colour.
    var usesSource: Bool { self == .clone || self == .heal }
    /// Fill-by-colour tools with a tolerance.
    var hasTolerance: Bool { [.magicWand, .paintBucket, .magicEraser].contains(self) }
    var pathTool: Bool { [.pen, .freeformPen, .curvaturePen, .addAnchor, .deleteAnchor, .convertPoint, .pathSelect, .directSelect].contains(self) }
    var typeTool: Bool { [.type, .verticalType, .typeMask, .verticalTypeMask].contains(self) }
    var shapeTool: Bool { [.rectangle, .ellipseShape, .triangle, .polygon, .line, .customShape].contains(self) }
    /// A drag draws a rectangle (in document pixels).
    var dragsRect: Bool {
        [.marquee, .ellipse, .objectSelect, .crop, .slice, .frame, .artboard, .zoomIn].contains(self) || (shapeTool && self != .line) || typeTool
    }
    /// A drag draws a line.
    var dragsLine: Bool { [.gradient, .ruler, .line].contains(self) }
    /// Touch and hold samples a colour (painting tools).
    var holdSamples: Bool { sized && !selects && self != .quickSelect }
}

enum GradientStyle: String, CaseIterable, Identifiable {
    case linear, radial, angle, reflected, diamond
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .linear: "square.tophalf.filled"
        case .radial: "circle.circle"
        case .angle: "rays"
        case .reflected: "square.split.1x2"
        case .diamond: "diamond"
        }
    }
}
