import XCTest
@testable import PhotoWagon

/// Omega (the long pre-release test) must know about everything the app has: these fail when
/// something new isn't in `OmegaCatalog`.
@MainActor
final class OmegaCatalogTests: XCTestCase {
    func testTheCatalogNamesRealCommands() {
        let ids = Set(EditorModel().editor.allCommands().map(\.id))
        XCTAssertEqual(Set(OmegaCatalog.skipped.keys).subtracting(ids), [], "skipped commands that no longer exist")
        XCTAssertEqual(Set(OmegaCatalog.fixedParams.keys).subtracting(ids), [], "fixed settings for commands that no longer exist")
        XCTAssertEqual(OmegaCatalog.historyCommands.subtracting(ids), [], "history commands that no longer exist")
        XCTAssertEqual(Set(OmegaCatalog.setup.keys).subtracting(ids), [], "setup steps for commands that no longer exist")
        let setupIDs = Set(OmegaCatalog.setup.values.flatMap { $0.map(\.0) })
        XCTAssertEqual(setupIDs.subtracting(ids), [], "setup steps that use commands that no longer exist")
        XCTAssertEqual(Set(OmegaCatalog.notUndoable.keys).subtracting(ids), [], "not-undoable commands that no longer exist")
        XCTAssertEqual(Set(OmegaCatalog.flatExportDiffers.keys).subtracting(ids), [], "flat-export exceptions for commands that no longer exist")
    }

    func testToolsThatOnlyLookAreRealTools() {
        let tools = Set(Tool.allCases.map(\.rawValue))
        XCTAssertEqual(Set(OmegaCatalog.toolsThatOnlyLook.keys).subtracting(tools), [])
    }

    func testEveryStoredSettingIsInTheCatalog() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PhotoWagon")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        let pattern = try NSRegularExpression(pattern: #"(?:forKey: |@AppStorage\(|static let key = )"([^"\\]+)""#)
        var found = Set<String>()
        for f in files {
            let s = try String(contentsOf: f, encoding: .utf8)
            for m in pattern.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                if let r = Range(m.range(at: 1), in: s) { found.insert(String(s[r])) }
            }
        }
        XCTAssertFalse(found.isEmpty)
        let known = OmegaCatalog.settings.union(OmegaCatalog.launchFlags).union(OmegaCatalog.notSettings.keys)
        XCTAssertEqual(found.subtracting(known), [], "settings Omega doesn't know about: add them to OmegaCatalog.settings")
        XCTAssertEqual(known.subtracting(found), [], "OmegaCatalog lists settings the app no longer has")
    }

    func testPairsCoverEveryPair() {
        for sizes in [[3, 4, 2, 5], [2, 2, 2, 2, 2, 2, 2, 2], [9, 1, 3], [5], [4, 3]] {
            let rows = Pairs.rows(sizes)
            XCTAssert(rows.allSatisfy { $0.count == sizes.count && zip($0, sizes).allSatisfy { v, n in v >= 0 && v < n } }, "\(sizes)")
            for i in sizes.indices {
                for j in sizes.indices where j > i {
                    for a in 0..<sizes[i] {
                        for b in 0..<sizes[j] {
                            XCTAssert(rows.contains { $0[i] == a && $0[j] == b }, "\(sizes): factors \(i)=\(a), \(j)=\(b)")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(Pairs.rows([3, 4, 2, 5]), Pairs.rows([3, 4, 2, 5]), "same sizes, same rows")
        XCTAssertLessThan(Pairs.rows([2, 2, 2, 2, 2, 2, 2, 2]).count, 12, "far fewer than all 256 combinations")
        XCTAssertEqual(Pairs.rows([]).count, 1)
    }
}
