import UIKit
import Vision

/// The objects in the image, found by Vision (as Photos lifts a subject), for Object
/// Selection, Select Subject and Remove Background. The engine's own selection is the fallback
/// when Vision finds nothing.
class ObjectFinder: @unchecked Sendable {
    struct Found {
        let observation: VNInstanceMaskObservation
        let handler: VNImageRequestHandler
        /// Vision's soft person matte (hair-level edges), when it finds a person.
        let person: CVPixelBuffer?
    }

    /// A mask over the whole image, `width × height` bytes (0 out, 255 in).
    struct Mask {
        let width: Int
        let height: Int
        let data: Data

        var params: [String: Any] { ["width": width, "height": height, "data": data.base64EncodedString()] }
    }

    /// Longest side of the image Vision looks at; the engine refines the edge at full size.
    static let maxSide: UInt32 = 2048

    /// Vision's objects in the active layer (`layer`) or the whole image (`nil`). Runs Vision
    /// every time: results aren't kept between operations.
    func objects(_ editor: Editor, layer: UInt64?) -> Found? {
        Self.find(editor, layer: layer)
    }

    private static func find(_ editor: Editor, layer: UInt64?) -> Found? {
        guard let png = try? editor.analysisImage(layer: layer, maxSide: maxSide), let image = UIImage(data: png)?.cgImage else { return nil }
        let handler = VNImageRequestHandler(cgImage: image)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let people = VNGeneratePersonSegmentationRequest()
        people.qualityLevel = .accurate
        people.outputPixelFormat = kCVPixelFormatType_OneComponent8
        guard (try? handler.perform([request])) != nil, let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil }
        // The person matte is optional: without it the object's own mask is used.
        let person = (try? handler.perform([people])) != nil ? people.results?.first?.pixelBuffer : nil
        return Found(observation: observation, handler: handler, person: person)
    }

    /// The object under (`x`, `y`), as fractions of the image's width and height.
    func instance(_ f: Found, x: Double, y: Double) -> Int? {
        let buffer = f.observation.instanceMask
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let (w, h) = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
        let px = min(max(Int(x * Double(w)), 0), w - 1), py = min(max(Int(y * Double(h)), 0), h - 1)
        let label = base.load(fromByteOffset: py * CVPixelBufferGetBytesPerRow(buffer) + px, as: UInt8.self)
        return label == 0 ? nil : Int(label)
    }

    /// A blue highlight of `instances` (all objects when `nil`) over the whole image, at most
    /// `maxSide` on a side.
    func highlight(_ f: Found, instances: IndexSet? = nil, maxSide: Int = 512) -> CGImage? {
        let buffer = f.observation.instanceMask
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let (w, h, row) = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), CVPixelBufferGetBytesPerRow(buffer))
        let set = instances ?? f.observation.allInstances
        return Self.tint(width: w, height: h, maxSide: maxSide) { x, y in
            set.contains(Int(base.load(fromByteOffset: y * row + x, as: UInt8.self))) ? 255 : 0
        }
    }

    /// A blue overlay of a `width × height` coverage mask (0–255), at most `maxSide` on a side,
    /// with a stronger edge.
    /// Vision's soft person matte of the whole image (`layer`: that layer only), for Refine Hair.
    func personMatte(_ editor: Editor, layer: UInt64?) -> Mask? {
        guard let png = try? editor.analysisImage(layer: layer, maxSide: Self.maxSide), let image = UIImage(data: png)?.cgImage else { return nil }
        let people = VNGeneratePersonSegmentationRequest()
        people.qualityLevel = .accurate
        people.outputPixelFormat = kCVPixelFormatType_OneComponent8
        guard (try? VNImageRequestHandler(cgImage: image).perform([people])) != nil, let buffer = people.results?.first?.pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let (w, h, row) = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), CVPixelBufferGetBytesPerRow(buffer))
        var out = Data(count: w * h)
        out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            for y in 0..<h {
                for x in 0..<w { dst[y * w + x] = base.load(fromByteOffset: y * row + x, as: UInt8.self) }
            }
        }
        return Mask(width: w, height: h, data: out)
    }

    /// Where the mask is mostly a person, take the person matte's softer edge (hair) too: the
    /// larger of the two, within the object's bounds grown by 5%.
    static func addHair(_ mask: inout Data, _ w: Int, _ h: Int, _ person: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(person, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(person, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(person), w > 0, h > 0 else { return }
        let (pw, ph, row) = (CVPixelBufferGetWidth(person), CVPixelBufferGetHeight(person), CVPixelBufferGetBytesPerRow(person))
        guard pw > 0, ph > 0 else { return }
        func matte(_ x: Int, _ y: Int) -> UInt8 {
            base.load(fromByteOffset: min(y * ph / h, ph - 1) * row + min(x * pw / w, pw - 1), as: UInt8.self)
        }
        var (inside, overlap) = (0, 0)
        var (x0, y0, x1, y1) = (w, h, -1, -1)
        for y in 0..<h {
            for x in 0..<w where mask[y * w + x] > 127 {
                inside += 1
                if matte(x, y) > 127 { overlap += 1 }
                (x0, y0, x1, y1) = (min(x0, x), min(y0, y), max(x1, x), max(y1, y))
            }
        }
        guard inside > 0, overlap * 2 > inside else { return }
        let (gx, gy) = ((x1 - x0) / 20 + 1, (y1 - y0) / 20 + 1)
        for y in max(0, y0 - gy)...min(h - 1, y1 + gy) {
            for x in max(0, x0 - gx)...min(w - 1, x1 + gx) {
                mask[y * w + x] = max(mask[y * w + x], matte(x, y))
            }
        }
    }

    static func tint(width: Int, height: Int, maxSide: Int = 512, coverage: (Int, Int) -> UInt8) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let step = max(1, (max(width, height) + maxSide - 1) / maxSide)
        let (tw, th) = ((width + step - 1) / step, (height + step - 1) / step)
        var cov = [UInt8](repeating: 0, count: tw * th)
        for ty in 0..<th {
            for tx in 0..<tw { cov[ty * tw + tx] = coverage(min(tx * step, width - 1), min(ty * step, height - 1)) }
        }
        let on = { (x: Int, y: Int) in x >= 0 && y >= 0 && x < tw && y < th && cov[y * tw + x] >= 128 }
        var px = [UInt8](repeating: 0, count: tw * th * 4)
        for y in 0..<th {
            for x in 0..<tw where cov[y * tw + x] > 0 {
                let edge = on(x, y) && !(on(x - 1, y) && on(x + 1, y) && on(x, y - 1) && on(x, y + 1))
                let a = edge ? 0.95 : 0.4 * Double(cov[y * tw + x]) / 255
                // Premultiplied.
                let i = (y * tw + x) * 4
                (px[i], px[i + 1], px[i + 2], px[i + 3]) = (UInt8(30 * a), UInt8(130 * a), UInt8(255 * a), UInt8(255 * a))
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: tw, height: th, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: tw * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The mask of `instances` (all objects when `nil`), at the analysed image's size.
    func mask(_ f: Found, instances: IndexSet? = nil) -> Mask? {
        guard let buffer = try? f.observation.generateScaledMaskForImage(forInstances: instances ?? f.observation.allInstances, from: f.handler) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let (w, h, row) = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), CVPixelBufferGetBytesPerRow(buffer))
        var out = Data(count: w * h)
        out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            for y in 0..<h {
                let line = base.advanced(by: y * row).assumingMemoryBound(to: Float32.self)
                for x in 0..<w {
                    dst[y * w + x] = UInt8(min(max(line[x], 0), 1) * 255)
                }
            }
        }
        if let person = f.person { Self.addHair(&out, w, h, person) }
        return Mask(width: w, height: h, data: out)
    }
}
