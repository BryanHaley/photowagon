import SwiftUI

/// The Crop and Rotate screen's frame: an upright box of `size` document pixels round `center`,
/// turned clockwise on screen by `angle` degrees (as `image.crop` takes it). The screen keeps the
/// box upright and turns the image the other way. The box may reach past the image: the canvas
/// grows there.
struct CropFrame: Equatable {
    var center: CGPoint
    var size: CGSize
    var angle = 0.0

    /// The whole image, unturned.
    init(width: Double, height: Double) {
        center = CGPoint(x: width / 2, y: height / 2)
        size = CGSize(width: width, height: height)
    }

    /// The smallest side, in document pixels.
    static let minSide = 8.0

    var params: [String: Any] {
        ["x": Double(center.x - size.width / 2).rounded(), "y": Double(center.y - size.height / 2).rounded(),
         "width": Double(size.width).rounded(), "height": Double(size.height).rounded(), "angle": Self.normalized(angle)]
    }

    /// A vector along the box (screen axes, document pixels) in the document.
    func toDocument(_ v: CGVector) -> CGVector {
        let a = angle * .pi / 180
        return CGVector(dx: v.dx * cos(a) - v.dy * sin(a), dy: v.dx * sin(a) + v.dy * cos(a))
    }

    /// The image dragged by `screen` points at `scale` points per pixel: the box moves the other way.
    func panned(by screen: CGVector, scale: Double) -> CropFrame {
        var f = self
        let d = toDocument(CGVector(dx: screen.dx / scale, dy: screen.dy / scale))
        f.center = CGPoint(x: center.x - d.dx, y: center.y - d.dy)
        return f
    }

    /// Which sides a handle moves: -1 the left (top), 1 the right (bottom), 0 neither.
    struct Handle: Equatable, Hashable {
        var x: Int
        var y: Int
        static let all = [-1, 0, 1].flatMap { x in [-1, 0, 1].map { y in Handle(x: x, y: y) } }.filter { $0.x != 0 || $0.y != 0 }
    }

    /// `handle` dragged by `screen` points: its sides move, the opposite ones stay. With `aspect`
    /// (width / height) the box keeps that shape: a corner follows the larger move, an edge grows
    /// the other way about the middle.
    func resized(_ handle: Handle, by screen: CGVector, scale: Double, aspect: Double?) -> CropFrame {
        let (dx, dy) = (screen.dx / scale, screen.dy / scale)
        var (x0, y0, x1, y1) = (-size.width / 2, -size.height / 2, size.width / 2, size.height / 2)
        if handle.x < 0 { x0 = min(x0 + dx, x1 - Self.minSide) } else if handle.x > 0 { x1 = max(x1 + dx, x0 + Self.minSide) }
        if handle.y < 0 { y0 = min(y0 + dy, y1 - Self.minSide) } else if handle.y > 0 { y1 = max(y1 + dy, y0 + Self.minSide) }
        if let aspect, aspect > 0 {
            var (w, h) = (x1 - x0, y1 - y0)
            if handle.x != 0, handle.y != 0 {
                // The larger relative move wins.
                if w / size.width > h / size.height { h = w / aspect } else { w = h * aspect }
                if handle.x < 0 { x0 = x1 - w } else { x1 = x0 + w }
                if handle.y < 0 { y0 = y1 - h } else { y1 = y0 + h }
            } else if handle.x != 0 {
                h = w / aspect
                (y0, y1) = (-h / 2, h / 2)
            } else {
                w = h * aspect
                (x0, x1) = (-w / 2, w / 2)
            }
        }
        var f = self
        let mid = toDocument(CGVector(dx: (x0 + x1) / 2, dy: (y0 + y1) / 2))
        f.center = CGPoint(x: center.x + mid.dx, y: center.y + mid.dy)
        f.size = CGSize(width: x1 - x0, height: y1 - y0)
        return f
    }

    /// Turned to `angle` at `size`, then shrunk onto an `image` of that size if given. Pass the size
    /// the box had before turning shrank it, so turning back grows it again.
    func turned(to angle: Double, size: CGSize, inside image: CGSize?) -> CropFrame {
        var f = self
        f.angle = angle
        f.size = size
        guard let image else { return f }
        return f.keptInside(width: image.width, height: image.height)
    }

    /// The largest box of `aspect` (width / height) inside this one, about the same middle.
    func fitted(to aspect: Double) -> CropFrame {
        var f = self
        if size.width / size.height > aspect {
            f.size.width = size.height * aspect
        } else {
            f.size.height = size.width / aspect
        }
        return f
    }

