import UIKit

/// One sample of a finger, mouse or Pencil on the canvas, in points.
struct ToolTouch {
    var location: CGPoint
    /// `UITouch.location`, which the zoom tools use (`location` is the precise one).
    var point: CGPoint
    var time: TimeInterval
    var pressure: Float = 1
    var tilt = (x: Float(0), y: Float(0))
    /// Barrel roll in degrees (Apple Pencil Pro).
    var rotation: Float = 0
    /// The sample's estimation update index while its pressure or tilt is still an estimate.
    var update: Int?
    /// A finger (not a mouse or Pencil): gets the loupe.
    var direct = true

    init(_ location: CGPoint, time: TimeInterval = 0) {
        (self.location, point, self.time) = (location, location, time)
    }

    @MainActor
    init(_ t: UITouch, in view: UIView) {
        (location, point, time) = (t.preciseLocation(in: view), t.location(in: view), t.timestamp)
        direct = t.type == .direct
        if t.type == .pencil {
            pressure = t.maximumPossibleForce > 0 ? Float(t.force / t.maximumPossibleForce) : 1
            let az = t.azimuthAngle(in: view)
            let cot = 1 / max(tan(t.altitudeAngle), 0.0001)
            tilt = (Float(atan(cos(az) * cot) * 180 / .pi), Float(atan(sin(az) * cot) * 180 / .pi))
            if #available(iOS 17.5, *) { rotation = Float(t.rollAngle * 180 / .pi) }
            if !t.estimatedPropertiesExpectingUpdates.isEmpty { update = t.estimationUpdateIndex?.intValue }
        }
    }
}

/// What each tool does with a one-finger (or mouse, or Pencil) gesture on the canvas.
extension CanvasUIView {
    // MARK: - Stroke points

    func strokePoint(_ t: ToolTouch, at p: CGPoint) -> StrokePoint {
        let d = toDoc(p)
        return StrokePoint(x: Double(d.x), y: Double(d.y), pressure: t.pressure, tiltX: t.tilt.x, tiltY: t.tilt.y, rotation: t.rotation,
                           timeMs: (t.time - strokeStartTime) * 1000)
    }

    func dp(_ p: Point) -> [Double] { [Double(p.x), Double(p.y)] }

    /// Screen distance in points between document points.
    func screenDistance(_ a: Point, _ b: Point) -> CGFloat {
        let (p, q) = (toScreen(a), toScreen(b))
        return hypot(p.x - q.x, p.y - q.y)
    }

    // MARK: - Began

