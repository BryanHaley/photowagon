import XCTest
@testable import PhotoWagon

/// Free Transform small, then big again: a pixel layer loses its detail, an embedded layer keeps
/// it (LayersTests' kinds of layers).
@MainActor
final class LayersCoverage: XCTestCase {
    /// A 400 × 400 document with a striped 200 × 200 square at 100, 100 on layer "stripes".
    private func striped() -> EditorModel {
        let model = makeModel(width: 400, height: 400)
        model.run("layer.new.layer", ["name": "stripes"])
        model.setForeground(.black)
        for x in stride(from: 100, to: 300, by: 8) {
            model.run("select.rect", ["x": x, "y": 100, "width": 4, "height": 200])
            model.run("edit.fill")
        }
        model.run("select.deselect")
        return model
    }

    /// Free Transform to a twentieth about the centre, then back, as the app commits it.
    private func shrinkAndGrow(_ model: EditorModel) {
        let full: [Double] = [100, 100, 300, 300], small: [Double] = [195, 195, 205, 205]
        let quad = { (r: [Double]) in [[r[0], r[1]], [r[2], r[1]], [r[2], r[3]], [r[0], r[3]]] }
        model.run("edit.transform", ["rect": full, "quad": quad(small)])
        model.run("edit.transform", ["rect": small, "quad": quad(full)])
    }

    func testSmallThenBigLosesDetailUnlessEmbedded() {
        let area = [120, 120, 280, 280]
        let pixels = striped()
        let sharp = pixels.stddev(area)
        XCTAssertGreaterThan(sharp, 0.3)
        shrinkAndGrow(pixels)
        XCTAssertLessThan(pixels.stddev(area), sharp * 0.5, "a pixel layer blurs")

        let embedded = striped()
        embedded.run("layer.smartObjects.convertToSmartObject")
        XCTAssertEqual(embedded.activeLayer?.kind, "Embedded")
        shrinkAndGrow(embedded)
        XCTAssertEqual(embedded.stddev(area), sharp, accuracy: sharp * 0.05, "an embedded layer stays sharp")
    }
}