    /// The box shrunk (keeping its shape) until the turned image covers it, so turning adds no
    /// canvas. Its middle moves onto the image first if it's off it.
    func keptInside(width: Double, height: Double) -> CropFrame {
        var f = self
        f.center = CGPoint(x: min(max(center.x, 0), width), y: min(max(center.y, 0), height))
        var s = 1.0
        for (cx, cy) in [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)] {
            let v = toDocument(CGVector(dx: cx * size.width / 2, dy: cy * size.height / 2))
            if v.dx > 0 { s = min(s, (width - f.center.x) / v.dx) } else if v.dx < 0 { s = min(s, f.center.x / -v.dx) }
            if v.dy > 0 { s = min(s, (height - f.center.y) / v.dy) } else if v.dy < 0 { s = min(s, f.center.y / -v.dy) }
        }
        s = max(s, Self.minSide / max(min(size.width, size.height), Self.minSide))
        f.size = CGSize(width: size.width * s, height: size.height * s)
        return f
    }

    /// The image's corners (a `width` × `height` document) in the cropped document, for selecting
    /// the canvas the crop adds.
    func imageCorners(width: Double, height: Double) -> [CGPoint] {
        let a = -angle * .pi / 180
        let (x0, y0) = ((center.x - size.width / 2).rounded(), (center.y - size.height / 2).rounded())
        return [(0.0, 0.0), (width, 0), (width, height), (0, height)].map { p in
            let (dx, dy) = (p.0 - center.x, p.1 - center.y)
            return CGPoint(x: dx * cos(a) - dy * sin(a) + center.x - x0, y: dx * sin(a) + dy * cos(a) + center.y - y0)
        }
    }

    /// The box reaches past the image somewhere (the crop adds canvas).
    func addsCanvas(width: Double, height: Double) -> Bool {
        let k = keptInside(width: width, height: height)
        return k.size.width < size.width - 0.5 || k.center != center
    }

    /// Degrees in (-180, 180].
    static func normalized(_ a: Double) -> Double {
        let r = a.truncatingRemainder(dividingBy: 360)
        return r > 180 ? r - 360 : r <= -180 ? r + 360 : r
    }
}

/// The Ratio menu's choices: width / height, `nil` for none.
enum CropAspect: String, CaseIterable, Identifiable {
    case freeform, original, square, r4x5, r5x4, r3x4, r4x3, r2x3, r3x2, r9x16, r16x9

    var id: String { rawValue }

    var title: String {
        switch self {
        case .freeform: "Freeform"
        case .original: "Original"
        case .square: "Square"
        default: rawValue.dropFirst().replacingOccurrences(of: "x", with: ":")
        }
    }

    func ratio(image: CGSize) -> Double? {
        switch self {
        case .freeform: return nil
        case .original: return image.height > 0 ? image.width / image.height : nil
        case .square: return 1
        default:
            let p = rawValue.dropFirst().split(separator: "x").compactMap { Double($0) }
            return p.count == 2 ? p[0] / p[1] : nil
        }
    }
}

/// What fills the canvas a crop adds (past the image, or uncovered by turning it).
enum CropFill: String, CaseIterable, Identifiable {
    case color, surroundings, ai, transparent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .color: "Color…"
        case .surroundings: "Fill from Surroundings"
        case .ai: "AI Fill"
        case .transparent: "Transparent"
        }
    }

}

