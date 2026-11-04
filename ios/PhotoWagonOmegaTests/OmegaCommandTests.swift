import XCTest
@testable import PhotoWagon

/// Tier B over every engine command, one class per menu so the runner can share them out between
/// two simulators. Results: `$OMEGA_OUT/<class>/results.jsonl`; the runner reads them and makes the
/// report. A class fails when any of its cases found a problem.
@MainActor
class OmegaCommandTests: XCTestCase {
    /// The commands this class covers.
    class func includes(_ c: CommandInfo) -> Bool { false }

    func testCommands() throws {
        guard type(of: self) != OmegaCommandTests.self else { return }
        let omega = Omega(shard: String(describing: type(of: self)))
        omega.runCommands { Self.includes($0) }
        omega.finish()
        XCTAssertEqual(omega.failed, 0, "cases with problems: see \(omega.folder.path)/results.jsonl")
    }

    static func top(_ c: CommandInfo) -> String { c.menu.components(separatedBy: " > ").first ?? "" }
}

final class OmegaFileTests: OmegaCommandTests { override class func includes(_ c: CommandInfo) -> Bool { top(c) == "File" } }
final class OmegaEditTests: OmegaCommandTests { override class func includes(_ c: CommandInfo) -> Bool { top(c) == "Edit" } }
final class OmegaImageTests: OmegaCommandTests { override class func includes(_ c: CommandInfo) -> Bool { top(c) == "Image" } }
final class OmegaLayerTests: OmegaCommandTests { override class func includes(_ c: CommandInfo) -> Bool { top(c) == "Layer" } }
final class OmegaTypeTests: OmegaCommandTests { override class func includes(_ c: CommandInfo) -> Bool { top(c) == "Type" } }
final class OmegaSelectTests: OmegaCommandTests { override class func includes(_ c: CommandInfo) -> Bool { top(c) == "Select" } }
final class OmegaFilterTests: OmegaCommandTests { override class func includes(_ c: CommandInfo) -> Bool { top(c) == "Filter" } }
final class OmegaViewTests: OmegaCommandTests { override class func includes(_ c: CommandInfo) -> Bool { top(c) == "View" } }
/// Commands with no menu (tools, panels, scripting), split by the first letter of their id.
final class OmegaHiddenAtoLTests: OmegaCommandTests {
    override class func includes(_ c: CommandInfo) -> Bool { top(c).isEmpty && c.id < "m" }
}
final class OmegaHiddenMtoZTests: OmegaCommandTests {
    override class func includes(_ c: CommandInfo) -> Bool { top(c).isEmpty && c.id >= "m" }
}
/// Anything in a menu the classes above don't name.
final class OmegaOtherMenuTests: OmegaCommandTests {
    override class func includes(_ c: CommandInfo) -> Bool {
        !["", "File", "Edit", "Image", "Layer", "Type", "Select", "Filter", "View"].contains(top(c))
    }
}
