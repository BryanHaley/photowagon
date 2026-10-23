import CoreML
import CryptoKit
import Foundation

/// Fills the hole in a square picture for AI Remove. Tests use a stand-in.
protocol Inpainter: Sendable {
    var side: Int { get }
    /// `image`: side × side RGB8; `mask`: side × side bytes, 255 in the hole. Returns side × side RGB8.
    func fill(image: Data, mask: Data) throws -> Data
}

struct AIRemoveError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// A Core ML inpainting model: `image` (RGB) and `mask` (gray, white = the hole), both `side` ×
/// `side`, in; `output` (RGB) out.
struct CoreMLInpainter: Inpainter {
    let url: URL
    let side: Int

    func fill(image: Data, mask: Data) throws -> Data {
        let n = side
        guard image.count == n * n * 3, mask.count == n * n else { throw AIRemoveError("AI Remove got a picture of the wrong size.") }
        let config = MLModelConfiguration()
        // The conversion was checked with every compute unit; others can change the result.
        config.computeUnits = .all
        let model = try MLModel(contentsOf: url, configuration: config)
        let picture = try Self.buffer(n, kCVPixelFormatType_32BGRA) { y, row in
            for x in 0..<n {
                let i = (y * n + x) * 3
                row[x * 4] = image[i + 2]
                row[x * 4 + 1] = image[i + 1]
                row[x * 4 + 2] = image[i]
                row[x * 4 + 3] = 255
            }
        }
        let hole = try Self.buffer(n, kCVPixelFormatType_OneComponent8) { y, row in
            for x in 0..<n { row[x] = mask[y * n + x] }
        }
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: picture), "mask": MLFeatureValue(pixelBuffer: hole)])
        guard let out = try model.prediction(from: input).featureValue(for: "output")?.imageBufferValue,
              CVPixelBufferGetPixelFormatType(out) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(out) == n, CVPixelBufferGetHeight(out) == n
        else { throw AIRemoveError("AI Remove's model gave an unexpected result.") }
        CVPixelBufferLockBaseAddress(out, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(out) else { throw AIRemoveError("AI Remove's model gave an empty result.") }
        let stride = CVPixelBufferGetBytesPerRow(out)
        var rgb = Data(count: n * n * 3)
        rgb.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            for y in 0..<n {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<n {
                    let i = (y * n + x) * 3
                    dst[i] = row[x * 4 + 2]
                    dst[i + 1] = row[x * 4 + 1]
                    dst[i + 2] = row[x * 4]
                }
            }
        }
        return rgb
    }

    private static func buffer(_ n: Int, _ format: OSType, fill: (Int, UnsafeMutablePointer<UInt8>) -> Void) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, n, n, format, nil, &made) == kCVReturnSuccess, let buf = made else {
            throw AIRemoveError("Not enough memory for AI Remove.")
        }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { throw AIRemoveError("Not enough memory for AI Remove.") }
        let stride = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<n { fill(y, base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)) }
        return buf
    }
}

/// AI Remove's model: downloaded the first time it's wanted, kept in Application Support.
@MainActor
final class ModelDownload: ObservableObject {
    static let shared = ModelDownload()

    enum State: Equatable { case missing, downloading(Double), ready, failed(String) }

    /// MI-GAN 512 (MIT) at a fixed revision of our mirror, checked by its SHA-256.
    static let source = URL(string: "https://huggingface.co/BryanHaley/photowagon-models/resolve/0e2fd237bbd4b6830a4eedbc1eac275238dc6996/migan/MIGAN.mlpackage.zip")!
    nonisolated static let sha256 = "c279edffd937627477b716376cea8e51aa8ac42c1691c8b47365020b915903c8"
    static let downloadBytes: Int64 = 24_529_826
    nonisolated static let name = "MIGAN"
    static let side = 512

    @Published private(set) var state: State
    let folder: URL
    var compiled: URL { folder.appendingPathComponent("\(Self.name).mlmodelc") }
    var inpainter: CoreMLInpainter? { state == .ready ? CoreMLInpainter(url: compiled, side: Self.side) : nil }

    private var task: URLSessionDownloadTask?
    private var watch: NSKeyValueObservation?

