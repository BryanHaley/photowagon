import UIKit

/// How close (screen points) a finger has to be to grab a point, handle or pin.
enum Reach {
    static let point: CGFloat = 22

    /// The index of the point nearest `p` within `reach`.
    static func nearest(_ pts: [CGPoint], to p: CGPoint, within reach: CGFloat = point) -> Int? {
        let d = { (i: Int) in hypot(pts[i].x - p.x, pts[i].y - p.y) }
        guard let i = pts.indices.min(by: { d($0) < d($1) }), d(i) < reach else { return nil }
        return i
    }
}

/// The magnifier above the finger for tools that place exact points.
enum Loupe {
    static let size: CGFloat = 170
    /// Document pixels across.
    static let side = 35
    /// Seconds it stays after the finger lifts, to show where the point went.
    static let linger: TimeInterval = 0.45

    /// The loupe's frame: above and left of the finger, flipped to stay inside `bounds`.
    static func frame(finger p: CGPoint, in bounds: CGRect) -> CGRect {
        let (dx, dy, margin): (CGFloat, CGFloat, CGFloat) = (20, 40, 8)
        var x = p.x - size - dx, y = p.y - size - dy
        if x < bounds.minX + margin { x = p.x + dx }
        if y < bounds.minY + margin { y = p.y + dy }
        x = min(max(x, bounds.minX + margin), max(bounds.maxX - size - margin, bounds.minX + margin))
        y = min(max(y, bounds.minY + margin), max(bounds.maxY - size - margin, bounds.minY + margin))
        return CGRect(x: x, y: y, width: size, height: size)
    }

    /// The pixel under document point `p`.
    static func pixel(_ p: Point) -> (x: Int, y: Int) {
        let clamp = { (v: Float) in Int(max(min(v.rounded(.down), 1e9), -1e9)) }
        return (clamp(p.x), clamp(p.y))
    }

    /// RGBA8 rows (straight alpha), `w`×`h`, as an image.
    static func image(_ data: Data, width w: Int, height h: Int) -> CGImage? {
        guard w > 0, h > 0, data.count == w * h * 4, let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// The round magnifier: document pixels, nearest-neighbour, a crosshair and the coordinates.
final class LoupeView: UIView {
    let pixels = CALayer()
    let cross = CAShapeLayer()
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        backgroundColor = UIColor(white: 0.25, alpha: 1)
        layer.cornerRadius = Loupe.size / 2
        layer.masksToBounds = true
        layer.borderWidth = 2
        layer.borderColor = UIColor.white.cgColor
        pixels.magnificationFilter = .nearest
        layer.addSublayer(pixels)
        cross.fillColor = nil
        cross.strokeColor = UIColor.systemPink.cgColor
        cross.lineWidth = 1.5
        layer.addSublayer(cross)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pixels.frame = bounds
        // A box round the middle pixel.
        let cell = bounds.width / CGFloat(Loupe.side)
        let c = CGRect(x: bounds.midX - cell / 2, y: bounds.midY - cell / 2, width: cell, height: cell)
        let path = CGMutablePath()
        path.addRect(c)
        path.move(to: CGPoint(x: c.midX, y: bounds.minY + 12)); path.addLine(to: CGPoint(x: c.midX, y: c.minY))
        path.move(to: CGPoint(x: c.midX, y: c.maxY)); path.addLine(to: CGPoint(x: c.midX, y: bounds.maxY - 22))
        path.move(to: CGPoint(x: bounds.minX + 12, y: c.midY)); path.addLine(to: CGPoint(x: c.minX, y: c.midY))
        path.move(to: CGPoint(x: c.maxX, y: c.midY)); path.addLine(to: CGPoint(x: bounds.maxX - 12, y: c.midY))
        cross.path = path
        cross.frame = bounds
        CATransaction.commit()
        label.frame = CGRect(x: 0, y: bounds.maxY - 22, width: bounds.width, height: 22)
    }
}

/// Which part of an adjustable box a finger took.
enum BoxPart: Equatable {
    /// Top left, top right, bottom right, bottom left.
    case corner(Int)
    /// Top, right, bottom, left.
    case edge(Int)
    case inside
}

/// The Rectangular or Elliptical Marquee's box after a drag: its handles adjust the selection.
struct MarqueeBox: Equatable {
    var x: Int, y: Int, w: Int, h: Int
    var ellipse = false
    var mode = "replace"
    /// The document and revision the box's selection step made.
    var doc: UInt64 = 0
    var revision: UInt64 = 0