/// The ☰ menu's Crop and Rotate: crop, straighten, turn and grow the canvas, then Done applies
/// it all.
struct CropRotateView: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var docSize = CGSize(width: 1, height: 1)
    @State private var frame = CropFrame(width: 1, height: 1)
    @State private var start: CropFrame?
    /// Points per document pixel, kept while a drag lasts so the box doesn't jump.
    @State private var heldScale: Double?
    @State private var aspect = CropAspect.freeform
    /// Lock Current Ratio: the box's shape when it was locked.
    @State private var lockedRatio: Double?
    @State private var fill = CropFill.color
    /// The Colour fill's colour (the background colour to start with).
    @State private var fillColor: UIColor?
    /// Turning keeps the box on the image (shrinking it), so it adds no canvas.
    @State private var keepInside = true
    @State private var turnFrom: CropFrame?
    /// The box's size before turning shrank it onto the image.
    @State private var unshrunk: CGSize?

    private var moving: Bool { start != nil || turnFrom != nil }
    private var ratio: Double? { lockedRatio ?? aspect.ratio(image: docSize) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { g in workArea(g.size) }
                AngleRuler(angle: frame.angle, begin: { turnFrom = frame; unshrunk = unshrunk ?? frame.size }, turn: { turn(to: $0) }, end: { turnFrom = nil })
                    .frame(height: 64)
                    .padding(.horizontal)
                controls
            }
            .background(Color.black)
            .overlay(alignment: .top) { if let hint = model.hint { HintBubble(model: model, text: hint).allowsHitTesting(false) } }
            .navigationTitle("Crop and Rotate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("crop.cancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { apply() }.accessibilityIdentifier("crop.done")
                }
            }
        }
        .task { await load() }
    }

    /// The image turned to `angle` degrees: from the box as the turn began, kept on the image.
    private func turn(to angle: Double) {
        let f = turnFrom ?? frame
        frame = f.turned(to: angle, size: unshrunk ?? f.size, inside: keepInside ? docSize : nil)
    }

    private func turnQuarter(clockwise: Bool) {
        let size = unshrunk ?? frame.size
        unshrunk = CGSize(width: size.height, height: size.width)
        withAnimation {
            frame = frame.turned(to: frame.angle + (clockwise ? -90 : 90), size: unshrunk ?? size, inside: keepInside ? docSize : nil)
        }
    }

    private func scale(_ area: CGSize) -> Double {
        heldScale ?? min((area.width - 48) / frame.size.width, (area.height - 48) / frame.size.height)
    }

    @ViewBuilder
    private func workArea(_ area: CGSize) -> some View {
        let k = scale(area)
        let c = CGPoint(x: area.width / 2, y: area.height / 2)
        let box = CGRect(x: c.x - frame.size.width * k / 2, y: c.y - frame.size.height * k / 2,
                         width: frame.size.width * k, height: frame.size.height * k)
        ZStack {
            if let image {
                Image(uiImage: image).resizable()
                    .frame(width: docSize.width * k, height: docSize.height * k)
                    .rotationEffect(.degrees(-frame.angle), anchor: UnitPoint(x: frame.center.x / docSize.width, y: frame.center.y / docSize.height))
                    .position(x: c.x + (docSize.width / 2 - frame.center.x) * k, y: c.y + (docSize.height / 2 - frame.center.y) * k)
            }
            // Outside the box dimmed; the box's own area, past the image, shows the canvas growing.
            Path { p in
                p.addRect(CGRect(origin: .zero, size: area))
                p.addRect(box)
            }
            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            Rectangle().stroke(.white, lineWidth: 1).frame(width: box.width, height: box.height).position(x: box.midX, y: box.midY)
                .allowsHitTesting(false)
            if moving {
                ThirdsGrid().stroke(.white.opacity(0.7), lineWidth: 0.5)
                    .frame(width: box.width, height: box.height).position(x: box.midX, y: box.midY)
                    .allowsHitTesting(false)
            }
            // Drag inside the box: move the image under it.
            Color.clear.contentShape(Rectangle())
                .frame(width: box.width, height: box.height).position(x: box.midX, y: box.midY)
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { d in
                        let s = start ?? frame
                        start = s
                        heldScale = k
                        frame = s.panned(by: CGVector(dx: d.translation.width, dy: d.translation.height), scale: k)
                    }
                    .onEnded { _ in endDrag() })
                .accessibilityIdentifier("crop.box")
            ForEach(CropFrame.Handle.all, id: \.self) { h in
                handle(h, box: box, k: k)
            }
        }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("crop.area")
    }

    private func handle(_ h: CropFrame.Handle, box: CGRect, k: Double) -> some View {
        let p = CGPoint(x: box.midX + Double(h.x) * box.width / 2, y: box.midY + Double(h.y) * box.height / 2)
        return HandleMark(handle: h)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .position(p)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { d in
                    let s = start ?? frame
                    start = s
                    heldScale = k
                    unshrunk = nil
                    frame = s.resized(h, by: CGVector(dx: d.translation.width, dy: d.translation.height), scale: k, aspect: ratio)
                }
                .onEnded { _ in endDrag() })
            .accessibilityIdentifier("crop.handle.\(h.x).\(h.y)")
    }

    private func endDrag() {
        start = nil
        withAnimation(.easeOut(duration: 0.25)) { heldScale = nil }
    }

    /// Icons only: touch and hold one for its name.
    private var controls: some View {
        HStack(spacing: 18) {
            icon("Reset", "arrow.counterclockwise", id: "crop.reset") { reset() }
            icon("Rotate 90° Left", "rotate.left", id: "crop.rotateLeft") { turnQuarter(clockwise: false) }
            icon("Rotate 90° Right", "rotate.right", id: "crop.rotateRight") { turnQuarter(clockwise: true) }
            icon(keepInside ? "Keep Inside Image: On" : "Keep Inside Image: Off", keepInside ? "square.dashed.inset.filled" : "square.dashed", id: "crop.keepInside") {
                keepInside.toggle()
                withAnimation { frame = frame.turned(to: frame.angle, size: unshrunk ?? frame.size, inside: keepInside ? docSize : nil) }
            }
            .accessibilityValue(keepInside ? "on" : "off")
            Menu {
                Picker("Fill Added Canvas", selection: Binding(get: { fill }, set: { f in
                    fill = f
                    if f == .color { pickFillColor() }
                })) {
                    ForEach(CropFill.allCases) { f in
                        // Only Color… opens something more.
                        if f == .color { Label(f.title, systemImage: "paintpalette").tag(f) } else { Text(f.title).tag(f) }
                    }
                }
            } label: {
                Image(systemName: "drop.halffull")
                    .overlay(alignment: .bottomTrailing) {
                        if fill == .color { Circle().fill(Color(fillColor ?? model.backgroundColor)).stroke(.white, lineWidth: 1).frame(width: 10, height: 10).offset(x: 5, y: 3) }
                    }
            }
            .frame(width: 40, height: 36)
            .accessibilityLabel("Fill Added Canvas")
            .accessibilityValue(fill.title)
            .accessibilityIdentifier("crop.fill")
            Menu {
                Picker("Ratio", selection: Binding(get: { lockedRatio == nil ? aspect : nil }, set: { if let a = $0 { setAspect(a) } })) {
                    ForEach(CropAspect.allCases) { Text($0.title).tag(Optional($0)) }
                }
                Toggle("Lock Current Ratio", isOn: Binding(get: { lockedRatio != nil }, set: { on in
                    lockedRatio = on ? frame.size.width / frame.size.height : nil
                    if !on { aspect = .freeform }
                }))
            } label: { Image(systemName: lockedRatio == nil ? "aspectratio" : "lock.rectangle") }
                .accessibilityLabel("Ratio")
                .accessibilityValue(lockedRatio == nil ? aspect.title : "Locked")
                .accessibilityIdentifier("crop.ratio")
        }
        .font(.title3)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func icon(_ title: String, _ symbol: String, id: String, _ action: @escaping () -> Void) -> some View {
        Image(systemName: symbol)
            .frame(width: 40, height: 36)
            .namedButton(title, model: model, action)
            .accessibilityIdentifier(id)
    }

    private func pickFillColor() {
        let c = fillColor ?? model.backgroundColor
        var (r, g, b, a) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        SystemColorPicker.present(title: "Fill Added Canvas", rgb: [Float(r), Float(g), Float(b)]) { rgb in
            fillColor = UIColor(rgba: rgb)
        }
    }

    private func setAspect(_ a: CropAspect) {
        aspect = a
        lockedRatio = nil
        unshrunk = nil
        if let r = a.ratio(image: docSize) { withAnimation { frame = frame.fitted(to: r) } }
    }

    private func reset() {
        withAnimation {
            frame = CropFrame(width: docSize.width, height: docSize.height)
            unshrunk = nil
            aspect = .freeform
            lockedRatio = nil
        }
    }

    private func load() async {
        guard let d = model.doc else { return }
        docSize = CGSize(width: Double(d.width), height: Double(d.height))
        frame = CropFrame(width: docSize.width, height: docSize.height)
        let editor = model.editor
        let png = await Task.detached(priority: .userInitiated) { try? editor.previewImage(maxSide: 2048) }.value
        if let png { image = UIImage(data: png) }
    }

    private func apply() {
        dismiss()
        guard frame != CropFrame(width: docSize.width, height: docSize.height) else { return }
        let adds = frame.addsCanvas(width: docSize.width, height: docSize.height)
        model.cropRotate(frame, fill: adds ? fill : .color, color: fillColor, image: docSize)
    }
}

