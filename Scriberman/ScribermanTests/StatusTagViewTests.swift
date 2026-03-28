import XCTest
@testable import Scriberman

final class StatusTagViewTests: XCTestCase {
    func testDoneMapsToGreenTint() {
        let style = StatusTagView.style(for: .done)
        XCTAssertEqual(style.label, "Done")
        XCTAssertEqual(style.tint, .green)
    }

    func testPendingMapsToOrangeTint() {
        XCTAssertEqual(StatusTagView.style(for: .recorded).tint, .orange)
        XCTAssertEqual(StatusTagView.style(for: .converting).tint, .orange)
        XCTAssertEqual(StatusTagView.style(for: .transcribing).tint, .orange)
        XCTAssertEqual(StatusTagView.style(for: .retranscribing).tint, .orange)
    }

    func testFailedMapsToRedTint() {
        let style = StatusTagView.style(for: .error("boom"))
        XCTAssertEqual(style.label, "Failed")
        XCTAssertEqual(style.tint, .red)
    }
}
