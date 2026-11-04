import XCTest

/// The Type tool on placed text: two lines, the text colour from the options bar, and the box
/// around the text that moves it and changes its size, without Free Transform.
final class TypeBoxTests: WalkthroughTestCase {
    private var info: [String: Any] { typeInfo(textLayer) }
    private var textLayer = ""
    private var style: [String: Any] { ((info["runs"] as? [[String: Any]])?.first?["style"]) as? [String: Any] ?? [:] }
    private var anchor: (Double, Double) {
        let m = info["transform"] as? [Double] ?? [0, 0, 0, 0, 0, 0]
        return (m[4], m[5])
    }

    func testTypeBox() {
        step("Horizontal Type: tap, two lines of text, OK") {
            openSample("seaside")
            tool(group: "Horizontal Type", pick: "Horizontal Type")
            at(300, 300).tap()
            replace(promptField, with: "Sunny\nday")
            app.buttons["prompt.ok"].firstMatch.tap()
            waitIdle()
            textLayer = layers.first?["name"] as? String ?? ""
            XCTAssertEqual((info["lines"] as? [Any])?.count, 2, "\(info)")
        }

        step("The options bar's Text Color, first in the bar: red") {
            tapAt(app.descendants(matching: .any)["type.color"].firstMatch)
            chooseColor(containing: "red")
            waitIdle()
            let c = (style["color"] as? [String: Any])?["c"] as? [Double] ?? []
            XCTAssert(c.count >= 3 && c[0] > 0.9 && c[1] < 0.1 && c[2] < 0.1, "red: \(c)")
        }

        let start = anchor
        let size = style["size_pt"] as? Double ?? 0
        step("Drag inside the text's box: it moves") {
            let b = info["bounds"] as? [Double] ?? [0, 0, 0, 0]
            let mid = ((b[0] + b[2]) / 2, (b[1] + b[3]) / 2)
            drag(doc: mid, to: (mid.0 + 150, mid.1 + 100))
            waitIdle()
            XCTAssertEqual(anchor.0, start.0 + 150, accuracy: 15)
            XCTAssertEqual(anchor.1, start.1 + 100, accuracy: 15)
            XCTAssertEqual(style["size_pt"] as? Double ?? 0, size, accuracy: 0.01, "moving keeps the size")
        }

        step("Drag its bottom-right corner out: the text gets bigger") {
            let b = info["bounds"] as? [Double] ?? [0, 0, 0, 0]
            drag(doc: (b[2], b[3]), to: (b[2] + (b[2] - b[0]) / 2, b[3] + (b[3] - b[1]) / 2))
            waitIdle()
            XCTAssertGreaterThan(style["size_pt"] as? Double ?? 0, size * 1.3, "\(style)")
            XCTAssertEqual(layers.first?["kind"] as? String, "Type", "still text")
        }
    }
}