extension EditorModel {
    /// Crop and Rotate's Done: the crop, and what fills the canvas it adds.
    func cropRotate(_ frame: CropFrame, fill: CropFill, color: UIColor? = nil, image: CGSize) {
        var p = frame.params
        if fill == .surroundings { p["contentAware"] = true }
        if fill == .transparent, layers.contains(where: \.isBackground) { run("layer.new.layerFromBackground") }
        guard fill == .ai else {
            // The crop fills the Background's new canvas with the background colour: this one, for
            // the crop only.
            let was = backgroundColor.hex
            if fill == .color, let color { run("tools.setColors", ["background": color.hex]) }
            runInBackground("image.crop", p) { [weak self] _ in
                if fill == .color, color != nil { self?.run("tools.setColors", ["background": was]) }
            }
            return
        }
        // AI Fill: the added canvas selected (all but where the image went), then AI Remove.
        let corners = frame.imageCorners(width: image.width, height: image.height).map { [Double($0.x), Double($0.y)] }
        runInBackground("image.crop", p) { [weak self] _ in
            guard let self else { return }
            self.run("select.all")
            self.run("select.lasso", ["points": corners, "mode": "subtract", "antiAlias": false])
            self.run("select.modify.expand", ["radius": 2, "applyAtCanvasBounds": true])
            // Without the model yet, AI Remove asks to download it and runs on the selection after.
            self.aiRemove(.selection) { [weak self] in if self?.inpainter != nil { self?.run("select.deselect") } }
        }
    }
}