    var rect: [Int] { [x, y, w, h] }

    /// Every handle and where it is, document pixels.
    var handles: [(BoxPart, Point)] {
        let (x0, y0, x1, y1) = (Float(x), Float(y), Float(x + w), Float(y + h))
        let (mx, my) = ((x0 + x1) / 2, (y0 + y1) / 2)
        return [(.corner(0), Point(x: x0, y: y0)), (.corner(1), Point(x: x1, y: y0)), (.corner(2), Point(x: x1, y: y1)), (.corner(3), Point(x: x0, y: y1)),
                (.edge(0), Point(x: mx, y: y0)), (.edge(1), Point(x: x1, y: my)), (.edge(2), Point(x: mx, y: y1)), (.edge(3), Point(x: x0, y: my))]
    }

    func contains(_ p: Point) -> Bool {
        p.x >= Float(x) && p.x <= Float(x + w) && p.y >= Float(y) && p.y <= Float(y + h)
    }

    /// The box with `part` dragged by `dx, dy` document pixels (whole pixels, at least 1 × 1;
    /// dragging a side past the other flips it).
    func dragged(_ part: BoxPart, dx: Float, dy: Float, keepRatio: Bool) -> MarqueeBox {
        let b = dragged(part, dx: dx, dy: dy)
        guard keepRatio, part != .inside, w > 0, h > 0 else { return b }
        let ratio = Float(w) / Float(h)
        var out = b
        switch part {
        case let .corner(i):
            // The opposite corner stays; the side that moved more leads.
            let (fx, fy) = (i == 0 || i == 3 ? x + w : x, i == 0 || i == 1 ? y + h : y)
            var (nw, nh) = (Float(b.w), Float(b.h))
            if nw / Float(w) >= nh / Float(h) { nh = nw / ratio } else { nw = nh * ratio }
            (out.w, out.h) = (max(Int(nw.rounded()), 1), max(Int(nh.rounded()), 1))
            out.x = i == 0 || i == 3 ? fx - out.w : fx
            out.y = i == 0 || i == 1 ? fy - out.h : fy
        case let .edge(i):
            // The other side follows, about the box's middle.
            if i == 0 || i == 2 {
                out.w = max(Int((Float(b.h) * ratio).rounded()), 1)
                out.x = x + w / 2 - out.w / 2
            } else {
                out.h = max(Int((Float(b.w) / ratio).rounded()), 1)
                out.y = y + h / 2 - out.h / 2
            }
        case .inside: break
        }
        return out
    }

    func dragged(_ part: BoxPart, dx: Float, dy: Float) -> MarqueeBox {
        let (mx, my) = (Int(dx.rounded()), Int(dy.rounded()))
        var (x0, y0, x1, y1) = (x, y, x + w, y + h)
        switch part {
        case .inside:
            (x0, x1, y0, y1) = (x0 + mx, x1 + mx, y0 + my, y1 + my)
        case let .corner(i):
            if i == 0 || i == 3 { x0 += mx } else { x1 += mx }
            if i == 0 || i == 1 { y0 += my } else { y1 += my }
        case let .edge(i):
            switch i {
            case 0: y0 += my
            case 1: x1 += mx
            case 2: y1 += my
            default: x0 += mx
            }
        }
        var b = self
        (b.x, b.y) = (min(x0, x1), min(y0, y1))
        (b.w, b.h) = (max(abs(x1 - x0), 1), max(abs(y1 - y0), 1))
        return b
    }
}

/// A width for text that grows with the reader's text size (fixed points cut text off when it's
/// large).
func scaled(_ width: CGFloat) -> CGFloat { UIFontMetrics.default.scaledValue(for: width) }
