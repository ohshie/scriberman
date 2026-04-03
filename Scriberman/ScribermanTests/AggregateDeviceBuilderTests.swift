import CoreAudio
import Testing
@testable import Scriberman

final class AggregateDeviceBuilderTests {
    @Test
    func testCreateTapBuildsStereoMixdownTapAndReturnsID() throws {
        let hardware = MockAggregateHardware()
        hardware.createTapResult = 101
        hardware.processObjectIDResult = 902
        let builder = AggregateDeviceBuilder(hardware: hardware)

        let tapID = try builder.createTap(for: 222)

        #expect(tapID == 101)
        #expect(hardware.requestedPIDs == [222])
        #expect(hardware.createdTapProcessObjectIDs == [902])
    }

    @Test

    func testCreateAggregateDeviceUpdatesTapList() throws {
        let hardware = MockAggregateHardware()
        hardware.createAggregateResult = 303
        let builder = AggregateDeviceBuilder(hardware: hardware)

        let aggregateID = try builder.createAggregateDevice(micUID: "mic-uid", tapID: 101)

        #expect(aggregateID == 303)
        #expect(hardware.createAggregateMicUIDs == ["mic-uid"])
        #expect(hardware.tapListUpdates.count == 1)
        #expect(hardware.tapListUpdates.first?.aggregateDeviceID == 303)
    }

    @Test

    func testCreateAggregateDeviceCleansUpWhenTapListUpdateFails() {
        let hardware = MockAggregateHardware()
        hardware.createAggregateResult = 303
        hardware.updateTapListError = AggregateDeviceBuilderError.failedToUpdateTapList(-999)
        let builder = AggregateDeviceBuilder(hardware: hardware)

        #expect(throws: (any Error).self) { try builder.createAggregateDevice(micUID: "mic-uid", tapID: 101) }
        #expect(hardware.destroyedAggregateIDs == [303])
    }

    @Test

    func testTeardownDestroysTapThenAggregate() {
        let hardware = MockAggregateHardware()
        let builder = AggregateDeviceBuilder(hardware: hardware)

        builder.teardown(tapID: 123, aggregateDeviceID: 456)

        #expect(hardware.callOrder == ["destroyTap:123", "destroyAggregate:456"])
    }
}

private final class MockAggregateHardware: AggregateDeviceHardwareProviding {
    var processObjectIDResult: AudioObjectID = 0
    var createTapResult: AudioObjectID = 0
    var createAggregateResult: AudioDeviceID = 0
    var updateTapListError: Error?

    var requestedPIDs: [pid_t] = []
    var createdTapProcessObjectIDs: [AudioObjectID] = []
    var createAggregateMicUIDs: [String] = []
    var tapListUpdates: [(aggregateDeviceID: AudioDeviceID, tapUID: String)] = []
    var destroyedTapIDs: [AudioObjectID] = []
    var destroyedAggregateIDs: [AudioDeviceID] = []
    var callOrder: [String] = []

    func processObjectID(for pid: pid_t) throws -> AudioObjectID {
        requestedPIDs.append(pid)
        return processObjectIDResult
    }

    func createProcessTap(description: CATapDescription) throws -> AudioObjectID {
        createdTapProcessObjectIDs.append(description.processes.first ?? 0)
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
