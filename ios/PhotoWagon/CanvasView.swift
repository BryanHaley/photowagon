import SwiftUI
import UIKit

/// The document canvas: Rust draws into this view's Metal layer every frame it changed.
struct CanvasView: UIViewRepresentable {
    let model: EditorModel

    func makeUIView(context: Context) -> CanvasUIView { CanvasUIView(model: model) }
    func updateUIView(_ view: CanvasUIView, context: Context) {}
}

final class CanvasUIView: UIView, UIPointerInteractionDelegate, UIGestureRecognizerDelegate {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    let model: EditorModel
    var link: CADisplayLink?
    var attached = false

    // Overlays, in points.
    let antsLight = CAShapeLayer()
    let antsDark = CAShapeLayer()
    let toolPath = CAShapeLayer()
    /// The brush outline under the mouse, trackpad or a hovering Pencil.
    let cursor = CAShapeLayer()
    var cursorAt: CGPoint?
    var pointer: UIPointerInteraction?
    /// Hue/Saturation's targeted adjustment, beside the Properties sheet: a recognizer keeps the
    /// drag when the sheet's presentation takes the touch from the view.
    let targetedPan = UIPanGestureRecognizer()

    // Keyboard
    lazy var bindings = model.editor.keyBindings()
    lazy var keys = Keys.commands(bindings, action: #selector(keyPressed(_:)))
    /// Space held: drags pan (Photoshop's Hand tool).
    var spaceDown = false

    // Touches
    enum Mode { case idle, tool, navigate, pan }
    var mode = Mode.idle
    var touches: [UITouch] = []
    var toolTouch: UITouch?
    /// Most fingers down at once in this gesture, when it started, and whether it moved.
    var gesture = (fingers: 0, start: 0.0, moved: false)
    var nav: (view: ViewState, center: CGPoint, distance: CGFloat, angle: CGFloat, anchor: Point)?
    /// How much twist the fingers made before the view started turning (nil: not turning yet).
    var navTurnFrom: Float?
    var hold: DispatchWorkItem?
    /// Object Selection: the finger was held, so it picks the highlighted object, not a box.
    var objectHold = false

    // The current tool gesture
    var startScreen = CGPoint.zero
    var startDoc = Point(x: 0, y: 0)
    var docPoints: [Point] = []
    var stroking = false
    var strokeStartTime: TimeInterval = 0
    var pending = PendingPoints()
    /// The Pencil's predicted points ahead of a live stroke.
    let predicted = CAShapeLayer()
    let symmetryGuide = CAShapeLayer()
    var moveApplied = (x: 0, y: 0)
    var moveKey = ""
    /// Move: copy the layer before the first step (⌥-drag), the moving layer's bounds and what it
    /// snaps to.
    var moveCopy = false
    var moveBox: [Float]?
    var snapX: [Float] = []
    var snapY: [Float] = []
    var moveShift = false
    /// Hue/Saturation's targeted adjustment: the range being dragged and its starting value.
    var targeted: (String, Double)?
    /// The first of two quickly typed opacity digits, and when.
    var firstDigit: (Int, TimeInterval)?
    var lastMove: TimeInterval = 0
    var previous = CGPoint.zero
    var sheetWasUp = false
    /// Scrubby Zoom: the zoom and point where the drag began.
    var scrubFrom: (zoom: Float, point: CGPoint, anchor: Point) = (1, .zero, Point(x: 0, y: 0))
    /// Rotate View: the view's rotation and the finger's angle when the drag began.
    var rotateFrom: (rotation: Float, angle: CGFloat) = (0, 0)
    /// ⌥ or the secondary button was down when the gesture began.
    var altDown = false
    var toolDrag = ToolDrag.none
    var penClosed = false
    var sliceRects: [[Float]] = []
    /// Work in progress: crop box, transform box, polygons, paths, markers.
    let pendingLines = CAShapeLayer()
    let pendingDots = CAShapeLayer()
    /// Dims what a crop cuts away.
    let shade = CAShapeLayer()
    /// Object Finder's highlight.
    let objectLayer = CALayer()
    /// Smart guides while moving a layer.
    let guideLines = CAShapeLayer()
    /// The magnifier for exact points, the pixel it shows (and the revision), and how often it
    /// fetched pixels.
    let loupe = LoupeView(frame: CGRect(x: 0, y: 0, width: Loupe.size, height: Loupe.size))
    var loupeShown: (x: Int, y: Int, revision: UInt64)?
    var loupeFetches = 0
    /// Counts hides, so a lingering one doesn't hide a loupe shown again since.
    var loupeHides = 0
    /// An eyedropper picking on the canvas for a settings screen (`EditorModel.canvasPick`).
    let pickPress = UILongPressGestureRecognizer()

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .black
        isAccessibilityElement = true
        accessibilityIdentifier = "canvas"
        accessibilityLabel = "Canvas"
        accessibilityTraits = .allowsDirectInteraction
        if let metal = layer as? CAMetalLayer {
            metal.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            metal.framebufferOnly = true
        }
        shade.fillColor = UIColor.black.withAlphaComponent(0.55).cgColor
        shade.fillRule = .evenOdd
        layer.addSublayer(shade)
        objectLayer.anchorPoint = .zero
        layer.addSublayer(objectLayer)
        guideLines.strokeColor = UIColor.systemPink.cgColor
        guideLines.lineWidth = 1
        guideLines.fillColor = nil
        layer.addSublayer(guideLines)
        for l in [predicted, symmetryGuide, antsLight, antsDark, toolPath, pendingLines, pendingDots, cursor] {
            l.fillColor = nil
            l.lineWidth = 1
            layer.addSublayer(l)
        }
        cursor.strokeColor = UIColor.white.cgColor
        for l in [pendingLines, pendingDots] {
            l.strokeColor = UIColor.white.cgColor
            l.shadowColor = UIColor.black.cgColor
            l.shadowOpacity = 0.9
            l.shadowRadius = 1
            l.shadowOffset = .zero
        }
        pendingDots.fillColor = UIColor.white.cgColor
        pendingDots.strokeColor = UIColor.black.cgColor
        cursor.shadowColor = UIColor.black.cgColor
        cursor.shadowOpacity = 0.8
        cursor.shadowRadius = 0.5
        cursor.shadowOffset = .zero

        // Mouse wheel and two-finger trackpad scroll: pan, or zoom with ⌥ or ⌘.
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        addGestureRecognizer(scroll)
        // Trackpad pinch and rotate (finger pinches go through the touch handling below).
        let indirect = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.allowedTouchTypes = indirect
        addGestureRecognizer(pinch)
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(rotated(_:)))
        rotate.allowedTouchTypes = indirect
        addGestureRecognizer(rotate)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        addPencilInteraction()
        predicted.fillColor = nil
        predicted.lineCap = .round
        predicted.lineJoin = .round
        symmetryGuide.fillColor = nil
        symmetryGuide.strokeColor = UIColor.systemCyan.cgColor
        symmetryGuide.lineWidth = 1
        symmetryGuide.lineDashPattern = [6, 4]
        targetedPan.addTarget(self, action: #selector(targetedPanned(_:)))
        targetedPan.delegate = self
        targetedPan.isEnabled = false
        addGestureRecognizer(targetedPan)
        pickPress.addTarget(self, action: #selector(pickPressed(_:)))
        pickPress.minimumPressDuration = 0
        pickPress.allowableMovement = .greatestFiniteMagnitude
        pickPress.isEnabled = false
        addGestureRecognizer(pickPress)
        let pointer = UIPointerInteraction(delegate: self)
        addInteraction(pointer)
        self.pointer = pointer
        antsLight.strokeColor = UIColor.white.cgColor
        antsDark.strokeColor = UIColor.black.cgColor
        antsDark.lineDashPattern = [4, 4]
        let march = CABasicAnimation(keyPath: "lineDashPhase")
        (march.fromValue, march.toValue, march.duration, march.repeatCount) = (0, 8, 0.5, .infinity)
        antsDark.add(march, forKey: "march")
        toolPath.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        toolPath.lineDashPattern = [5, 3]
        addSubview(loupe)
    }

    required init?(coder: NSCoder) { nil }

    var scale: CGFloat { window?.screen.scale ?? UIScreen.main.scale }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, window != nil else { return }
        layer.contentsScale = scale
        for l in [shade, predicted, symmetryGuide, antsLight, antsDark, toolPath, pendingLines, pendingDots, cursor, guideLines] { l.frame = bounds }
        let (w, h) = (UInt32(bounds.width * scale), UInt32(bounds.height * scale))
        if !attached, let metal = layer as? CAMetalLayer {
            let address = UInt64(UInt(bitPattern: Unmanaged.passUnretained(metal).toOpaque()))
            do {
                try model.editor.attach(layer: address, width: w, height: h)
                attached = true
            } catch {
                model.show(error)
            }
        } else {
            model.editor.resize(width: w, height: h)
        }
        model.canvasResized(width: w, height: h, scale: Float(scale))
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            becomeFirstResponder()
            if link == nil {
                let l = CADisplayLink(target: self, selector: #selector(tick))
                l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
                l.add(to: .main, forMode: .common)
                link = l
            }
        } else {
            link?.invalidate()
            link = nil
            if attached {
                model.editor.detach()
                attached = false
            }
        }
    }

