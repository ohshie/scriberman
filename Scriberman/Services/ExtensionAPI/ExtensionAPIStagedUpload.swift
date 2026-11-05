import CryptoKit
import Darwin
import Foundation

/// An import body on its way to disk: one file, created exclusively, in a directory of its own.
/// It hashes the bytes as they are written, so the signed body hash is checked against what was
/// actually received. Whoever holds it last calls `discard()`, which removes the directory.
///
/// The listener writes from its queue while the handler reads the result on the main actor, so
/// every member is guarded by a lock.
final class ExtensionAPIStagedUpload: @unchecked Sendable {
    /// The directory made for this upload alone.
    let directoryURL: URL
    /// The file the body is written to.
    let fileURL: URL

    private let lock = NSLock()
    private var descriptor: Int32
    private var hasher = SHA256()
    private var digest: String?
    private var _writeFailed = false
    private var isDiscarded = false

    /// Creates the file `name` inside `directory`, never through an existing file or link.
    /// On failure the directory is removed.
    init(directory: URL, name: String) throws {
        directoryURL = directory
        fileURL = directory.appendingPathComponent(name, isDirectory: false)
        let fd = open(fileURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: directory)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        descriptor = fd
    }

    deinit {
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    /// A new directory with a unique name inside `root`, readable only by this user.
    static func makeUniqueDirectory(in root: URL) throws -> URL {
        var template = Array(root.appendingPathComponent("ScribermanImport.XXXXXXXX").path.utf8CString)
        let made = template.withUnsafeMutableBufferPointer { buffer in
            mkdtemp(buffer.baseAddress!)
        }
        guard made != nil else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return URL(fileURLWithPath: String(cString: template), isDirectory: true)
    }

    /// Whether writing any chunk failed. Later chunks are still hashed.
    var writeFailed: Bool {
        lock.withLock { _writeFailed }
    }

    /// The lowercase hex SHA-256 of every byte passed to `write`, once `finishWriting` ran.
    var bodySHA256: String? {
        lock.withLock { digest }
    }

    func write(_ chunk: Data) {
        lock.withLock {
            guard digest == nil else { return }
            hasher.update(data: chunk)
            guard !_writeFailed, descriptor >= 0 else { return }
            let complete = chunk.withUnsafeBytes { buffer -> Bool in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    offset += written
                }
                return true
            }
            if !complete {
                _writeFailed = true
            }
        }
    }

    /// Closes the file and fixes the body hash.
    func finishWriting() {
        lock.withLock {
            guard digest == nil else { return }
            if descriptor >= 0 {
                if Darwin.close(descriptor) != 0 {
                    _writeFailed = true
                }
                descriptor = -1
            }
            digest = ExtensionAPISigning.hex(hasher.finalize())
        }
    }

    /// Closes the file if open and removes the directory with everything in it. Safe to call more
    /// than once.
    func discard() {
        lock.withLock {
            guard !isDiscarded else { return }
            isDiscarded = true
            if descriptor >= 0 {
                Darwin.close(descriptor)
                descriptor = -1
            }
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }
}

extension ExtensionAPIStagedUpload: Equatable {
    static func == (lhs: ExtensionAPIStagedUpload, rhs: ExtensionAPIStagedUpload) -> Bool {
        lhs === rhs
    }
}
