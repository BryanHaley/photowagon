import SwiftUI
import UIKit

/// What an Apple Pencil double-tap or squeeze does.
enum PencilAction: String, CaseIterable, Identifiable {
    case system, eraser, previousTool, colors, brushSettings, palette, undo, off
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "As in Settings"
        case .eraser: "Switch to Eraser"
        case .previousTool: "Previous Tool"
        case .colors: "Show Colors"
        case .brushSettings: "Brush Settings"
        case .palette: "Show Palette"
        case .undo: "Undo"
        case .off: "Off"
        }
    }

    /// The action iPadOS Settings › Apple Pencil chose.
    static func from(_ preferred: UIPencilPreferredAction) -> PencilAction {
        switch preferred {
        case .switchEraser: return .eraser
        case .switchPrevious: return .previousTool
        case .showColorPalette: return .colors
        case .showInkAttributes: return .brushSettings
        case .ignore, .runSystemShortcut: return .off
        default:
            if #available(iOS 17.5, *), preferred == .showContextualPalette { return .palette }
            return .off
        }
    }
}

/// Pressure response: how hard a press makes full pressure.
enum PencilPressure: String, CaseIterable, Identifiable {
    case light, normal, firm
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// The engine's `tools.pressureCurve` points.
    var curve: [[Double]] {
        switch self {
        case .light: [[0, 0], [0.3, 0.55], [1, 1]]
        case .normal: [[0, 0], [1, 1]]
        case .firm: [[0, 0], [0.6, 0.35], [1, 1]]
        }
    }

    static func matching(_ curve: [[Double]]) -> PencilPressure? {
        allCases.first { c in c.curve.count == curve.count && zip(c.curve, curve).allSatisfy { a, b in zip(a, b).allSatisfy { abs($0 - $1) < 0.001 } } }
    }
}

/// Apple Pencil: double-tap and squeeze, painting only with the Pencil, its pressure response.
extension EditorModel {
    var pencilTap: PencilAction {
        get { PencilAction(rawValue: defaults.string(forKey: "pencilTap") ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "pencilTap"); objectWillChange.send() }
    }

    var pencilSqueeze: PencilAction {
        get { PencilAction(rawValue: defaults.string(forKey: "pencilSqueeze") ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "pencilSqueeze"); objectWillChange.send() }
    }

    /// Fingers pan instead of painting. Starts as iPadOS's Only Draw with Apple Pencil.
    var pencilOnly: Bool {
        get { defaults.object(forKey: "pencilOnly") as? Bool ?? UIPencilInteraction.prefersPencilOnlyDrawing }
        set { defaults.set(newValue, forKey: "pencilOnly"); objectWillChange.send() }
    }

    var pencilPressure: PencilPressure? {
        get {
            let pts = (pref("tools.pressureCurve") as? [[NSNumber]])?.map { $0.map(\.doubleValue) } ?? PencilPressure.normal.curve
            return PencilPressure.matching(pts)
        }
        set {
            guard let newValue else { return }
            setPref("tools.pressureCurve", newValue.curve)
            objectWillChange.send()
        }
    }

    /// A one-finger touch pans rather than uses `tool` (with Pencil-only drawing).
    static func fingerPans(_ type: UITouch.TouchType, tool: Tool, pencilOnly: Bool) -> Bool {
        pencilOnly && type == .direct && tool.strokeCommand != nil
    }

    /// The action a double-tap or squeeze runs: the setting, or iPadOS's choice.
    func resolve(_ action: PencilAction, system: UIPencilPreferredAction) -> PencilAction {
        action == .system ? .from(system) : action
    }

    /// Run a Pencil action; `at` is where the Pencil hovers (for the palette), in canvas points.
    func perform(_ action: PencilAction, at point: CGPoint?) {
        switch action {
        case .eraser: switchEraser()
        case .previousTool: if let p = previousTool { tool = p }
        case .colors: SystemColorPicker.present(title: "Foreground", rgb: foreground.rgb) { [weak self] in self?.setForeground(UIColor(rgb: $0)) }
        case .brushSettings: showBrushSettings = true
        case .palette: pencilPalette = point ?? CGPoint(x: 200, y: 200)
        case .undo: run("edit.undo")
        case .system, .off: break
        }
    }

    /// The Eraser, and back to the tool before it.
    func switchEraser() {
        if tool == .eraser {
            tool = toolBeforeEraser ?? .brush
        } else {
            toolBeforeEraser = tool
            tool = .eraser
        }
    }
}

extension UIColor {
    var rgb: [Float] {
        var (r, g, b, a) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return [] }
        return [r, g, b].map(Float.init)
    }

    convenience init(rgb: [Float]) {
        let c = rgb.count == 3 ? rgb : [0, 0, 0]
        self.init(red: CGFloat(c[0]), green: CGFloat(c[1]), blue: CGFloat(c[2]), alpha: 1)
    }
}

/// Stroke points waiting for the next frame. A Pencil sample whose pressure or tilt is still an
/// estimate is held (with those after it) until its final values come, or `wait` seconds pass.
struct PendingPoints {
    private(set) var points: [StrokePoint] = []
    /// Estimation update index → the point it updates, and when it came.
    private var waiting: [Int: (index: Int, time: TimeInterval)] = [:]
    var wait: TimeInterval = 0.05

    var isEmpty: Bool { points.isEmpty }

    mutating func append(_ p: StrokePoint, update: Int? = nil, time: TimeInterval = 0) {
        if let update { waiting[update] = (points.count, time) }
        points.append(p)
    }