    @objc func tick() {
        guard attached, !model.busy else { return }
        let ready = pending.takeReady(now: CACurrentMediaTime())
        if !ready.isEmpty {
            do { try model.editor.strokePush(points: ready) } catch { model.show(error) }
            model.needsDraw = true
        }
        if model.needsDraw {
            model.needsDraw = false
            model.editor.draw(view: model.view)
            model.noteView()
        }
        if model.overlayDirty {
            model.overlayDirty = false
            updateAnts()
            updateSymmetry()
            updateObjectHighlight()
            updatePending()
            updateCursor()
            pointer?.invalidate()
        }
        let sidePan = model.targetedAdjust != nil || model.sheetDrag != nil
        if targetedPan.isEnabled != sidePan { targetedPan.isEnabled = sidePan }
        if pickPress.isEnabled != (model.canvasPick != nil) { pickPress.isEnabled = model.canvasPick != nil }
        if window?.rootViewController?.presentedViewController != nil {
            // A sheet covers the canvas: whatever gesture began here is over.
            sheetWasUp = true
            if mode != .idle {
                if mode == .tool { toolCancelled() }
                touches.removeAll()
                (mode, nav) = (.idle, nil)
            }
        } else if sheetWasUp {
            // Take the keyboard back when a sheet closes (not every frame: a text field in the
            // options row needs it too).
            sheetWasUp = false
            becomeFirstResponder()
        }
    }