    init(folder: URL = URL.applicationSupportDirectory.appendingPathComponent("Models")) {
        self.folder = folder
        // The model AI Remove used before.
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("LaMa.mlmodelc"))
        state = FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(Self.name).mlmodelc").path) ? .ready : .missing
    }

    /// Downloads and installs the model; `done` gets the error, or nil once it's ready.
    func download(then done: @escaping @MainActor (Error?) -> Void = { _ in }) {
        guard task == nil, state != .ready else { return }
        state = .downloading(0)
        let folder = folder
        let task = URLSession.shared.downloadTask(with: Self.source) { tmp, response, error in
            // `tmp` is deleted once this returns, so the install happens here.
            let result = Result {
                guard let tmp else { throw error ?? AIRemoveError("The download failed.") }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw AIRemoveError("The download failed (HTTP \(http.statusCode)).")
                }
                try Self.install(zip: tmp, into: folder)
            }
            Task { @MainActor in
                self.task = nil
                self.watch = nil
                switch result {
                case .success:
                    self.state = .ready
                    done(nil)
                case .failure(let e):
                    self.state = (e as? URLError)?.code == .cancelled ? .missing : .failed(e.localizedDescription)
                    done(e)
                }
            }
        }
        watch = task.progress.observe(\.fractionCompleted) { p, _ in
            let f = p.fractionCompleted
            Task { @MainActor in if case .downloading = self.state { self.state = .downloading(f) } }
        }
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
    }

    func delete() {
        try? FileManager.default.removeItem(at: compiled)
        state = .missing
    }

    /// Checks the zip, unpacks it and compiles the model into `folder`.
    nonisolated static func install(zip: URL, into folder: URL, sha256 want: String = sha256) throws {
        guard try digest(zip) == want else { throw AIRemoveError("The download was damaged. Try again.") }
        let fm = FileManager.default
        let work = folder.appendingPathComponent("unpack-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try unzip(zip: zip.path, dest: work.path)
        let built = try MLModel.compileModel(at: work.appendingPathComponent("\(name).mlpackage"))
        var dest = folder.appendingPathComponent("\(name).mlmodelc")
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: built, to: dest)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dest.setResourceValues(values)
    }

    nonisolated static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 4 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// What AI Remove removes: painted strokes (document pixels), or the selection.
enum AIRemoveRequest: Equatable {
    case strokes([[Point]])
    case selection
}

extension EditorModel {
    /// AI Remove: the engine cuts the model's square round the strokes, the model fills it, and
    /// the engine pastes it back into the hole, as one undo step.
    func aiRemove(_ what: AIRemoveRequest, then: (() -> Void)? = nil) {
        guard let inpainter else {
            aiRemoveWaiting = what
            then?()
            return
        }
        let (size, hard, all, side, match) = (brushSize, hardness * 100, sampleAllLayers, inpainter.side, aiMatchColor)
        let points: [[[Double]]]? = if case .strokes(let s) = what { s.map { $0.map { [Double($0.x), Double($0.y)] } } } else { nil }
        let params = { (ai: [String: Any]) in
            var p: [String: Any] = ["size": size, "hardness": hard, "sampleAllLayers": all, "ai": ai]
            if let points { p["strokes"] = points } else { p["selection"] = true }
            return json(p)
        }
        whileBusy({ editor in
            let out = try editor.execute(id: "paint.removeAI", params: params(["side": side]))
            guard let v = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                  let image = (v["image"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let mask = (v["mask"] as? String).flatMap({ Data(base64Encoded: $0) })
            else { throw AIRemoveError("AI Remove couldn't read the picture.") }
            let filled = try inpainter.fill(image: image, mask: mask)
            _ = try editor.execute(id: "paint.remove", params: params(["side": side, "fill": filled.base64EncodedString(), "matchColor": match]))
        }, then: then)
    }

    /// The model to fill with: a test's stand-in, else the downloaded one.
    var inpainter: (any Inpainter)? { inpainterOverride ?? ModelDownload.shared.inpainter }

    /// Downloads the model, then removes what was waiting for it.
    func downloadAIModel() {
        let waiting = aiRemoveWaiting
        aiRemoveWaiting = nil
        ModelDownload.shared.download { [weak self] error in
            if let error {
                if (error as? URLError)?.code != .cancelled { self?.toast = "Couldn't download AI Remove: \(error.localizedDescription)" }
            } else if let waiting {
                self?.aiRemove(waiting)
            }
        }
    }
}