    /// The final pressure, tilt and rotation of the sample with estimation index `update`.
    mutating func update(_ update: Int, pressure: Float, tilt: (x: Float, y: Float), rotation: Float) {
        guard let w = waiting.removeValue(forKey: update), points.indices.contains(w.index) else { return }
        points[w.index].pressure = pressure
        (points[w.index].tiltX, points[w.index].tiltY, points[w.index].rotation) = (tilt.x, tilt.y, rotation)
    }

    /// The points ready to paint at `now`: up to the first one still waiting.
    mutating func takeReady(now: TimeInterval) -> [StrokePoint] {
        let held = waiting.values.filter { now - $0.time < wait }.map(\.index).min() ?? points.count
        let out = Array(points.prefix(held))
        points.removeFirst(out.count)
        waiting = waiting.compactMapValues { w in w.index >= out.count ? (w.index - out.count, w.time) : nil }
        return out
    }

    mutating func takeAll() -> [StrokePoint] {
        defer { removeAll() }
        return points
    }

    mutating func removeAll() {
        points.removeAll()
        waiting.removeAll()
    }
}

/// Double-tap and squeeze on the canvas, and the strokes' predicted points.
extension CanvasUIView: UIPencilInteractionDelegate {
    func addPencilInteraction() {
        let p = UIPencilInteraction()
        p.delegate = self
        addInteraction(p)
    }

    // Before iPadOS 17.5.
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        if #available(iOS 17.5, *) { return }
        model.perform(model.resolve(model.pencilTap, system: UIPencilInteraction.preferredTapAction), at: cursorAt)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        model.perform(model.resolve(model.pencilTap, system: UIPencilInteraction.preferredTapAction), at: tap.hoverPose?.location ?? cursorAt)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        model.perform(model.resolve(model.pencilSqueeze, system: UIPencilInteraction.preferredSqueezeAction), at: squeeze.hoverPose?.location ?? cursorAt)
    }

    /// Draw the Pencil's predicted points ahead of a live stroke; `nil` clears them.
    func showPrediction(_ touches: [UITouch]?) {
        guard let touches, !touches.isEmpty, stroking, model.tool.livePreview, let last = docPoints.last else {
            predicted.path = nil
            return
        }
        let path = CGMutablePath()
        path.move(to: toScreen(last))
        for t in touches { path.addLine(to: t.preciseLocation(in: self)) }
        predicted.path = path
        predicted.lineWidth = max(brushWidth, 1)
        predicted.strokeColor = model.foreground.withAlphaComponent(CGFloat(model.opacity)).cgColor
    }
}

/// The squeeze palette, beside the Pencil: tools, colours, size and opacity, undo and redo.
struct PencilPalette: View {
    @ObservedObject var model: EditorModel
    let at: CGPoint

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach([Tool.brush, .eraser, .smudge, .eyedropper], id: \.self) { t in
                    Button { model.tool = t; model.pencilPalette = nil } label: {
                        Image(systemName: t.symbol).frame(width: 40, height: 36)
                            .background(model.tool == t ? Color.white.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .accessibilityLabel(t.title)
                }
                Divider().frame(height: 28)
                Button { model.perform(.colors, at: nil) } label: {
                    Circle().fill(Color(model.foreground)).frame(width: 28, height: 28).overlay(Circle().stroke(.white, lineWidth: 2))
                }
                .accessibilityLabel("Foreground")
                .accessibilityIdentifier("pencilPalette.color")
            }
            row("Size", "\(Int(model.brushSize)) px", value: Binding(get: { model.brushSize }, set: { model.setBrush("size", $0.rounded()) }), in: 1...1000)
            row("Opacity", "\(Int(model.opacity * 100))%", value: Binding(get: { model.opacity }, set: { model.setBrush("opacity", max($0, 0.01)) }), in: 0.01...1)
            HStack {
                Button { model.run("edit.undo") } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                Spacer()
                Button { model.run("edit.redo") } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
            }
            .font(.callout)
        }
        .padding(12)
        .frame(width: 270)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .foregroundStyle(.white)
        .accessibilityIdentifier("pencilPalette")
    }

    private func row(_ title: String, _ text: String, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(title); Spacer(); Text(text).monospacedDigit().foregroundStyle(.secondary) }.font(.caption)
            Slider(value: value, in: range)
        }
    }
}

/// The symmetry axes and the painting cursor.
extension CanvasUIView {
    func updateSymmetry() {
        let l = model.symmetryLines
        let path = CGMutablePath()
        var i = 0
        while i + 3 < l.count {
            path.move(to: toScreen(Point(x: Float(l[i]), y: Float(l[i + 1]))))
            path.addLine(to: toScreen(Point(x: Float(l[i + 2]), y: Float(l[i + 3]))))
            i += 4
        }
        symmetryGuide.path = model.tool.brushOptions ? path : nil
    }

    /// The brush outline of radius `r` at `p`, with a small cross in its middle; just the cross
    /// for the precise cursor (Caps Lock).
    static func cursorPath(at p: CGPoint, radius r: CGFloat, precise: Bool) -> CGPath {
        let path = CGMutablePath()
        if !precise { path.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)) }
        let c: CGFloat = precise ? 9 : min(4, r / 2)
        if precise || r > 8 {
            path.move(to: CGPoint(x: p.x - c, y: p.y)); path.addLine(to: CGPoint(x: p.x + c, y: p.y))
            path.move(to: CGPoint(x: p.x, y: p.y - c)); path.addLine(to: CGPoint(x: p.x, y: p.y + c))
        }
        return path
    }
}