    // MARK: - Coordinates

    func pixels(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale, y: p.y * scale) }

    func toDoc(_ p: CGPoint) -> Point {
        let q = pixels(p)
        return screenToDoc(view: model.view, x: Float(q.x), y: Float(q.y))
    }

    func toScreen(_ d: Point) -> CGPoint {
        let p = docToScreen(view: model.view, x: d.x, y: d.y)
        return CGPoint(x: CGFloat(p.x) / scale, y: CGFloat(p.y) / scale)
    }

    // MARK: - Overlays

    func updateObjectHighlight() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let (image, r) = model.objectHighlight, r[2] > r[0], r[3] > r[1] else {
            objectLayer.contents = nil
            return
        }
        // The document rectangle on screen, whatever the zoom and rotation.
        let (o, x, y) = (toScreen(Point(x: r[0], y: r[1])), toScreen(Point(x: r[2], y: r[1])), toScreen(Point(x: r[0], y: r[3])))
        let (w, h) = (CGFloat(r[2] - r[0]), CGFloat(r[3] - r[1]))
        objectLayer.contents = image
        objectLayer.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        objectLayer.position = o
        objectLayer.setAffineTransform(CGAffineTransform(a: (x.x - o.x) / w, b: (x.y - o.y) / w, c: (y.x - o.x) / h, d: (y.y - o.y) / h, tx: 0, ty: 0))
    }

    func updateAnts() {
        let segs = model.editor.selectionOutline(view: model.view)
        let path = CGMutablePath()
        var i = 0
        while i + 3 < segs.count {
            path.move(to: CGPoint(x: CGFloat(segs[i]) / scale, y: CGFloat(segs[i + 1]) / scale))
            path.addLine(to: CGPoint(x: CGFloat(segs[i + 2]) / scale, y: CGFloat(segs[i + 3]) / scale))
            i += 4
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        antsLight.path = path
        antsDark.path = path
        CATransaction.commit()
    }

    func setToolPath(_ path: CGPath?, width: CGFloat = 1, dashed: Bool = true) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        toolPath.path = path
        toolPath.lineWidth = width
        toolPath.lineDashPattern = dashed ? [5, 3] : nil
        toolPath.lineCap = dashed ? .butt : .round
        toolPath.lineJoin = .round
        toolPath.strokeColor = (dashed ? UIColor.white.withAlphaComponent(0.9) : UIColor.systemPink.withAlphaComponent(0.45)).cgColor
        CATransaction.commit()
    }

    func polyline(_ pts: [Point], closed: Bool) -> CGPath {
        let path = CGMutablePath()
        if let first = pts.first {
            path.move(to: toScreen(first))
            for p in pts.dropFirst() { path.addLine(to: toScreen(p)) }
            if closed { path.closeSubpath() }
        }
        return path
    }

    /// The marquee from `a` to `b` (document points) as a screen path.
    func marquee(_ a: Point, _ b: Point, ellipse: Bool) -> CGPath {
        let (x0, y0, x1, y1) = (min(a.x, b.x), min(a.y, b.y), max(a.x, b.x), max(a.y, b.y))
        if ellipse {
            let (cx, cy, rx, ry) = ((x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) / 2, (y1 - y0) / 2)
            let pts = (0..<72).map { i -> Point in
                let t = Float(i) / 72 * 2 * .pi
                return Point(x: cx + rx * cos(t), y: cy + ry * sin(t))
            }
            return polyline(pts, closed: true)
        }
        return polyline([Point(x: x0, y: y0), Point(x: x1, y: y0), Point(x: x1, y: y1), Point(x: x0, y: y1)], closed: true)
    }

    // MARK: - Touches

    /// A touch that ended outside this view (a sheet swipe that began on the canvas) never
    /// reports its end here: forget finished touches so the canvas doesn't stay busy.
    func dropFinishedTouches() {
        touches.removeAll { $0.phase == .ended || $0.phase == .cancelled }
        if touches.isEmpty, mode != .idle {
            if mode == .tool { toolCancelled() }
            mode = .idle
            nav = nil
        }
    }

    override func touchesBegan(_ set: Set<UITouch>, with event: UIEvent?) {
        dropFinishedTouches()
        if !isFirstResponder { becomeFirstResponder() }
        // Working on the image settles on the tool picked: show its options.
        if model.pickingGroup != nil { model.pickingGroup = nil }
        if touches.isEmpty { gesture = (0, CACurrentMediaTime(), false) }
        touches.append(contentsOf: set)
        gesture.fingers = max(gesture.fingers, touches.count)
        if touches.count == 1, mode == .idle, let t = touches.first, spaceDown || EditorModel.fingerPans(t.type, tool: model.tool, pencilOnly: model.pencilOnly) {
            mode = .pan
            startScreen = pixels(t.location(in: self))
        } else if touches.count == 1, mode == .idle, let t = touches.first, !model.busy {
            mode = .tool
            toolTouch = t
            // ⌥-click or right-click: sample a colour, set the clone source, zoom out.
            let alt = event?.modifierFlags.contains(.alternate) == true || event?.buttonMask.contains(.secondary) == true
            previous = t.preciseLocation(in: self)
            toolBegan(ToolTouch(t, in: self), modifiers: event?.modifierFlags ?? [], alt: alt)
        } else if touches.count >= 2 {
            if mode == .tool { toolCancelled() }
            mode = .navigate
            startNavigation()
        }
    }

    override func touchesMoved(_ set: Set<UITouch>, with event: UIEvent?) {
        switch mode {
        case .tool:
            if let t = toolTouch, set.contains(t) {
                toolMoved(ToolTouch(t, in: self), samples: event?.coalescedTouches(for: t)?.map { ToolTouch($0, in: self) }, modifiers: event?.modifierFlags ?? [])
                showPrediction(t.type == .pencil ? event?.predictedTouches(for: t) : nil)
            }
        case .navigate:
            navigate()
        case .pan:
            if let t = touches.first {
                let p = pixels(t.location(in: self))
                model.pan(dx: Float(p.x - startScreen.x), dy: Float(p.y - startScreen.y))
                startScreen = p
            }
        case .idle:
            break
        }
        if let t = set.first, t.type != .direct { showCursor(at: t.location(in: self)) }
    }

    override func touchesEstimatedPropertiesUpdated(_ set: Set<UITouch>) {
        for t in set {
            guard let i = t.estimationUpdateIndex?.intValue else { continue }
            let s = ToolTouch(t, in: self)
            pending.update(i, pressure: s.pressure, tilt: s.tilt, rotation: s.rotation)
        }
    }

    override func touchesEnded(_ set: Set<UITouch>, with event: UIEvent?) {
        showPrediction(nil)
        if mode == .tool, let t = toolTouch, set.contains(t) {
            toolEnded(ToolTouch(t, in: self), modifiers: event?.modifierFlags ?? [])
            toolTouch = nil
        }
        touches.removeAll { set.contains($0) }
        if mode == .navigate, touches.count >= 2 { startNavigation() }
        if touches.isEmpty {
            if mode == .navigate, !gesture.moved, CACurrentMediaTime() - gesture.start < 0.3 {
                if gesture.fingers == 2 { model.run("edit.undo") }
                if gesture.fingers == 3 { model.run("edit.redo") }
            }
            mode = .idle
            nav = nil
        }
    }

    override func touchesCancelled(_ set: Set<UITouch>, with event: UIEvent?) {
        showPrediction(nil)
        if mode == .tool { toolCancelled() }
        touches.removeAll { set.contains($0) }
        if touches.isEmpty { mode = .idle; nav = nil }
    }

    // MARK: - Navigation (two fingers: pan, pinch, rotate)

    func startNavigation() {
        guard touches.count >= 2 else { return }
        let (a, b) = (pixels(touches[0].location(in: self)), pixels(touches[1].location(in: self)))
        let c = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        nav = (model.view, c, hypot(b.x - a.x, b.y - a.y), atan2(b.y - a.y, b.x - a.x), screenToDoc(view: model.view, x: Float(c.x), y: Float(c.y)))
        navTurnFrom = nil
    }

    /// The view's turn for a twist of `twist` radians: on an unrotated view nothing until the twist
    /// passes ±20°, then it follows from there without a jump; an already rotated view turns at once.
    /// `from` keeps where the turning began.
    static func navTurn(twist: Float, rotated: Bool, from: inout Float?) -> Float {
        let twist = remainder(twist, 2 * .pi)
        if from == nil {
            let deadZone: Float = 20 * .pi / 180
            if rotated { from = 0 } else if abs(twist) > deadZone { from = twist > 0 ? deadZone : -deadZone }
        }
        guard let from else { return 0 }
        return twist - from
    }

    func navigate() {
        guard let n = nav, touches.count >= 2, n.distance > 0 else { return }
        let (a, b) = (pixels(touches[0].location(in: self)), pixels(touches[1].location(in: self)))
        let c = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let d = hypot(b.x - a.x, b.y - a.y)
        if abs(d - n.distance) > 12 || hypot(c.x - n.center.x, c.y - n.center.y) > 12 { gesture.moved = true }
        guard gesture.moved else { return }
        var v = n.view
        v.zoom = min(max(n.view.zoom * Float(d / n.distance), 0.01), 64)
        let r = n.view.rotation + Self.navTurn(twist: Float(atan2(b.y - a.y, b.x - a.x) - n.angle), rotated: abs(remainder(n.view.rotation, 2 * .pi)) > 0.0001, from: &navTurnFrom)
        v.rotation = r
        // Keep the document point first under the fingers under them.
        let (sx, sy) = (Float(c.x) - Float(v.width) / 2, Float(c.y) - Float(v.height) / 2)
        let (cs, sn) = (cos(-r), sin(-r))
        v.centerX = n.anchor.x - (sx * cs - sy * sn) / v.zoom
        v.centerY = n.anchor.y - (sx * sn + sy * cs) / v.zoom
        model.view = v
        model.needsDraw = true
        model.overlayDirty = true
        setToolPath(nil)
    }

    /// ⇧ makes the marquee square (a circle for the ellipse).
    func constrained(_ p: Point, _ modifiers: UIKeyModifierFlags) -> Point {
        guard modifiers.contains(.shift) else { return p }
        let (dx, dy) = (p.x - startDoc.x, p.y - startDoc.y)
        let side = max(abs(dx), abs(dy))
        return Point(x: startDoc.x + (dx < 0 ? -side : side), y: startDoc.y + (dy < 0 ? -side : side))
    }

    // MARK: - Keyboard

    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? { keys }

    @objc func keyPressed(_ c: UIKeyCommand) {
        dropFinishedTouches()
        guard let value = c.propertyList as? String, let colon = value.firstIndex(of: ":"), mode == .idle || mode == .pan else { return }
        let (kind, id) = (String(value[..<colon]), String(value[value.index(after: colon)...]))
        switch kind {
        case "tool":
            selectTool(id, next: c.modifierFlags.contains(.shift))
        case "app" where id == "commit":
            model.commitPending()
        case "app":
            model.cancelPending()
        case "command":
            // Keys for New, Save, Close, … open the app's own screens.
            model.performKey(id)
        default:
            shell(id)
        }
    }

    /// The tool for `id`'s key: the current one when it shares the key, else `id`; with `next`
    /// the one after the current among those sharing the key.
    func selectTool(_ id: String, next: Bool) {
        guard let key = bindings.first(where: { $0.id == id })?.shortcut else { return }
        let group = bindings.filter { $0.kind == "tool" && $0.shortcut == key }.flatMap { b in Tool.allCases.filter { $0.engineId == b.id } }
        guard let first = group.first else { return }
        model.pickingGroup = nil
        if let i = group.firstIndex(of: model.tool) {
            if next { model.tool = group[(i + 1) % group.count] }
        } else {
            model.tool = first
        }
        updateCursor()
        pointer?.invalidate()
    }

    func shell(_ id: String) {
        switch id {
        case "view.zoomIn": model.zoom(by: 1.5)
        case "view.zoomOut": model.zoom(by: 1 / 1.5)
        case "view.fitOnScreen": model.fit()
        case "view.actualPixels": model.zoom(by: 1 / model.view.zoom)
        case "edit.freeTransform": model.beginTransform()
        case "edit.puppetWarp": model.beginPuppet()
        default: if let r = EditorModel.request(for: id) { model.request = r }
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key?.keyCode == .keyboardSpacebar && $0.key?.modifierFlags.isEmpty == true }) {
            spaceDown = true
        } else if presses.contains(where: { $0.key?.keyCode == .keyboardGraveAccentAndTilde }), model.tool.brushOptions {
            // Hold ` (~): the brush erases until it's let go.
            model.setBrush(path: "erase", true)
        } else if let key = presses.first?.key, [.keyboardLeftArrow, .keyboardRightArrow].contains(key.keyCode), model.tool.brushOptions,
                  key.modifierFlags.subtracting([.shift, .numericPad]).isEmpty {
            model.rotateBrush(clockwise: key.keyCode == .keyboardRightArrow, shift: key.modifierFlags.contains(.shift))
        } else if presses.contains(where: { $0.key?.keyCode == .keyboardCapsLock }) {
            model.preciseCursor.toggle()
            model.overlayDirty = true
        } else if let key = presses.first?.key, key.modifierFlags.subtracting([.shift, .numericPad]).isEmpty,
                  let d = Int(key.charactersIgnoringModifiers), (0...9).contains(d), key.charactersIgnoringModifiers.count == 1 {
            opacityKey(d, shift: key.modifierFlags.contains(.shift), time: event?.timestamp ?? 0)
        } else {
            super.pressesBegan(presses, with: event)
        }
    }

    /// Number keys set opacity, as in Photoshop: 1 = 10% … 0 = 100%, two digits typed quickly an
    /// exact value (4 then 5 = 45%). Painting tools take it as their opacity (⇧: flow); tools
    /// with no opacity of their own set the selected layers' (⇧: fill). Strength and exposure
    /// tools are left alone.
    func opacityKey(_ d: Int, shift: Bool, time: TimeInterval) {
        var value = d == 0 ? 100 : d * 10
        if let (first, at) = firstDigit, time - at < 0.8 {
            value = first * 10 + d
            firstDigit = nil
        } else {
            firstDigit = (d, time)
        }
        let v = Double(value) / 100
        let tool = model.tool
        if [.brush, .pencil, .eraser, .clone, .patternStamp, .historyBrush, .mixerBrush].contains(tool) {
            model.setBrush(shift && tool != .pencil ? "flow" : "opacity", max(v, 0.01))
        } else if tool.hasOpacity {
            return
        } else if let a = model.activeLayer, !a.isBackground {
            let ids = model.selectedLayers.count > 1 ? model.selectedLayers.map(\.id) : [a.id]
            model.run("layer.setProps", ["layers": ids, shift ? "fill" : "opacity": v])
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key?.keyCode == .keyboardSpacebar }) {
            spaceDown = false
            if mode == .pan { mode = .idle }
        } else if presses.contains(where: { $0.key?.keyCode == .keyboardGraveAccentAndTilde }), model.brushErases {
            model.setBrush(path: "erase", false)
        } else {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        spaceDown = false
        super.pressesCancelled(presses, with: event)
    }

    // MARK: - Mouse, trackpad and hover

    @objc func scrolled(_ g: UIPanGestureRecognizer) {
        let d = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        if g.modifierFlags.contains(.alternate) || g.modifierFlags.contains(.command) {
            model.zoom(by: Float(exp(-d.y * 0.01)), at: pixels(g.location(in: self)))
        } else {
            model.pan(dx: Float(d.x * scale), dy: Float(d.y * scale))
        }
    }

    @objc func pinched(_ g: UIPinchGestureRecognizer) {
        model.zoom(by: Float(g.scale), at: pixels(g.location(in: self)))
        g.scale = 1
    }

    @objc func rotated(_ g: UIRotationGestureRecognizer) {
        let p = pixels(g.location(in: self))
        let anchor = screenToDoc(view: model.view, x: Float(p.x), y: Float(p.y))
        model.view.rotation += Float(g.rotation)
        g.rotation = 0
        model.place(anchor, at: p)
    }

    /// Hold to see the loupe, let go on the spot.
    @objc func pickPressed(_ g: UILongPressGestureRecognizer) {
        let t = ToolTouch(g.location(in: self))
        switch g.state {
        case .began, .changed: updateLoupe(t)
        case .ended:
            model.canvasPicked(toDoc(t.location))
            hideLoupe(linger: true)
        default: hideLoupe()
        }
    }

    @objc func targetedPanned(_ g: UIPanGestureRecognizer) {
        if let d = model.sheetDrag {
            let at = g.location(in: self)
            if g.state == .began {
                let tr = g.translation(in: self)
                startScreen = CGPoint(x: at.x - tr.x, y: at.y - tr.y)
            }
            if [.began, .changed, .ended].contains(g.state) { d.moved(g.state == .began, toDoc(startScreen), toDoc(at)) }
            return
        }
        guard let t = model.targetedAdjust else { return }
        switch g.state {
        case .began:
            let tr = g.translation(in: self)
            let at = g.location(in: self)
            startScreen = CGPoint(x: at.x - tr.x, y: at.y - tr.y)
            targetedBegan(t, at: toDoc(startScreen))
            targetedMoved(t, to: at)
        case .changed, .ended:
            targetedMoved(t, to: g.location(in: self))
            if g.state == .ended { targeted = nil }
        default:
            targeted = nil
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { g == targetedPan }

    @objc func hovered(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed: showCursor(at: g.location(in: self))
        default: showCursor(at: nil)
        }
        if model.tool == .objectSelect, mode == .idle {
            model.showObjects(at: g.state == .began || g.state == .changed ? toDoc(g.location(in: self)) : nil)
        }
    }

    func showCursor(at p: CGPoint?) {
        cursorAt = p
        updateCursor()
    }

    /// The brush outline at the pointer, at the brush's size on screen.
    func updateCursor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let p = cursorAt, model.tool.sized {
            let r = max(CGFloat(model.brushSize) * CGFloat(model.view.zoom) / scale / 2, 2)
            cursor.path = Self.cursorPath(at: p, radius: r, precise: model.preciseCursor)
        } else {
            cursor.path = nil
        }
        CATransaction.commit()
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        // The brush outline is the pointer while painting.
        model.tool.sized ? .hidden() : nil
    }
}
