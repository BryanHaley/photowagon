import UIKit
import XCTest
@testable import PhotoWagon

/// Every sample in corpus/formats (made by scripts/format_samples.py) opened the way the app opens
/// files: our engine first, then Apple's decoder, then LibRaw. Records which one took each file,
/// and checks what Apple's decoder or LibRaw opened against the reference decode (8-bit, lossy
/// tolerance: they go through a colour-managed TIFF). The engine's own results are checked exactly
/// by crates/io/tests/format_matrix.rs. Skips when the corpus hasn't been generated.
@MainActor
final class FormatMatrixTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../corpus/formats").standardized
    }

    /// The composite as 8-bit RGBA straight from the PNG bytes (no colour conversion).
    private func pixels(_ png: Data) -> (Int, Int, [UInt8])? {
        guard let image = UIImage(data: png)?.cgImage else { return nil }
        let (w, h) = (image.width, image.height)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Back to straight alpha.
        for i in stride(from: 0, to: out.count, by: 4) where out[i + 3] > 0 && out[i + 3] < 255 {
            for k in 0..<3 { out[i + k] = UInt8(min(255, Int(out[i + k]) * 255 / Int(out[i + 3]))) }
        }
        return (w, h, out)
    }

    /// Samples nothing on iOS opens (or opens right) yet, and why.
    private let known: [String: String] = [
        "jpeg/12bit": "Apple's decoder gets the last (partial) block row of 12-bit JPEG wrong",
        "libjpeg-turbo/monkey12.jpg": "12-bit JPEG: as jpeg/12bit",
        "libtiff/testfax3_bug54_1dnoEOL.tif": "a damaged Group 3 fax file: Apple's decoder shows it inverted (our engine doesn't read Group 3)",
        "tiff/rgb8-zstd": "ZSTD TIFF: neither our engine nor Apple's decoder reads it",
        "tiff/rgb8-lzma": "LZMA TIFF: neither reads it",
        "libtiff/miniswhite-1c-1b.g3": "a raw Group 3 fax stream, not a TIFF",
        "libtiff/ojpeg_chewey_subsamp21_multi_strip.tiff": "subsampled old-style JPEG TIFF: neither reads it",
        "libtiff/ojpeg_single_strip_no_rowsperstrip.tiff": "subsampled old-style JPEG TIFF",
        "libtiff/ojpeg_zackthecat_subsamp22_single_strip.tiff": "subsampled old-style JPEG TIFF",
        "libtiff/webp_lossless_rgba_alpha_fully_opaque.tif": "tiff crate bug (RGBA TIFF whose WebP has no alpha); Apple doesn't read WebP TIFF",
    ]

    func testEveryFormatOpensAndAppleDecodesMatch() throws {
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = manifest["samples"] as? [[String: Any]] else {
            throw XCTSkip("run python3 -I scripts/format_samples.py first")
        }
        var rows: [String] = []
        var failed: [String] = []
        for s in samples {
            let file = s["file"] as? String ?? ""
            let name = "\(s["format"] ?? "?")/\(s["option"] ?? "?")"
            let model = makeModel()
            guard let bytes = try? Data(contentsOf: root.appendingPathComponent(file)) else { continue }
            let decoder: String
            do {
                decoder = try EditorModel.load(model.editor, bytes, (file as NSString).lastPathComponent) ?? "engine"
            } catch {
                rows.append("| \(name) | – | can't open: \(error) |")
                failed.append(name)
                continue
            }
            // Compared for every decoder: the engine's own results are checked exactly by
            // format_matrix.rs, here the whole open path is.
            let mode = (s["expect"] as? [String: Any])?["mode"] as? String ?? "Rgb"
            // "*": a public test file whose mode isn't promised (compared as shown).
            guard mode == "Rgb" || mode == "Grayscale" || mode == "*" else {
                rows.append("| \(name) | \(decoder) | opened (\(mode) converted to RGB, not compared) |")
                continue
            }
            let (w, h) = (s["width"] as? Int ?? 0, s["height"] as? Int ?? 0)
            // The preview and analysis images stop at 4096 pixels a side.
            guard max(w, h) <= 4096 else {
                rows.append("| \(name) | \(decoder) | opened (\(w) × \(h): too large to compare here) |")
                continue
            }
            // Official JPEG XL renderings are sRGB: compare the document as shown in sRGB.
            let srgb = s["srgb"] as? Bool == true
            let shown = srgb ? try? model.editor.previewImage(maxSide: UInt32(max(w, h))) : try? model.editor.analysisImage(layer: nil, maxSide: UInt32(max(w, h)))
            guard let png = shown, let (pw, ph, px) = pixels(png),
                  let refData = try? Data(contentsOf: root.appendingPathComponent(s["reference"] as? String ?? "")) else {
                rows.append("| \(name) | \(decoder) | no pixels |")
                failed.append(name)
                continue
            }
            let ref = refData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            guard (pw, ph) == (w, h), ref.count == w * h * 4 else {
                rows.append("| \(name) | \(decoder) | size \(pw)×\(ph), expected \(w)×\(h) |")
                failed.append(name)
                continue
            }
            var (sum, maxDiff) = (0.0, 0.0)
            for i in 0..<(w * h) {
                let alpha = Double(min(1, max(0, ref[i * 4 + 3])))
                for k in 0..<4 {
                    // Targa alpha opens as an alpha channel over an opaque Background (as in Photoshop).
                    if k == 3, s["format"] as? String == "tga" { continue }
                    let raw = abs(Double(px[i * 4 + k]) / 255 - Double(min(1, max(0, ref[i * 4 + k]))))
                    // Colour counts as much as it shows: none under transparent pixels.
                    let d = k < 3 ? raw * alpha : raw
                    sum += d
                    maxDiff = max(maxDiff, d)
                }
            }
            let mean = sum / Double(w * h * 4)
            // Apple's decoder upsamples 4:2:0 colour more simply than the reference decoders, which the
            // chart's 1-pixel colour pattern shows up: lossy samples get a wider margin.
            let lossy = s["tolerance"] as? String != "exact"
            let ok = lossy ? mean <= 0.03 && maxDiff <= 0.6 : mean <= 0.004 && maxDiff <= 0.02
            if !ok { failed.append(name) }
            rows.append("| \(name) | \(decoder) | \(ok ? "PASS" : "FAIL") mean \(String(format: "%.4f", mean)) max \(String(format: "%.3f", maxDiff)) |")
        }
        let report = "# Format matrix on iOS\n\n| Sample | Opened by | Result |\n|---|---|---|\n" + rows.joined(separator: "\n") + "\n"
        try? report.write(to: root.appendingPathComponent("ios-report.md"), atomically: true, encoding: .utf8)
        print(report)
        for name in known.keys where !failed.contains(name) {
            print("\(name) works now: take it off `known`")
        }
        let unexpected = failed.filter { known[$0] == nil }
        XCTAssert(unexpected.isEmpty, "not opened or wrong: \(unexpected)")
    }

    /// Every raw in corpus/pixls (`cargo xtask corpus --pixls`) through the app's open path:
    /// which decoder takes it, and the size it opens at. Only the High Efficiency NEF (TicoRAW)
    /// may fail: no decoder here reads it.
    func testEveryRawOpens() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../corpus/pixls").standardized
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil), !files.isEmpty else {
            throw XCTSkip("run cargo xtask corpus --pixls first")
        }
        var rows: [String] = []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let model = makeModel()
            guard let bytes = try? Data(contentsOf: url) else { continue }
            let name = url.lastPathComponent
            do {
                let decoder = try EditorModel.load(model.editor, bytes, name) ?? "engine"
                let doc = model.editor.document()
                rows.append("| \(name) | \(decoder) | \(doc.map { "\($0.width) × \($0.height)" } ?? "?") |")
            } catch {
                rows.append("| \(name) | – | can't open: \(error) |")
                if !name.contains("High_Efficiency") { XCTFail("\(name): \(error)") }
            }
        }
        let report = "# Raws on iOS\n\n| File | Opened by | Size |\n|---|---|---|\n" + rows.joined(separator: "\n") + "\n"
        try? report.write(to: dir.appendingPathComponent("../formats/ios-raws.md").standardized, atomically: true, encoding: .utf8)
        print(report)
    }
}
