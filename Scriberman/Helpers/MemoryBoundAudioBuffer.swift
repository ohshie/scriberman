import Foundation

final class MemoryBoundAudioBuffer: Sendable {
    private enum Storage {
        case array([Float])
        case mapped(Data)
    }

    private let storage: Storage
    let count: Int

    init(samples: [Float]) {
        self.storage = .array(samples)
        self.count = samples.count
    }

    init(url: URL) throws {
        // Use memory-mapped data for large files
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        self.storage = .mapped(data)
        self.count = data.count / MemoryLayout<Float>.size
    }

    func withUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<Float>) throws -> R) rethrows -> R {
        switch storage {
        case .array(let array):
            return try array.withUnsafeBufferPointer(body)
        case .mapped(let data):
            return try data.withUnsafeBytes { rawBuffer in
                let floatBuffer = rawBuffer.bindMemory(to: Float.self)
                return try body(floatBuffer)
            }
        }
    }
}