/// Lines dividing a box in thirds each way.
struct ThirdsGrid: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        for i in 1...2 {
            let x = r.minX + r.width * Double(i) / 3, y = r.minY + r.height * Double(i) / 3
            p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
            p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
        }
        return p
    }
}

/// A corner's L or an edge's bar, drawn on the box's line.
private struct HandleMark: View {
    let handle: CropFrame.Handle

    var body: some View {
        Canvas { ctx, size in
            let (c, l) = (CGPoint(x: size.width / 2, y: size.height / 2), 18.0)
            var p = Path()
            if handle.x != 0, handle.y != 0 {
                p.move(to: CGPoint(x: c.x, y: c.y - Double(handle.y) * l))
                p.addLine(to: c)
                p.addLine(to: CGPoint(x: c.x - Double(handle.x) * l, y: c.y))
            } else if handle.x != 0 {
                p.move(to: CGPoint(x: c.x, y: c.y - l)); p.addLine(to: CGPoint(x: c.x, y: c.y + l))
            } else {
                p.move(to: CGPoint(x: c.x - l, y: c.y)); p.addLine(to: CGPoint(x: c.x + l, y: c.y))
            }
            ctx.stroke(p, with: .color(.white), style: StrokeStyle(lineWidth: 4, lineCap: .square))
        }
    }
}

/// Straighten: drag the ruler sideways, a degree a tick, round and round (it reads 0 again after a
/// full turn).
private struct AngleRuler: View {
    let angle: Double
    let begin: () -> Void
    let turn: (Double) -> Void
    let end: () -> Void
    @State private var from: Double?
    private let perDegree = 8.0

    /// What the ruler reads: within one turn either way.
    private var reading: Double {
        let r = angle.truncatingRemainder(dividingBy: 360)
        return abs(r) < 0.05 ? 0 : r
    }

    var body: some View {
        GeometryReader { g in
            let mid = g.size.width / 2
            ZStack {
                Canvas { ctx, size in
                    let span = Int(size.width / perDegree / 2) + 2
                    let base = Int(angle.rounded(.down))
                    for d in (base - span)...(base + span) {
                        let x = mid + (Double(d) - angle) * perDegree
                        let tall = d % 5 == 0
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: size.height - (tall ? 22 : 14)))
                        p.addLine(to: CGPoint(x: x, y: size.height - 6))
                        ctx.stroke(p, with: .color(.white.opacity(d % 90 == 0 ? 1 : 0.6)), lineWidth: tall ? 1.5 : 1)
                    }
                    var m = Path()
                    m.move(to: CGPoint(x: mid, y: size.height - 30)); m.addLine(to: CGPoint(x: mid, y: size.height - 2))
                    ctx.stroke(m, with: .color(.yellow), lineWidth: 2)
                }
                Text(String(format: "%.1f°", reading))
                    .font(.caption.monospacedDigit()).foregroundStyle(.white)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { d in
                    if from == nil { from = angle; begin() }
                    turn((((from ?? angle) - d.translation.width / perDegree) * 10).rounded() / 10)
                }
                .onEnded { _ in from = nil; end() })
        }
        .accessibilityElement()
        .accessibilityLabel("Straighten")
        .accessibilityValue(String(format: "%.1f degrees", reading))
        .accessibilityAdjustableAction { dir in
            begin()
            turn(angle + (dir == .increment ? 1 : -1))
            end()
        }
        .accessibilityIdentifier("crop.straighten")
    }
}
