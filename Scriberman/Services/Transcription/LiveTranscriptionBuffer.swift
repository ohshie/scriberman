import Foundation

actor LiveTranscriptionBuffer {
    private let chunkSampleCount: Int
    private let sampleRate: Float

    private var buffers: [AudioSource: [Float]] = [:]
    private var chunkStartTimes: [AudioSource: Date] = [:]
    private var totalSamplesProcessed: [AudioSource: Int] = [:]
    private var pendingChunkOffsets: [AudioSource: Float] = [:]

    init(chunkSampleCount: Int = 160_000, sampleRate: Float = 16_000) {
        self.chunkSampleCount = chunkSampleCount
        self.sampleRate = sampleRate
    }

    func append(samples: [Float], source: AudioSource) -> [Float]? {
        guard !samples.isEmpty else {
            return nil
        }

        if chunkStartTimes[source] == nil {
            chunkStartTimes[source] = .now
        }

        var currentBuffer = buffers[source] ?? []
        currentBuffer.append(contentsOf: samples)

        if currentBuffer.count >= chunkSampleCount {
            let chunkToProcess = currentBuffer
            currentBuffer.removeAll()
            buffers[source] = currentBuffer
            chunkStartTimes[source] = nil

            let currentOffset = Float(totalSamplesProcessed[source] ?? 0) / sampleRate
            totalSamplesProcessed[source] = (totalSamplesProcessed[source] ?? 0) + chunkToProcess.count
            pendingChunkOffsets[source] = currentOffset

            return chunkToProcess
        }

        buffers[source] = currentBuffer
        return nil
    }

    func takePendingChunkOffset(for source: AudioSource) -> Float? {
        let offset = pendingChunkOffsets[source]
        pendingChunkOffsets[source] = nil
        return offset
    }

    func currentOffset(for source: AudioSource) -> Float {
        Float(totalSamplesProcessed[source] ?? 0) / sampleRate
    }

    func remainingBuffers() -> [AudioSource: [Float]] {
        buffers
    }

    func reset() {
        buffers.removeAll()
        chunkStartTimes.removeAll()
        totalSamplesProcessed.removeAll()
        pendingChunkOffsets.removeAll()
    }
}
