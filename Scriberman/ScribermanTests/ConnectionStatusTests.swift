import Foundation
import XCTest
@testable import Scriberman

final class ConnectionStatusTests: XCTestCase {
    func testConnectedStatusesWithSameDateAreEqual() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let lhs = ConnectionStatus.connected(date)
        let rhs = ConnectionStatus.connected(date)

        XCTAssertEqual(lhs, rhs)
    }

    func testFailedStatusCarriesMessage() {
        let status = ConnectionStatus.failed("Unauthorized")

        guard case let .failed(message) = status else {
            return XCTFail("Expected .failed status")
        }
        XCTAssertEqual(message, "Unauthorized")
    }
}
