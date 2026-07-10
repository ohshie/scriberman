import AVFoundation
import Foundation
import Testing
@testable import Scriberman

@Suite
struct WavHeaderRepairerTests {
    private func makeWavData(payloadBytes: Int, blockAlign: UInt16 = 2, stale: Bool) -> Data {
        var data = Data()
        let dataSize = UInt32(stale ? 0 : payloadBytes)
        let riffSize = UInt32(stale ? 36 : 36 + payloadBytes)

        data.append(Data("RIFF".utf8))
        data.append(uint32LE(riffSize))
        data.append(Data("WAVE".utf8))

        data.append(Data("fmt ".utf8))
        data.append(uint32LE(16))
        data.append(uint16LE(1))                       // PCM
        data.append(uint16LE(1))                       // mono
        data.append(uint32LE(16_000))                  // sample rate
        data.append(uint32LE(16_000 * UInt32(blockAlign)))
        data.append(uint16LE(blockAlign))
        data.append(uint16LE(blockAlign * 8))          // bits per sample

        data.append(Data("data".utf8))
        data.append(uint32LE(dataSize))
        data.append(Data(repeating: 0x11, count: payloadBytes))
        return data
    }

    private func writeTempFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    @Test
    func staleHeaderIsRepairedAndReadable() throws {
        let payloadBytes = 3_200
        let url = try writeTempFile(makeWavData(payloadBytes: payloadBytes, stale: true))
        defer { try? FileManager.default.removeItem(at: url) }

        let repaired = try WavHeaderRepairer.repairIfNeeded(at: url)
        #expect(repaired)

        let bytes = try Data(contentsOf: url)
        #expect(readUInt32LE(bytes, at: 4) == UInt32(36 + payloadBytes))
        #expect(readUInt32LE(bytes, at: 40) == UInt32(payloadBytes))

        let audioFile = try AVAudioFile(forReading: url)
        #expect(audioFile.length == Int64(payloadBytes / 2))
    }

    @Test
    func healthyFileIsLeftByteIdentical() throws {
        let original = makeWavData(payloadBytes: 1_000, stale: false)
        let url = try writeTempFile(original)
        defer { try? FileManager.default.removeItem(at: url) }

        let repaired = try WavHeaderRepairer.repairIfNeeded(at: url)
        #expect(!repaired)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test
    func tornTrailingFrameIsExcludedByBlockAlignment() throws {
        // 3,203 bytes with 2-byte frames: the final odd byte is a torn frame.
        let url = try writeTempFile(makeWavData(payloadBytes: 3_203, stale: true))
        defer { try? FileManager.default.removeItem(at: url) }

        let repaired = try WavHeaderRepairer.repairIfNeeded(at: url)
        #expect(repaired)

        let bytes = try Data(contentsOf: url)
        #expect(readUInt32LE(bytes, at: 40) == 3_202)
    }

    @Test
    func nonWavFileThrowsWithoutModification() throws {
        let junk = Data((0..<256).map { _ in UInt8.random(in: 0...255) })
        let url = try writeTempFile(junk)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: (any Error).self) {
            try WavHeaderRepairer.repairIfNeeded(at: url)
        }
        #expect(try Data(contentsOf: url) == junk)
    }

    @Test
    func tinyFileThrows() throws {
        let url = try writeTempFile(Data("RIFF".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: (any Error).self) {
            try WavHeaderRepairer.repairIfNeeded(at: url)
        }
    }

    // MARK: - Byte helpers

    private func uint32LE(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private func uint16LE(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
