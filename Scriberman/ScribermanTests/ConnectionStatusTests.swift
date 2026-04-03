import Foundation
import Testing
@testable import Scriberman

struct ConnectionStatusTests {
    @Test
    func connectedStatusesWithSameDateAreEqual() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let lhs = ConnectionStatus.connected(date)
        let rhs = ConnectionStatus.connected(date)

        #expect(lhs == rhs)
    }

    @Test
    func failedStatusCarriesMessage() {
        let status = ConnectionStatus.failed("Unauthorized")

        guard case let .failed(message) = status else {
            Issue.record("Expected .failed status")
            return
        }
        #expect(message == "Unauthorized")
    }
}