    func toolBegan(_ t: ToolTouch, modifiers: UIKeyModifierFlags = [], alt: Bool = false) {
        defer { updateLoupe(t) }
        let p = t.location
        startScreen = p
        startDoc = toDoc(p)
        docPoints = [startDoc]
        stroking = false
        strokeStartTime = t.time
        pending.removeAll()
        altDown = alt
        toolDrag = .none

        // Hue/Saturation's targeted adjustment has a pan of its own (`targetedPanned`).
        if model.targetedAdjust != nil || model.sheetDrag != nil { return }
        // Fluid Warp takes the canvas while it is open: each drag is a stroke.
        if model.fluidWarp != nil { return }
        // Puppet Warp takes the canvas while it is open: tap to pin, drag a pin to bend.
        if let p = model.puppet {
            if let i = Reach.nearest(p.pins.map { toScreen($0.dst) }, to: toScreen(startDoc)) {
                model.puppet?.selected = i
                toolDrag = .pin(i)
            } else {
                model.puppet?.pins.append(Puppet.Pin(src: startDoc, dst: startDoc))
                model.puppet?.selected = p.pins.count
                toolDrag = .none
            }
            return
        }
        // Free Transform takes the canvas while it is open, whatever the tool.
        if let box = model.transform {
            toolDrag = transformDrag(box, at: startDoc)
            return
        }
        if alt, model.tool.holdSamples || model.tool == .eyedropper {
            held(startDoc)
            return
        }
        switch model.tool {
        case .move:
            moveApplied = (0, 0)
            moveKey = "move-\(UUID().uuidString)"
            lastMove = 0
            // Auto-Select, or ⌘ for a moment, picks the layer under the finger.
            if model.autoSelect != modifiers.contains(.command) {
                _ = try? model.editor.execute(id: "layer.pickAt", params: json(["x": Double(startDoc.x), "y": Double(startDoc.y)]))
                model.sync()
            }
            moveCopy = alt || model.moveCopies
            prepareSnap()
        case .zoomIn where model.scrubbyZoom:
            scrubFrom = (model.view.zoom, p, startDoc)
        case .eyedropper:
            model.sample(at: startDoc)
        case .rotateView:
            rotateFrom = (model.view.rotation, atan2(p.y - bounds.midY, p.x - bounds.midX))
        case .crop:
            if model.straightening {
                toolDrag = .straighten
            } else if let (a, b) = model.cropRect {
                // A corner or an edge resizes (and can go past the canvas to add to it); inside moves.
                let (x0, y0, x1, y1) = (min(a.x, b.x), min(a.y, b.y), max(a.x, b.x), max(a.y, b.y))
                let near = { (p: Point) in self.screenDistance(p, self.startDoc) < 24 }
                let corners = [Point(x: x0, y: y0), Point(x: x1, y: y0), Point(x: x1, y: y1), Point(x: x0, y: y1)]
                if let i = corners.firstIndex(where: near) {
                    toolDrag = .cropEdge(corners[(i + 2) % 4], x: true, y: true)
                } else if near(Point(x: startDoc.x, y: y0)) && startDoc.x > x0 && startDoc.x < x1 {
                    toolDrag = .cropEdge(Point(x: x0, y: y1), x: false, y: true, other: x1)
                } else if near(Point(x: startDoc.x, y: y1)) && startDoc.x > x0 && startDoc.x < x1 {
                    toolDrag = .cropEdge(Point(x: x0, y: y0), x: false, y: true, other: x1)
                } else if near(Point(x: x0, y: startDoc.y)) && startDoc.y > y0 && startDoc.y < y1 {
                    toolDrag = .cropEdge(Point(x: x1, y: y0), x: true, y: false, other: y1)
                } else if near(Point(x: x1, y: startDoc.y)) && startDoc.y > y0 && startDoc.y < y1 {
                    toolDrag = .cropEdge(Point(x: x0, y: y0), x: true, y: false, other: y1)
                } else if inside(startDoc, a, b) {
                    toolDrag = .moveCrop(a, b)
                }
            }
        case .marquee, .ellipse:
            if let box = model.marqueeBox, let part = boxPart(box, at: startDoc) {
                toolDrag = .marqueeBox(part, box)
            } else {
                model.marqueeBox = nil
            }
        case .polygonLasso, .perspectiveCrop:
            if let i = Reach.nearest(model.quad.map(toScreen), to: p) {
                toolDrag = .quadPoint(i)
            } else {
                showCandidate(startDoc)
            }
        case .ruler:
            if let (a, b) = model.ruler, let i = Reach.nearest([a, b].map(toScreen), to: p) { toolDrag = .rulerEnd(i) }
        case .colorSampler:
            if let i = Reach.nearest(model.samplers.map(toScreen), to: p) { toolDrag = .sampler(i, model.samplers[i]) }
        case .directSelect:
            toolDrag = pathHandleAt(startDoc) ?? .none
        case .pen:
            penBegan(at: startDoc)
        case .curvaturePen:
            curvatureTap(at: startDoc)
        default:
            break
        }
        objectHold = false
        if model.tool == .objectSelect, model.objectFinder {
            let at = startDoc
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.mode == .tool, !self.gesture.moved else { return }
                self.objectHold = true
                self.model.holdObject(at: at)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            hold = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
        }
        if model.tool.holdSamples || model.tool == .eyedropper {
            let at = startDoc
            let item = DispatchWorkItem { [weak self] in self?.held(at) }
            hold = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: item)
        }
    }

    /// Touch and hold (or ⌥-click, right-click): sample a colour, or set the clone source.
    func held(_ at: Point) {
        guard mode == .tool, !gesture.moved else { return }
        if stroking {
            model.editor.strokeCancel()
            stroking = false
        }
        if model.tool.usesSource {
            model.run("cloneSource.set", ["source": dp(at)])
            model.toast = "Clone source set"
        } else {
            model.sample(at: at)
        }
        mode = .idle
        toolTouch = nil
        setToolPath(nil)
        hideLoupe()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: - Moved

    /// `samples`: the coalesced touches since the last move (just `t` when there are none).
    func toolMoved(_ t: ToolTouch, samples: [ToolTouch]? = nil, modifiers: UIKeyModifierFlags = []) {
        defer { updateLoupe(t) }
        let p = t.location
        if !gesture.moved, hypot(p.x - startScreen.x, p.y - startScreen.y) > 4 {
            gesture.moved = true
            hold?.cancel()
        }
        guard gesture.moved else { return }
        let samples = samples ?? [t]
        let here = toDoc(p)
        if model.targetedAdjust != nil || model.sheetDrag != nil { return }
        if let w = model.fluidWarp {
            docPoints.append(contentsOf: samples.map { toDoc($0.location) })
            setToolPath(polyline(docPoints, closed: false), width: CGFloat(w.size) * CGFloat(model.view.zoom) / scale, dashed: false)
            return
        }
        if model.puppet != nil {
            if case let .pin(i) = toolDrag, model.puppet?.pins.indices.contains(i) == true { model.puppet?.pins[i].dst = here }
            return
        }
        if objectHold {
            model.showObjects(at: here)
            return
        }
        if model.transform != nil {
            transformMoved(to: here, shift: modifiers.contains(.shift), alt: modifiers.contains(.alternate))
            return
        }
        switch model.tool {
        case _ where model.tool.strokeCommand != nil:
            if !stroking { beginStroke(t, at: startScreen) }
            guard stroking else { return }
            for s in samples {
                var sp = strokePoint(s, at: s.location)
                if modifiers.contains(.shift) {
                    let q = EditorModel.axisLocked(Point(x: Float(sp.x), y: Float(sp.y)), from: startDoc)
                    (sp.x, sp.y) = (Double(q.x), Double(q.y))
                }
                pending.append(sp, update: s.update, time: CACurrentMediaTime())
                docPoints.append(Point(x: Float(sp.x), y: Float(sp.y)))
            }
            if !model.tool.livePreview { setToolPath(strokesPath(model.removeStrokes + [docPoints]), width: brushWidth, dashed: false) }
        case .zoomIn where model.scrubbyZoom:
            let factor = Float(exp((p.x - scrubFrom.point.x) * 0.01))
            model.view.zoom = min(max(scrubFrom.zoom * factor, 0.01), 64)
            model.place(scrubFrom.anchor, at: pixels(scrubFrom.point))
        case .marquee, .ellipse:
            if case let .marqueeBox(part, box) = toolDrag {
                model.marqueeBox = box.dragged(part, dx: here.x - startDoc.x, dy: here.y - startDoc.y, keepRatio: model.marqueeLockRatio)
            } else {
                let q = constrained(here, modifiers)
                setToolPath(marquee(startDoc, q, ellipse: model.tool == .ellipse))
            }
        case .polygonLasso, .perspectiveCrop:
            if case let .quadPoint(i) = toolDrag {
                if model.quad.indices.contains(i) { model.quad[i] = here }
            } else {
                showCandidate(here)
            }
        case .colorSampler:
            if case let .sampler(i, _) = toolDrag, model.samplers.indices.contains(i) {
                model.samplers[i] = here
                updatePending()
            }
        case .objectSelect, .slice, .frame, .artboard, .zoomIn, .rectangle, .ellipseShape, .triangle, .polygon, .customShape,
             .type, .verticalType, .typeMask, .verticalTypeMask:
            let q = constrained(here, modifiers)
            setToolPath(model.tool == .ellipse || model.tool == .ellipseShape ? marquee(startDoc, q, ellipse: true) : marquee(startDoc, q, ellipse: false))
        case .crop:
            if case .straighten = toolDrag {
                setToolPath(polyline([startDoc, here], closed: false))
            } else if case let .moveCrop(a, b) = toolDrag {
                let (dx, dy) = (here.x - startDoc.x, here.y - startDoc.y)
                model.cropRect = (Point(x: a.x + dx, y: a.y + dy), Point(x: b.x + dx, y: b.y + dy))
            } else if case let .cropEdge(fixed, x, y, other) = toolDrag {
                // The fixed corner stays; the dragged sides follow the finger.
                let far = Point(x: x ? here.x : (other ?? fixed.x), y: y ? here.y : (other ?? fixed.y))
                model.cropRect = (fixed, far)
            } else {
                model.cropAngle = 0
                model.cropRect = (startDoc, constrained(here, modifiers))
            }
        case .ruler:
            if case let .rulerEnd(i) = toolDrag, let (a, b) = model.ruler {
                model.ruler = i == 0 ? (here, b) : (a, here)
            } else {
                model.ruler = (startDoc, here)
            }
        case .gradient, .line:
            setToolPath(polyline([startDoc, here], closed: false))
        case .lasso, .magneticLasso, .freeformPen:
            docPoints.append(contentsOf: samples.map { toDoc($0.location) })
            setToolPath(polyline(docPoints, closed: false))
        case .patch, .contentAwareMove:
            setToolPath(polyline([startDoc, here], closed: false))
        case .move:
            moveShift = modifiers.contains(.shift)
            applyMove(to: here, force: false, time: t.time)
        case .eyedropper:
            model.sample(at: here)
        case .hand:
            let (a, b) = (pixels(p), pixels(previous))
            model.pan(dx: Float(a.x - b.x), dy: Float(a.y - b.y))
        case .rotateView:
            let c = CGPoint(x: bounds.midX, y: bounds.midY)
            let turn = Float(atan2(p.y - c.y, p.x - c.x) - rotateFrom.angle)
            // 5° steps (two-finger rotate turns freely).
            let step = Float.pi / 36
            let mid = pixels(c)
            let anchor = screenToDoc(view: model.view, x: Float(mid.x), y: Float(mid.y))
            model.view.rotation = ((rotateFrom.rotation + turn) / step).rounded() * step
            model.place(anchor, at: mid)
        case .pen:
            penDragged(to: here)
        case .directSelect:
            dragPathHandle(to: here)
        case .pathSelect:
            let d = (here.x - startDoc.x, here.y - startDoc.y)
            startDoc = here
            model.workPath = model.workPath.map { sp in
                Subpath(knots: sp.knots.map { k in
                    let m = { (q: Point) in Point(x: q.x + d.0, y: q.y + d.1) }
                    return Knot(anchor: m(k.anchor), in: m(k.inHandle), out: m(k.outHandle))
                }, closed: sp.closed)
            }
        default:
            break
        }
        previous = p
    }

    func beginStroke(_ t: ToolTouch, at p: CGPoint) {
        guard let (cmd, params) = model.strokeParams() else { return }
        do {
            try model.editor.strokeBegin(command: cmd, params: json(params), points: [strokePoint(t, at: p)])
            stroking = true
            model.needsDraw = true
        } catch {
            // Photoshop offers to rasterize a smart object, type or shape layer before painting on it.
            if let l = model.activeLayer, ["Embedded", "Type", "Shape", "Fill"].contains(l.kind) {
                model.rasterizePrompt = l
            } else {
                model.show(error)
            }
            if model.tool.usesSource { model.toast = "Touch and hold the image to set the clone source first." }
            mode = .idle
            toolTouch = nil
        }
    }

    /// Sideways from where the drag began: a point per step of saturation (or hue).
    func targetedMoved(_ t: TargetedAdjust, to p: CGPoint) {
        guard let (range, from) = targeted else { return }
        let key = t.hue ? "hue" : "saturation"
        let limit = t.hue ? 180.0 : 100.0
        let v = min(max(from + Double(p.x - startScreen.x), -limit), limit).rounded()
        var part = (model.layers.first { $0.id == t.layer }?.adjustment?.params[range] as? [String: Any]) ?? [:]
        guard (part[key] as? NSNumber)?.doubleValue != v else { return }
        part[key] = v
        model.run("layer.setAdjustment", ["layer": t.layer, range: part, "coalesce": t.key])
    }

    /// The colour range under the finger and its value when the drag began.
    func targetedBegan(_ t: TargetedAdjust, at p: Point) {
        targeted = nil
        guard let px = model.query("document.pixel", ["x": Int(p.x), "y": Int(p.y)]) as? [Double], px.count >= 3,
              let params = model.layers.first(where: { $0.id == t.layer })?.adjustment?.params else { return }
        let (r, g, b) = (px[0], px[1], px[2])
        let (mx, mn) = (max(r, g, b), min(r, g, b))
        guard mx - mn > 0.02 else {
            model.toast = "No color there to adjust"
            return
        }
        var hue = mx == r ? (g - b) / (mx - mn) : mx == g ? 2 + (b - r) / (mx - mn) : 4 + (r - g) / (mx - mn)
        hue = (hue * 60 + 360).truncatingRemainder(dividingBy: 360)
        // The range whose middle holds the hue (Reds' runs below 0°).
        let pick = HueSaturationProperties.ranges.first { name in
            guard let rr = (params[name] as? [String: Any])?["range"] as? [NSNumber], rr.count == 4 else { return false }
            let (lo, hi) = (rr[1].doubleValue, rr[2].doubleValue)
            return [hue, hue - 360, hue + 360].contains { $0 >= lo && $0 <= hi }
        } ?? HueSaturationProperties.ranges.min { a, b in
            func gap(_ n: String) -> Double {
                let rr = ((params[n] as? [String: Any])?["range"] as? [NSNumber])?.map(\.doubleValue) ?? [0, 0, 0, 0]
                let mid = (rr[1] + rr[2]) / 2
                return [hue, hue - 360, hue + 360].map { abs($0 - mid) }.min() ?? 999
            }
            return gap(a) < gap(b)
        }
        guard let range = pick else { return }
        let from = ((params[range] as? [String: Any])?[t.hue ? "hue" : "saturation"] as? NSNumber)?.doubleValue ?? 0
        targeted = (range, from)
        model.toast = "Adjusting \(range.capitalized)"
    }

    // MARK: - Ended

    func toolEnded(_ t: ToolTouch, modifiers: UIKeyModifierFlags = []) {
        defer { hideLoupe(linger: true) }
        hold?.cancel()
        let end = toDoc(t.location)
        let tapped = !gesture.moved
        if model.targetedAdjust != nil || model.sheetDrag != nil { return }
        if model.fluidWarp != nil {
            setToolPath(nil)
            model.fluidWarp?.add(docPoints.map(dp))
            return
        }
        if model.puppet != nil {
            toolDrag = .none
            return
        }
        if model.transform != nil {
            toolDrag = .none
            return
        }
        let mode = model.selectionMode.rawValue
        let rect = rectParams(startDoc, constrained(end, modifiers))
        switch model.tool {
        case _ where model.tool.strokeCommand != nil:
            if tapped, modifiers.contains(.shift) || model.straightLine, let a = model.lastStrokeEnd {
                docPoints = [a, end]
                beginStroke(t, at: toScreen(a))
                pending.append(strokePoint(t, at: t.location))
            } else if !stroking {
                beginStroke(t, at: startScreen)
            }
            guard stroking else { return }
            stroking = false
            model.lastStrokeEnd = docPoints.last
            if [.remove, .aiRemove].contains(model.tool), !model.removeEachStroke {
                pending.removeAll()
                model.editor.strokeCancel()
                model.removeStrokes.append(docPoints)
                return
            }
            if model.tool == .aiRemove {
                pending.removeAll()
                model.editor.strokeCancel()
                model.aiRemove(.strokes([docPoints])) { [weak self] in self?.setToolPath(nil) }
                return
            }
            if !pending.isEmpty {
                try? model.editor.strokePush(points: pending.takeAll())
            }
            if model.tool.livePreview {
                do { _ = try model.editor.strokeEnd() } catch { model.show(error) }
                model.sync()
            } else {
                // Content-aware fills and selection growing take a moment: off the main thread.
                model.whileBusy({ editor in _ = try editor.strokeEnd() }, then: { [weak self] in self?.setToolPath(nil) })
            }
        case .marquee, .ellipse:
            setToolPath(nil)
            let boxDrag: Bool = { if case .marqueeBox = toolDrag { return true }; return false }()
            toolDrag = .none
            if boxDrag, !tapped {
                model.applyMarqueeBox()
            } else if tapped || rect == nil {
                model.marqueeBox = nil
                if model.selectionMode == .replace, model.doc?.hasSelection == true { model.run("select.deselect") }
            } else if abs(remainder(model.view.rotation, .pi / 2)) > 0.01 {
                // A tilted view draws the marquee tilted on the document: select that shape.
                let e = constrained(end, modifiers)
                let corners = [startDoc, Point(x: e.x, y: startDoc.y), e, Point(x: startDoc.x, y: e.y)]
                model.run("select.lasso", ["points": corners.map(dp), "mode": mode].merging(model.edgeParams) { a, _ in a })
            } else if let r = rect {
                model.selectMarquee(r, ellipse: model.tool == .ellipse, mode: mode)
            }
        case .singleRow, .singleColumn:
            guard let d = model.doc else { return }
            let row = model.tool == .singleRow
            model.run("select.rect", ["x": row ? 0 : Int(end.x), "y": row ? Int(end.y) : 0, "width": row ? Int(d.width) : 1,
                                      "height": row ? 1 : Int(d.height), "line": row ? "row" : "column", "mode": mode])
        case .lasso:
            setToolPath(nil)
            if docPoints.count >= 3 {
                model.run("select.lasso", ["points": docPoints.map(dp), "mode": mode].merging(model.edgeParams) { a, _ in a })
            } else if model.selectionMode == .replace, model.doc?.hasSelection == true {
                model.run("select.deselect")
            }
        case .magneticLasso:
            setToolPath(nil)
            let pts = thinned(docPoints, every: 12)
            if pts.count >= 3 {
                let p = json(["points": pts.map(dp), "mode": mode])
                model.whileBusy { editor in _ = try editor.execute(id: "select.magneticLasso", params: p) }
            }
        case .polygonLasso:
            setToolPath(nil)
            if case let .quadPoint(i) = toolDrag {
                toolDrag = .none
                // Tapping the first point closes the shape.
                if tapped, i == 0, model.quad.count >= 3 { model.commitPending() }
            } else {
                model.quad.append(end)
            }
        case .objectSelect:
            setToolPath(nil)
            if tapped || rect == nil || objectHold {
                model.selectObject(at: end, mode: mode)
            } else {
                model.selectInBackground("select.object", ["rect": rect!, "mode": mode], nothing: "No object found there. Drag a box around it.")
            }
        case .magicWand:
            model.run("select.magicWand", ["x": Int(end.x), "y": Int(end.y), "tolerance": model.tolerance, "contiguous": model.contiguous, "sampleAllLayers": model.sampleAllLayers, "mode": mode])
        case .crop:
            if case .straighten = toolDrag {
                setToolPath(nil)
                model.straighten(from: startDoc, to: end)
                toolDrag = .none
                return
            }
            toolDrag = .none
            if tapped, model.cropRect == nil, let d = model.doc {
                model.cropRect = (Point(x: 0, y: 0), Point(x: Float(d.width), y: Float(d.height)))
            }
        case .perspectiveCrop:
            setToolPath(nil)
            if case .quadPoint = toolDrag {
                toolDrag = .none
                return
            }
            model.quad.append(end)
            if model.quad.count == 4 { model.toast = "Return or ✓ crops" }
            if model.quad.count > 4 { model.quad = [end] }
        case .slice:
            setToolPath(nil)
            if let r = rect { model.run("slice.new", ["rect": r]) }
            showSlices()
        case .sliceSelect:
            showSlices(at: end)
        case .frame:
            setToolPath(nil)
            if let r = rect { model.run("layer.new.frame", ["x": r[0], "y": r[1], "width": r[2], "height": r[3]]) }
        case .artboard:
            setToolPath(nil)
            if let r = rect { model.run("layer.new.artboard", ["rect": r]) }
        case .colorSampler:
            if case let .sampler(i, from) = toolDrag {
                toolDrag = .none
                guard !tapped else { return }
                if let out = model.run("view.colorSamplers.move", ["index": i, "x": Double(end.x), "y": Double(end.y)]) as? [String: Any],
                   let point = out["point"] as? [String: Any], let rgb = point["rgb"] as? [NSNumber], rgb.count >= 3 {
                    model.toast = "#\(i + 1): R \(rgb[0]) G \(rgb[1]) B \(rgb[2])"
                } else if model.samplers.indices.contains(i) {
                    model.samplers[i] = from
                }
                updatePending()
            } else if let out = model.run("view.colorSamplers.add", ["x": Double(end.x), "y": Double(end.y)]) as? [String: Any],
               let point = out["point"] as? [String: Any], let rgb = point["rgb"] as? [NSNumber] {
                model.samplers.append(end)
                model.toast = "#\(model.samplers.count): R \(rgb[0]) G \(rgb[1]) B \(rgb[2])"
                updatePending()
            }
        case .ruler:
            setToolPath(nil)
            toolDrag = .none
        case .note:
            let at = end
            model.prompt = TextPrompt(title: "Note", text: "") { [weak self] text in
                self?.model.run("notes.add", ["x": Double(at.x), "y": Double(at.y), "text": text])
            }
        case .count:
            if let out = model.run("count.add", ["x": Double(end.x), "y": Double(end.y)]) as? [String: Any],
               let groups = out["groups"] as? [[String: Any]] {
                model.countMarks = groups.flatMap { ($0["points"] as? [[NSNumber]] ?? []).map { Point(x: $0[0].floatValue, y: $0[1].floatValue) } }
                model.toast = "Count: \(out["total"] ?? model.countMarks.count)"
                updatePending()
            }
        case .patch, .contentAwareMove:
            setToolPath(nil)
            guard !tapped else { return }
            let cmd = model.tool == .patch ? "paint.patch" : "paint.contentAwareMove"
            let p = json(["offset": [Int((end.x - startDoc.x).rounded()), Int((end.y - startDoc.y).rounded())]])
            model.whileBusy { editor in _ = try editor.execute(id: cmd, params: p) }
        case .redEye:
            model.run("paint.redEye", ["x": Int(end.x), "y": Int(end.y)])
        case .magicEraser:
            model.run("paint.magicEraser", ["x": Int(end.x), "y": Int(end.y), "tolerance": model.tolerance, "contiguous": model.contiguous, "sampleAllLayers": model.sampleAllLayers])
        case .paintBucket:
            model.run("paint.bucket", ["x": Int(end.x), "y": Int(end.y), "tolerance": model.tolerance, "contiguous": model.contiguous, "sampleAllLayers": model.sampleAllLayers])
        case .gradient:
            setToolPath(nil)
            if !tapped {
                model.run("paint.gradient", ["from": dp(startDoc), "to": dp(end), "style": model.gradientStyle.rawValue,
                                             "gradient": model.gradientPreset, "reverse": model.gradientReverse])
            }
        case .rectangle, .ellipseShape, .triangle, .polygon, .customShape:
            setToolPath(nil)
            guard let r = rect else { return }
            let fill = model.foreground.hex
            switch model.tool {
            case .rectangle: model.run("shape.create", ["kind": "rect", "rect": r, "fill": fill])
            case .ellipseShape: model.run("shape.create", ["kind": "ellipse", "rect": r, "fill": fill])
            case .triangle: model.run("shape.create", ["kind": "polygon", "sides": 3, "rect": r, "fill": fill])
            case .polygon: model.run("shape.create", ["kind": "polygon", "sides": model.polygonSides, "rect": r, "fill": fill])
            default:
                if let preset = model.firstShapePreset { model.run("shape.presets.place", ["preset": preset, "rect": r, "fill": fill]) }
            }
        case .line:
            setToolPath(nil)
            if !tapped {
                let weight = max(2, Double(4 * scale) / Double(model.view.zoom))
                model.run("shape.create", ["kind": "line", "from": dp(startDoc), "to": dp(end), "weight": weight.rounded(), "fill": model.foreground.hex])
            }
        case .type, .verticalType, .typeMask, .verticalTypeMask:
            setToolPath(nil)
            typeEnded(at: end, box: tapped ? nil : rect)
        case .zoomOut:
            // ⌥ flips it, as in Photoshop.
            model.zoom(by: altDown ? 2 : 0.5, at: pixels(t.point))
        case .zoomIn where model.scrubbyZoom && !tapped:
            break
        case .zoomIn:
            setToolPath(nil)
            if altDown {
                model.zoom(by: 0.5, at: pixels(t.point))
            } else if let r = rect, !tapped, r[2] > 0, r[3] > 0 {
                // Zoom to the dragged area.
                let z = min(Float(model.view.width) / Float(r[2]), Float(model.view.height) / Float(r[3]))
                model.view.zoom = min(z, 64)
                model.view.centerX = Float(r[0]) + Float(r[2]) / 2
                model.view.centerY = Float(r[1]) + Float(r[3]) / 2
                model.needsDraw = true
                model.overlayDirty = true
            } else {
                model.zoom(by: 2, at: pixels(t.point))
            }
        case .move:
            applyMove(to: end, force: true, time: t.time)
            model.smartGuides = []
        case .freeformPen:
            setToolPath(nil)
            let pts = thinned(docPoints, every: 8)
            if pts.count >= 2 { model.setWorkPath(model.workPath + [Subpath(knots: smooth(pts), closed: false)]) }
        case .pen:
            penEnded()
        case .addAnchor:
            if let (s, k) = segmentAt(end) { pathEdit("path.addAnchor", ["subpath": s, "knot": k]) }
        case .deleteAnchor:
            if let (s, k) = anchorAt(end) { pathEdit("path.deleteAnchor", ["subpath": s, "knot": k]) }
        case .convertPoint:
            if let (s, k) = anchorAt(end) {
                let knot = model.workPath[s].knots[k]
                let corner = knot.inHandle == knot.anchor && knot.outHandle == knot.anchor
                // A corner becomes smooth with handles along the neighbours; a smooth point a corner.
                var p: [String: Any] = ["subpath": s, "knot": k]
                if corner { p["out"] = dp(smoothHandle(s, k)) }
                pathEdit("path.convertPoint", p)
            }
        case .directSelect, .pathSelect:
            // Write the dragged path back as one step.
            if gesture.moved { model.setWorkPath(model.workPath) }
            toolDrag = .none
        default:
            break
        }
    }

    func toolCancelled() {
        hold?.cancel()
        if objectHold { model.clearObjectHighlight() }
        objectHold = false
        if stroking {
            model.editor.strokeCancel()
            stroking = false
            pending.removeAll()
            model.needsDraw = true
        }
        setToolPath(nil)
        hideLoupe()
        toolTouch = nil
        toolDrag = .none
    }

    /// Move the layer so the document point under the finger follows it (whole pixels, at most
    /// 30 times a second; every step joins one undo step).
    func applyMove(to p: Point, force: Bool, time: TimeInterval) {
        guard force || time - lastMove > 1.0 / 30 else { return }
        var (dx, dy) = (p.x - startDoc.x, p.y - startDoc.y)
        // ⇧ keeps to one direction.
        if moveShift {
            if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 }
        }
        (dx, dy) = snapped(dx, dy)
        let target = (x: Int(dx.rounded()), y: Int(dy.rounded()))
        let step = (x: target.x - moveApplied.x, y: target.y - moveApplied.y)
        guard step.x != 0 || step.y != 0 else { return }
        lastMove = time
        if moveCopy {
            moveCopy = false
            model.run("layer.duplicate")
        }
        var p: [String: Any] = ["dx": step.x, "dy": step.y, "coalesce": moveKey]
        // An unlinked mask moves alone.
        if model.maskTarget { p["target"] = "mask" }
        if model.run("layer.translate", p) != nil {
            moveApplied = target
        }
    }

    /// What the moving layer can snap to: the canvas's edges and centre only (not other layers).
    func prepareSnap() {
        (moveBox, snapX, snapY) = (nil, [], [])
        guard model.snap, let a = model.activeLayer, let b = a.bounds, b.count == 4, let d = model.doc else { return }
        moveBox = b.map(Float.init)
        snapX = [0, Float(d.width) / 2, Float(d.width)]
        snapY = [0, Float(d.height) / 2, Float(d.height)]
    }

    /// `(dx, dy)` moved onto the nearest snap within a few screen points, with its smart guides.
    func snapped(_ dx: Float, _ dy: Float) -> (Float, Float) {
        guard let b = moveBox else { return (dx, dy) }
        let reach = 8 * Float(scale) / max(model.view.zoom, 0.01)
        func best(_ edges: [Float], _ targets: [Float]) -> Float? {
            var out: (gap: Float, move: Float)?
            for e in edges {
                for t in targets where abs(t - e) <= reach && abs(t - e) < (out?.gap ?? .infinity) { out = (abs(t - e), t - e) }
            }
            return out?.move
        }
        let xs = [b[0], b[0] + b[2] / 2, b[0] + b[2]].map { $0 + dx }
        let ys = [b[1], b[1] + b[3] / 2, b[1] + b[3]].map { $0 + dy }
        let sx = moveShift && dx == 0 ? nil : best(xs, snapX)
        let sy = moveShift && dy == 0 ? nil : best(ys, snapY)
        let (nx, ny) = (dx + (sx ?? 0), dy + (sy ?? 0))
        var guides: [(Point, Point)] = []
        let (w, h) = (Float(model.doc?.width ?? 0), Float(model.doc?.height ?? 0))
        if sx != nil {
            for x in [b[0], b[0] + b[2] / 2, b[0] + b[2]].map({ $0 + nx }) where snapX.contains(where: { abs($0 - x) < 0.5 }) {
                guides.append((Point(x: x, y: 0), Point(x: x, y: h)))
            }
        }
        if sy != nil {
            for y in [b[1], b[1] + b[3] / 2, b[1] + b[3]].map({ $0 + ny }) where snapY.contains(where: { abs($0 - y) < 0.5 }) {
                guides.append((Point(x: 0, y: y), Point(x: w, y: y)))
            }
        }
        model.smartGuides = guides
        return (nx, ny)
    }

    // MARK: - Helpers

    /// `[x, y, w, h]` of the rectangle from `a` to `b`, or `nil` when it is under a pixel.
    func rectParams(_ a: Point, _ b: Point) -> [Int]? {
        let (x0, y0, x1, y1) = (min(a.x, b.x), min(a.y, b.y), max(a.x, b.x), max(a.y, b.y))
        guard x1 - x0 >= 1, y1 - y0 >= 1 else { return nil }
        return [Int(x0.rounded()), Int(y0.rounded()), Int((x1 - x0).rounded()), Int((y1 - y0).rounded())]
    }

    func inside(_ p: Point, _ a: Point, _ b: Point) -> Bool {
        p.x >= min(a.x, b.x) && p.x <= max(a.x, b.x) && p.y >= min(a.y, b.y) && p.y <= max(a.y, b.y)
    }

    /// Every point at least `every` screen points from the last kept one (and the last point).
    func thinned(_ pts: [Point], every: CGFloat) -> [Point] {
        var out: [Point] = []
        for p in pts where out.last.map({ screenDistance($0, p) >= every }) ?? true { out.append(p) }
        if let l = pts.last, out.last != l { out.append(l) }
        return out
    }

    /// Smooth knots through `pts` (Catmull-Rom handles).
    func smooth(_ pts: [Point]) -> [Knot] {
        pts.indices.map { i in
            let prev = pts[max(i - 1, 0)], next = pts[min(i + 1, pts.count - 1)]
            let (tx, ty) = ((next.x - prev.x) / 6, (next.y - prev.y) / 6)
            let a = pts[i]
            return Knot(anchor: a, in: Point(x: a.x - tx, y: a.y - ty), out: Point(x: a.x + tx, y: a.y + ty))
        }
    }

    // MARK: - Precision

    /// The part of the marquee box under `p`: a handle within reach (less on a small box, to
    /// leave room inside), else inside.
    func boxPart(_ box: MarqueeBox, at p: Point) -> BoxPart? {
        let hs = box.handles
        let corners = hs.prefix(4).map { toScreen($0.1) }
        let side = min(hypot(corners[0].x - corners[1].x, corners[0].y - corners[1].y), hypot(corners[1].x - corners[2].x, corners[1].y - corners[2].y))
        let reach = max(12, min(24, side / 3))
        if let i = Reach.nearest(hs.map { toScreen($0.1) }, to: toScreen(p), within: reach) { return hs[i].0 }
        return box.contains(p) ? .inside : nil
    }

    /// Polygonal Lasso and Perspective Crop: where the next point goes, joined to the last one.
    func showCandidate(_ p: Point) {
        let path = CGMutablePath()
        if let last = model.quad.last { path.addPath(polyline([last, p], closed: false)) }
        let c = toScreen(p)
        path.addEllipse(in: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10))
        setToolPath(path)
    }

    /// The tool is placing an exact point now, so the loupe shows.
    var loupeWanted: Bool {
        if model.canvasPick != nil { return model.doc != nil }
        guard model.puppet == nil, model.transform == nil, model.targetedAdjust == nil, model.sheetDrag == nil, model.doc != nil else { return false }
        switch model.tool {
        case .marquee, .ellipse:
            if case let .marqueeBox(part, _) = toolDrag { return part != .inside }
            return true
        case .crop:
            if case .moveCrop = toolDrag { return false }
            return true
        case .directSelect:
            switch toolDrag {
            case .anchor, .handle: return true
            default: return false
            }
        case .singleRow, .singleColumn, .polygonLasso, .perspectiveCrop, .eyedropper, .colorSampler, .ruler, .gradient, .pen:
            return true
        default:
            return false
        }
    }

    /// Show the loupe at the finger, fetching the pixels only when it moves to another one.
    func updateLoupe(_ t: ToolTouch) {
        guard t.direct, loupeWanted, let d = model.doc else { return hideLoupe() }
        let at = toDoc(t.location)
        let px = Loupe.pixel(at)
        if loupeShown?.x != px.x || loupeShown?.y != px.y || loupeShown?.revision != d.revision {
            loupeShown = (px.x, px.y, d.revision)
            loupeFetches += 1
            let half = Loupe.side / 2
            let (x, y) = (Int32(clamping: px.x - half), Int32(clamping: px.y - half))
            let n = UInt32(Loupe.side)
            let image = (try? model.editor.renderRegion(x: x, y: y, w: n, h: n)).flatMap { Loupe.image($0, width: Loupe.side, height: Loupe.side) }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            loupe.pixels.contents = image
            CATransaction.commit()
            loupe.label.text = "\(px.x), \(px.y)"
        }
        loupe.frame = Loupe.frame(finger: t.location, in: bounds)
        loupe.isHidden = false
        // A new touch: a lingering hide no longer applies.
        loupeHides += 1
    }

    /// `linger`: a finger just lifted, so the loupe stays a moment to show where the point went.
    func hideLoupe(linger: Bool = false) {
        loupeHides += 1
        guard linger, !loupe.isHidden else {
            loupe.isHidden = true
            loupeShown = nil
            return
        }
        let n = loupeHides
        DispatchQueue.main.asyncAfter(deadline: .now() + Loupe.linger) { [weak self] in
            guard let self, self.loupeHides == n else { return }
            self.loupe.isHidden = true
            self.loupeShown = nil
        }
    }

    // MARK: - Type

    func typeEnded(at p: Point, box: [Int]?) {
        let vertical = model.tool == .verticalType || model.tool == .verticalTypeMask
        let mask = model.tool == .typeMask || model.tool == .verticalTypeMask
        // Tap on existing type (Type tools only): edit its text.
        if box == nil, !mask, let hit = try? model.editor.execute(id: "type.hitTest", params: json(["x": Double(p.x), "y": Double(p.y)])),
           let h = try? JSONSerialization.jsonObject(with: Data(hit.utf8)) as? [String: Any], let layer = h["layer"] as? NSNumber,
           let info = try? model.editor.execute(id: "type.info", params: json(["layer": layer])),
           let i = try? JSONSerialization.jsonObject(with: Data(info.utf8)) as? [String: Any] {
            model.prompt = TextPrompt(title: "Edit Text", text: i["text"] as? String ?? "") { [weak self] text in
                self?.model.run("type.edit", ["layer": layer, "text": text])
            }
            return
        }
        let size = model.defaultTypeSize
        model.prompt = TextPrompt(title: mask ? "Type Mask" : "Text", text: "") { [weak self] text in
            guard let self, !text.isEmpty else { return }
            var params: [String: Any] = ["text": text, "size": self.model.typeSize > 0 ? self.model.typeSize : size, "color": self.model.foreground.hex,
                                         "orientation": vertical ? "vertical" : "horizontal", "align": self.model.typeAlign]
            if !self.model.typeFont.isEmpty { params["font"] = self.model.typeFont }
            if self.model.typeTracking != 0 { params["tracking"] = self.model.typeTracking }
            if self.model.typeLeading > 0 { params["leading"] = self.model.typeLeading }
            if let b = box {
                params["box"] = b
                (params["x"], params["y"]) = (b[0], b[1])
            } else {
                (params["x"], params["y"]) = (Double(p.x), Double(p.y))
            }
            guard let out = self.model.run("type.create", params) as? [String: Any], let layer = out["layer"] else { return }
            if mask { self.model.run("type.createSelection", ["layer": layer, "removeLayer": true]) }
        }
    }

    // MARK: - Pen tools

    func penBegan(at p: Point) {
        var path = model.workPath
        // Touching the first anchor of the open subpath closes it.
        if let s = path.indices.last, !path[s].closed, let first = path[s].knots.first, path[s].knots.count >= 2, screenDistance(first.anchor, p) < Reach.point {
            path[s].closed = true
            model.setWorkPath(path)
            penClosed = true
            return
        }
        penClosed = false
        if path.last.map({ $0.closed }) ?? true { path.append(Subpath(knots: [], closed: false)) }
        path[path.count - 1].knots.append(Knot(p))
        model.workPath = path
    }

    /// Dragging from a new anchor pulls out its handles (a smooth point).
    func penDragged(to p: Point) {
        guard !penClosed, var sp = model.workPath.last, let k = sp.knots.indices.last else { return }
        let a = sp.knots[k].anchor
        sp.knots[k] = Knot(anchor: a, in: Point(x: 2 * a.x - p.x, y: 2 * a.y - p.y), out: p)
        var path = model.workPath
        path[path.count - 1] = sp
        model.workPath = path
    }

    func penEnded() {
        if !penClosed { model.setWorkPath(model.workPath) }
    }

    /// Curvature Pen: each tap adds a point and the curve runs smoothly through them all.
    func curvatureTap(at p: Point) {
        var path = model.workPath
        if path.last.map({ $0.closed }) ?? true { path.append(Subpath(knots: [], closed: false)) }
        var anchors = path[path.count - 1].knots.map(\.anchor)
        anchors.append(p)
        path[path.count - 1].knots = smooth(anchors)
        model.setWorkPath(path)
    }

    /// The anchor nearest `p` within reach, as (subpath, knot).
    func anchorAt(_ p: Point) -> (Int, Int)? {
        let all = model.workPath.enumerated().flatMap { s, sp in sp.knots.indices.map { (s, $0) } }
        let pts = all.map { toScreen(model.workPath[$0.0].knots[$0.1].anchor) }
        return Reach.nearest(pts, to: toScreen(p)).map { all[$0] }
    }

    /// Direct Selection: the anchor or shown handle nearest `p`.
    func pathHandleAt(_ p: Point) -> ToolDrag? {
        var all: [(ToolDrag, Point)] = []
        for (s, sp) in model.workPath.enumerated() {
            for (k, knot) in sp.knots.enumerated() {
                all.append((.anchor(s, k), knot.anchor))
                if knot.outHandle != knot.anchor || knot.inHandle != knot.anchor {
                    all.append((.handle(s, k, out: true), knot.outHandle))
                    all.append((.handle(s, k, out: false), knot.inHandle))
                }
            }
        }
        return Reach.nearest(all.map { toScreen($0.1) }, to: toScreen(p)).map { all[$0].0 }
    }

    /// Direct Selection: move the anchor (with its handles) or one handle; the other handle of a
    /// smooth point turns to stay opposite.
    func dragPathHandle(to here: Point) {
        var path = model.workPath
        switch toolDrag {
        case let .anchor(s, k):
            guard path.indices.contains(s), path[s].knots.indices.contains(k) else { return }
            let d = (here.x - startDoc.x, here.y - startDoc.y)
            let knot = path[s].knots[k]
            let shift = { (q: Point) in Point(x: q.x + d.0, y: q.y + d.1) }
            path[s].knots[k] = Knot(anchor: shift(knot.anchor), in: shift(knot.inHandle), out: shift(knot.outHandle))
            startDoc = here
        case let .handle(s, k, out):
            guard path.indices.contains(s), path[s].knots.indices.contains(k) else { return }
            let knot = path[s].knots[k]
            let a = knot.anchor
            let other = out ? knot.inHandle : knot.outHandle
            let moved = out ? knot.outHandle : knot.inHandle
            let len = hypot(other.x - a.x, other.y - a.y)
            // Smooth: the two handles point opposite ways.
            let (u, v) = ((moved.x - a.x, moved.y - a.y), (other.x - a.x, other.y - a.y))
            let smooth = len > 0 && abs(u.0 * v.1 - u.1 * v.0) <= 0.01 * hypot(u.0, u.1) * len && u.0 * v.0 + u.1 * v.1 < 0
            var opposite = other
            let (dx, dy) = (here.x - a.x, here.y - a.y)
            if smooth, hypot(dx, dy) > 0 {
                let n = hypot(dx, dy)
                opposite = Point(x: a.x - dx / n * len, y: a.y - dy / n * len)
            }
            path[s].knots[k] = out ? Knot(anchor: a, in: opposite, out: here) : Knot(anchor: a, in: here, out: opposite)
        default:
            return
        }
        model.workPath = path
    }

    /// The segment nearest `p` (by its midpoint), as the knot it leaves.
    func segmentAt(_ p: Point) -> (Int, Int)? {
        var best: ((Int, Int), CGFloat)?
        for (s, sp) in model.workPath.enumerated() {
            let n = sp.knots.count
            for k in 0..<(sp.closed ? n : max(n - 1, 0)) {
                let (a, b) = (sp.knots[k], sp.knots[(k + 1) % n])
                // The cubic's midpoint.
                let x = (a.anchor.x + 3 * a.outHandle.x + 3 * b.inHandle.x + b.anchor.x) / 8
                let y = (a.anchor.y + 3 * a.outHandle.y + 3 * b.inHandle.y + b.anchor.y) / 8
                let d = screenDistance(Point(x: x, y: y), p)
                if d < 30, d < (best?.1 ?? .infinity) { best = ((s, k), d) }
            }
        }
        return best?.0
    }

    /// An out handle for knot `k` along the line between its neighbours.
    func smoothHandle(_ s: Int, _ k: Int) -> Point {
        let knots = model.workPath[s].knots
        let prev = knots[max(k - 1, 0)].anchor, next = knots[min(k + 1, knots.count - 1)].anchor
        let a = knots[k].anchor
        return Point(x: a.x + (next.x - prev.x) / 6, y: a.y + (next.y - prev.y) / 6)
    }

    func pathEdit(_ cmd: String, _ params: [String: Any]) {
        var p = params
        p["name"] = "work"
        model.run(cmd, p)
        model.loadWorkPath()
    }

    // MARK: - Free Transform

    /// The rotate handle: a knob on a stem out from the middle of the box's top edge, in screen
    /// points (`base` on the edge, `knob` at the end).
    func rotateHandle(_ box: TransformBox) -> (base: CGPoint, knob: CGPoint) {
        let top = toScreen(box.map(Point(x: (box.x0 + box.x1) / 2, y: box.y0)))
        let mid = toScreen(box.map(box.center))
        let (vx, vy) = (top.x - mid.x, top.y - mid.y)
        let len = max(hypot(vx, vy), 0.001)
        return (top, CGPoint(x: top.x + vx / len * 36, y: top.y + vy / len * 36))
    }

    func transformDrag(_ box: TransformBox, at p: Point) -> ToolDrag {
        let quad = box.quad
        let knob = rotateHandle(box).knob
        let at = toScreen(p)
        if hypot(at.x - knob.x, at.y - knob.y) < 22 {
            let c = box.map(box.origin)
            return .rotate(box, atan2(p.y - c.y, p.x - c.x))
        }
        // A small box keeps room inside it for moving.
        let side = min(screenDistance(quad[0], quad[1]), screenDistance(quad[1], quad[2]))
        let reach = max(16, min(36, side / 3))
        if let i = quad.indices.min(by: { screenDistance(quad[$0], p) < screenDistance(quad[$1], p) }), screenDistance(quad[i], p) < reach {
            return .corner(i, box)
        }
        // The reference point drags on its own.
        if screenDistance(box.map(box.origin), p) < 16 { return .pivot(box) }
        // Inside the box moves it; outside turns it.
        if inside(p, quad: quad) { return .moveBox(box) }
        let c = box.map(box.origin)
        return .rotate(box, atan2(p.y - c.y, p.x - c.x))
    }

    /// Whether `p` is inside the quadrilateral `q` (convex, either winding).
    func inside(_ p: Point, quad q: [Point]) -> Bool {
        var sign: Float = 0
        for i in q.indices {
            let (a, b) = (q[i], q[(i + 1) % q.count])
            let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            if cross != 0 {
                if sign == 0 { sign = cross } else if (cross > 0) != (sign > 0) { return false }
            }
        }
        return true
    }

    func transformMoved(to p: Point, shift: Bool, alt: Bool = false) {
        switch toolDrag {
        case let .moveBox(b):
            var n = b
            (n.dx, n.dy) = (b.dx + p.x - startDoc.x, b.dy + p.y - startDoc.y)
            model.transform = n
        case let .pivot(b):
            // Back to the source frame: undo the move, turn and scale.
            let c = b.map(b.origin)
            let (cs, sn) = (cos(-b.angle), sin(-b.angle))
            let (vx, vy) = (p.x - c.x, p.y - c.y)
            let (lx, ly) = (vx * cs - vy * sn, vx * sn + vy * cs)
            guard b.sx != 0, b.sy != 0 else { return }
            var n = b
            n.setPivot(Point(x: b.origin.x + lx / b.sx, y: b.origin.y + ly / b.sy))
            model.transform = n
        case let .rotate(b, a0):
            let c = b.map(b.origin)
            var n = b
            n.angle = b.angle + atan2(p.y - c.y, p.x - c.x) - a0
            // ⇧ turns in 15° steps.
            if shift != model.snapRotation { n.angle = (n.angle / (.pi / 12)).rounded() * (.pi / 12) }
            model.transform = n
        case let .corner(i, b):
            // The opposite corner stays put, or the reference point with Scale From Reference.
            let ci = b.corners[i]
            let fixed = model.scaleFromPivot != alt ? b.origin : b.corners[(i + 2) % 4]
            let pf = b.map(fixed)
            let (cs, sn) = (cos(-b.angle), sin(-b.angle))
            let (vx, vy) = (p.x - pf.x, p.y - pf.y)
            let (lx, ly) = (vx * cs - vy * sn, vx * sn + vy * cs)
            // Keep Proportions (⇧ swaps it for this drag).
            guard let scale = TransformBox.cornerScale(local: (lx, ly), corner: (ci.x - fixed.x, ci.y - fixed.y),
                                                       current: (b.sx, b.sy), keep: model.keepProportions != shift) else { return }
            var n = b
            (n.sx, n.sy) = scale
            (n.dx, n.dy) = (0, 0)
            let moved = n.map(fixed)
            (n.dx, n.dy) = (pf.x - moved.x, pf.y - moved.y)
            model.transform = n
        default:
            break
        }
    }

    // MARK: - Slices

    func showSlices(at p: Point? = nil) {
        guard let out = try? model.editor.execute(id: "slice.list", params: "{}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let slices = obj["slices"] as? [[String: Any]]
        else { return }
        // The automatic slices that fill the rest are not drawn.
        sliceRects = slices.filter { $0["origin"] as? String == "user" }.compactMap { ($0["rect"] as? [NSNumber])?.map(\.floatValue) }
        if let p, let hit = slices.first(where: { s in
            guard let r = (s["rect"] as? [NSNumber])?.map(\.floatValue) else { return false }
            return p.x >= r[0] && p.x < r[0] + r[2] && p.y >= r[1] && p.y < r[1] + r[3] && s["origin"] as? String == "user"
        }) {
            model.toast = "\(hit["name"] ?? "Slice") \(hit["number"] ?? "")"
        }
        updatePending()
    }

    // MARK: - Pending overlays

    /// The brush's width on screen.
    var brushWidth: CGFloat { CGFloat(model.brushSize) * CGFloat(model.view.zoom) / scale }

    func strokesPath(_ strokes: [[Point]]) -> CGPath {
        let path = CGMutablePath()
        for s in strokes {
            path.addPath(polyline(s.count == 1 ? [s[0], s[0]] : s, closed: false))
        }
        return path
    }

    /// Crop box, perspective quad, polygon, Free Transform box, ruler, work path, samplers and
    /// counts: what the canvas shows for work in progress.
    func updatePending() {
        if [.remove, .aiRemove].contains(model.tool), !stroking {
            setToolPath(model.removeStrokes.isEmpty ? nil : strokesPath(model.removeStrokes), width: brushWidth, dashed: false)
        }
        let lines = CGMutablePath()
        let dots = CGMutablePath()
        let dot = { (p: CGPoint, r: CGFloat) in dots.addRect(CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)) }
        var cut: [Point]?
        if let (a, b) = model.cropRect {
            // Turned by the straighten angle about its centre.
            let (cx, cy) = ((a.x + b.x) / 2, (a.y + b.y) / 2)
            let (sn, cs) = (Float(sin(model.cropAngle * .pi / 180)), Float(cos(model.cropAngle * .pi / 180)))
            let turn = { (p: Point) in Point(x: cx + cs * (p.x - cx) - sn * (p.y - cy), y: cy + sn * (p.x - cx) + cs * (p.y - cy)) }
            let corners = [a, Point(x: b.x, y: a.y), b, Point(x: a.x, y: b.y)].map(turn)
            cut = corners
            lines.addPath(polyline(corners, closed: true))
            // Rule of thirds.
            for f: Float in [1 / 3, 2 / 3] {
                let x = a.x + (b.x - a.x) * f, y = a.y + (b.y - a.y) * f
                lines.addPath(polyline([Point(x: x, y: a.y), Point(x: x, y: b.y)].map(turn), closed: false))
                lines.addPath(polyline([Point(x: a.x, y: y), Point(x: b.x, y: y)].map(turn), closed: false))
            }
            corners.forEach { dot(toScreen($0), 4) }
        }
        if model.tool == .perspectiveCrop, model.quad.count == 4 { cut = clockwiseFromTopLeft(model.quad) }
        if !model.quad.isEmpty {
            lines.addPath(polyline(model.quad, closed: model.tool == .perspectiveCrop && model.quad.count == 4))
            model.quad.forEach { dot(toScreen($0), 4) }
        }
        if let t = model.transform {
            lines.addPath(polyline(t.quad, closed: true))
            t.quad.forEach { dot(toScreen($0), 8) }
            let (base, knob) = rotateHandle(t)
            lines.move(to: base)
            lines.addLine(to: knob)
            lines.addEllipse(in: CGRect(x: knob.x - 9, y: knob.y - 9, width: 18, height: 18))
            // The reference point: a circle with a cross.
            let r = toScreen(t.map(t.origin))
            lines.addEllipse(in: CGRect(x: r.x - 7, y: r.y - 7, width: 14, height: 14))
            dot(r, 2)
        }
        if let p = model.puppet {
            if p.showMesh {
                let m = model.puppetMesh
                var i = 0
                while i + 3 < m.count {
                    lines.move(to: toScreen(Point(x: m[i], y: m[i + 1])))
                    lines.addLine(to: toScreen(Point(x: m[i + 2], y: m[i + 3])))
                    i += 4
                }
            }
            for (i, pin) in p.pins.enumerated() { dot(toScreen(pin.dst), i == p.selected ? 8 : 5) }
        }
        if let (a, b) = model.ruler, model.tool == .ruler {
            lines.addPath(polyline([a, b], closed: false))
            [a, b].forEach { dot(toScreen($0), 4.5) }
        }
        if model.tool.pathTool || model.tool.shapeTool {
            for sp in model.workPath where !sp.knots.isEmpty {
                let path = CGMutablePath()
                path.move(to: toScreen(sp.knots[0].anchor))
                let n = sp.knots.count
                for k in 0..<(sp.closed ? n : n - 1) {
                    let (a, b) = (sp.knots[k], sp.knots[(k + 1) % n])
                    path.addCurve(to: toScreen(b.anchor), control1: toScreen(a.outHandle), control2: toScreen(b.inHandle))
                }
                if sp.closed { path.closeSubpath() }
                lines.addPath(path)
                for k in sp.knots {
                    dot(toScreen(k.anchor), 4.5)
                    if k.outHandle != k.anchor || k.inHandle != k.anchor {
                        lines.addPath(polyline([k.inHandle, k.anchor, k.outHandle], closed: false))
                        dot(toScreen(k.outHandle), 3.5)
                        dot(toScreen(k.inHandle), 3.5)
                    }
                }
            }
        }
        if model.tool == .colorSampler || model.tool == .eyedropper {
            for s in model.samplers {
                let p = toScreen(s)
                lines.move(to: CGPoint(x: p.x - 8, y: p.y)); lines.addLine(to: CGPoint(x: p.x + 8, y: p.y))
                lines.move(to: CGPoint(x: p.x, y: p.y - 8)); lines.addLine(to: CGPoint(x: p.x, y: p.y + 8))
            }
        }
        if model.tool == .count { model.countMarks.forEach { dot(toScreen($0), 4) } }
        if let box = model.marqueeBox, model.tool == .marquee || model.tool == .ellipse {
            let c = box.handles.prefix(4).map(\.1)
            lines.addPath(polyline(Array(c), closed: true))
            box.handles.forEach { dot(toScreen($0.1), 5) }
        }
        if model.tool == .slice || model.tool == .sliceSelect {
            for r in sliceRects where r.count == 4 {
                lines.addPath(polyline([Point(x: r[0], y: r[1]), Point(x: r[0] + r[2], y: r[1]), Point(x: r[0] + r[2], y: r[1] + r[3]), Point(x: r[0], y: r[1] + r[3])], closed: true))
            }
        }
        var dim: CGMutablePath?
        if let cut {
            dim = CGMutablePath()
            dim?.addRect(bounds)
            dim?.addPath(polyline(cut, closed: true))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pendingLines.path = lines
        let guides = CGMutablePath()
        for (a, b) in model.smartGuides {
            guides.move(to: toScreen(a))
            guides.addLine(to: toScreen(b))
        }
        guideLines.path = guides
        pendingDots.path = dots
        shade.path = dim
        CATransaction.commit()
    }
}

/// What a tool drag is doing.
enum ToolDrag {
    case none
    case moveCrop(Point, Point)
    /// A crop corner or edge: the corner that stays, which sides move, and where the other end of
    /// a dragged edge is.
    case cropEdge(Point, x: Bool, y: Bool, other: Float? = nil)
    /// Crop › Straighten: a line along what should be level.
    case straighten
    case anchor(Int, Int)
    /// A path handle: subpath, knot, the out handle (or the in handle).
    case handle(Int, Int, out: Bool)
    /// The marquee box: the part dragged and the box when the drag began.
    case marqueeBox(BoxPart, MarqueeBox)
    /// A Polygonal Lasso or Perspective Crop point.
    case quadPoint(Int)
    /// A ruler end (0 the start, 1 the end).
    case rulerEnd(Int)
    /// A colour sampler and where it was.
    case sampler(Int, Point)
    case moveBox(TransformBox)
    case rotate(TransformBox, Float)
    case pivot(TransformBox)
    case corner(Int, TransformBox)
    /// A Puppet Warp pin.
    case pin(Int)
}
