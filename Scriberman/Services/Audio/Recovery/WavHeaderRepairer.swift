import Foundation

enum WavHeaderRepairError: Error {
    case notAWavFile
    case malformedChunkLayout
}

/// Repairs WAV files whose writer never closed them. `AVAudioFile` patches the
/// RIFF and data-chunk size fields only on `close()`, so a crash or power loss
/// leaves valid PCM behind a header that claims (near-)zero data — readers see
/// an empty file. Repair rewrites the two size fields from the physical file
/// length, frame-aligned so a torn trailing frame is excluded (design D2).
/// Correctly closed files are left byte-identical.
enum WavHeaderRepairer {
    /// Returns true when a repair was written, false when the header already
    /// matched the file. Throws for non-WAV or structurally malformed input.
    static func repairIfNeeded(at url: URL) throws -> Bool {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        let fileLength = try handle.seekToEnd()
        guard fileLength >= 44 else { throw WavHeaderRepairError.notAWavFile }

        try handle.seek(toOffset: 0)
        guard let riffHeader = try handle.read(upToCount: 12), riffHeader.count == 12,
              riffHeader.subdata(in: 0..<4) == Data("RIFF".utf8),
              riffHeader.subdata(in: 8..<12) == Data("WAVE".utf8)
        else {
            throw WavHeaderRepairError.notAWavFile
        }
        let declaredRiffSize = riffHeader.uint32LE(at: 4)

        // Walk chunks: fmt supplies the block align, data is the payload.
        // AVAudioFile always writes data as the final chunk, so preceding
        // chunk sizes (written at prepare time) are trustworthy to skip by.
        var offset: UInt64 = 12
        var blockAlign: UInt64 = 1

        while offset + 8 <= fileLength {
            try handle.seek(toOffset: offset)
            guard let chunkHeader = try handle.read(upToCount: 8), chunkHeader.count == 8 else {
                throw WavHeaderRepairError.malformedChunkLayout
            }
            let chunkID = chunkHeader.subdata(in: 0..<4)
            let declaredChunkSize = chunkHeader.uint32LE(at: 4)

            if chunkID == Data("fmt ".utf8) {
                guard let fmt = try handle.read(upToCount: 16), fmt.count == 16 else {
                    throw WavHeaderRepairError.malformedChunkLayout
                }
                // Bytes 12-13 of the fmt payload: nBlockAlign.
                let align = UInt64(fmt.uint16LE(at: 12))
                blockAlign = max(align, 1)
            }

            if chunkID == Data("data".utf8) {
                let dataOffset = offset + 8
                let physicalDataSize = fileLength - dataOffset
                let alignedDataSize = physicalDataSize - (physicalDataSize % blockAlign)
                let correctDataSize = UInt32(clamping: alignedDataSize)
                let correctRiffSize = UInt32(clamping: dataOffset + alignedDataSize - 8)

                if declaredChunkSize == correctDataSize && declaredRiffSize == correctRiffSize {
                    return false
                }

                try handle.seek(toOffset: 4)
                try handle.write(contentsOf: correctRiffSize.littleEndianData)
                try handle.seek(toOffset: offset + 4)
                try handle.write(contentsOf: correctDataSize.littleEndianData)
                return true
            }

            // Chunk payloads are padded to even lengths.
            let paddedSize = UInt64(declaredChunkSize) + UInt64(declaredChunkSize % 2)
            offset += 8 + paddedSize
        }

        throw WavHeaderRepairError.malformedChunkLayout
    }
}

private extension Data {
    func uint32LE(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        return UInt32(self[base])
            | (UInt32(self[base + 1]) << 8)
            | (UInt32(self[base + 2]) << 16)
            | (UInt32(self[base + 3]) << 24)
    }

    func uint16LE(at offset: Int) -> UInt16 {
        let base = startIndex + offset
        return UInt16(self[base]) | (UInt16(self[base + 1]) << 8)
    }
}

private extension UInt32 {
    var littleEndianData: Data {
        withUnsafeBytes(of: littleEndian) { Data($0) }
    }
}
