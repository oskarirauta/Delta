import XCTest
@testable import DeltaTVCatalog

final class JITStatusTests: XCTestCase {
    func testPreferenceAndDebuggerCannotMakeAnUnsupportedCoreActive() {
        XCTAssertEqual(TVJITStatus(backendSupported: false, debugFlag: true, requested: true, active: false), .unsupported)
    }
    func testOnlyBackendReportedExecutionIsActive() {
        XCTAssertEqual(TVJITStatus(backendSupported: true, debugFlag: true, requested: true, active: false), .nextSession)
        XCTAssertEqual(TVJITStatus(backendSupported: true, debugFlag: true, requested: true, active: true), .active)
    }
    func testChangingPreferenceDoesNotPretendToStopRunningJIT() {
        XCTAssertEqual(TVJITStatus(backendSupported: true, debugFlag: true, requested: false, active: true), .active)
    }
    func testDisabledAndMissingPermissionAreDistinct() {
        XCTAssertEqual(TVJITStatus(backendSupported: true, debugFlag: true, requested: false, active: false), .disabled)
        XCTAssertEqual(TVJITStatus(backendSupported: true, debugFlag: false, requested: true, active: false), .permissionRequired)
    }
}
