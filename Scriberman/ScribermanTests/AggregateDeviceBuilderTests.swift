import CoreAudio
import XCTest
@testable import Scriberman

final class AggregateDeviceBuilderTests: XCTestCase {
    func testCreateTapBuildsStereoMixdownTapAndReturnsID() throws {
        let hardware = MockAggregateHardware()
        hardware.createTapResult = 101
        let builder = AggregateDeviceBuilder(hardware: hardware)

        let tapID = try builder.createTap(for: 222)

        XCTAssertEqual(tapID, 101)
        XCTAssertEqual(hardware.createdTapPIDs, [222])
    }

    func testCreateAggregateDeviceUpdatesTapList() throws {
        let hardware = MockAggregateHardware()
        hardware.createAggregateResult = 303
        let builder = AggregateDeviceBuilder(hardware: hardware)

        let aggregateID = try builder.createAggregateDevice(micUID: "mic-uid", tapID: 101)

        XCTAssertEqual(aggregateID, 303)
        XCTAssertEqual(hardware.createAggregateMicUIDs, ["mic-uid"])
        XCTAssertEqual(hardware.tapListUpdates.count, 1)
        XCTAssertEqual(hardware.tapListUpdates.first?.aggregateDeviceID, 303)
    }

    func testCreateAggregateDeviceCleansUpWhenTapListUpdateFails() {
        let hardware = MockAggregateHardware()
        hardware.createAggregateResult = 303
        hardware.updateTapListError = AggregateDeviceBuilderError.failedToUpdateTapList(-999)
        let builder = AggregateDeviceBuilder(hardware: hardware)

        XCTAssertThrowsError(try builder.createAggregateDevice(micUID: "mic-uid", tapID: 101))
        XCTAssertEqual(hardware.destroyedAggregateIDs, [303])
    }

    func testTeardownDestroysTapThenAggregate() {
        let hardware = MockAggregateHardware()
        let builder = AggregateDeviceBuilder(hardware: hardware)

        builder.teardown(tapID: 123, aggregateDeviceID: 456)

        XCTAssertEqual(hardware.callOrder, ["destroyTap:123", "destroyAggregate:456"])
    }
}

private final class MockAggregateHardware: AggregateDeviceHardwareProviding {
    var createTapResult: AudioObjectID = 0
    var createAggregateResult: AudioDeviceID = 0
    var updateTapListError: Error?

    var createdTapPIDs: [pid_t] = []
    var createAggregateMicUIDs: [String] = []
    var tapListUpdates: [(aggregateDeviceID: AudioDeviceID, tapUID: String)] = []
    var destroyedTapIDs: [AudioObjectID] = []
    var destroyedAggregateIDs: [AudioDeviceID] = []
    var callOrder: [String] = []

    func createProcessTap(description: CATapDescription) throws -> AudioObjectID {
        createdTapPIDs.append(description.processes.map { pid_t($0) }.first ?? 0)
        return createTapResult
    }

    func createAggregateDevice(description: CFDictionary) throws -> AudioDeviceID {
        let dictionary = description as NSDictionary
        if let micUID = dictionary[kAudioAggregateDeviceMainSubDeviceKey] as? String {
            createAggregateMicUIDs.append(micUID)
        }
        return createAggregateResult
    }

    func updateAggregateTapList(aggregateDeviceID: AudioDeviceID, tapUID: String) throws {
        tapListUpdates.append((aggregateDeviceID: aggregateDeviceID, tapUID: tapUID))
        if let updateTapListError {
            throw updateTapListError
        }
    }

    func destroyProcessTap(_ tapID: AudioObjectID) {
        destroyedTapIDs.append(tapID)
        callOrder.append("destroyTap:\(tapID)")
    }

    func destroyAggregateDevice(_ aggregateDeviceID: AudioDeviceID) {
        destroyedAggregateIDs.append(aggregateDeviceID)
        callOrder.append("destroyAggregate:\(aggregateDeviceID)")
    }
}
