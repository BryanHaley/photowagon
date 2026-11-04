import UIKit
import XCTest
@testable import PhotoWagon

/// A section of its own: runs `body`, writes the section's status and fails on any problem.
@MainActor
class OmegaSectionTests: XCTestCase {
    func section(_ body: (Omega) -> Void) {
        let omega = Omega(shard: String(describing: type(of: self)))
        body(omega)
        omega.finish()
        XCTAssertEqual(omega.failed, 0, "cases with problems: see \(omega.folder.path)/results.jsonl")
    }
}

final class OmegaSaveReopenTests: OmegaSectionTests {
    func testSaveAndReopen() { section { $0.runRoundTrips() } }
}

final class OmegaDepthsTests: OmegaSectionTests {
    func testEveryDepthAgrees() { section { $0.runDepths() } }
}

final class OmegaPicturesTests: OmegaSectionTests {
    func testReferencePictures() { section { $0.runPictures() } }
}

/// Timings only mean something on one setup: iOS 27.
final class OmegaSpeedTests: OmegaSectionTests {
    func testSpeedAndMemory() {
        section { omega in if UIDevice.current.systemVersion.hasPrefix("27") { omega.runSpeed() } }
    }
}

final class OmegaSessionsTests: OmegaSectionTests {
    func testRandomSessions() { section { $0.runSessions(count: 200, steps: 200) } }
}

final class OmegaToolsTests: OmegaSectionTests {
    func testEveryTool() { section { $0.runTools() } }
}

final class OmegaSettingsTests: OmegaSectionTests {
    func testSettingsTogether() { section { $0.runSettings() } }
}

/// Every format and import, with real files (OmegaFiles.swift).
final class OmegaFilesTests: OmegaSectionTests {
    func testEveryFormatAndImport() { section { $0.runFiles() } }
}
