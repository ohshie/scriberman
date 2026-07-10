import Foundation
import Testing
@testable import Scriberman

@Suite
struct TextInjectorLadderTests {
    private final class CallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        var calls: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        func record(_ call: String) {
            lock.lock()
            defer { lock.unlock() }
            storage.append(call)
        }
    }

    private func makeInjector(
        trusted: Bool,
        axSucceeds: Bool,
        typeOutSucceeds: Bool,
        recorder: CallRecorder
    ) -> TextInjector {
        TextInjector(
            isTrusted: { trusted },
            axInsert: { _ in
                recorder.record("ax")
                return axSucceeds
            },
            typeOut: { _ in
                recorder.record("typeOut")
                return typeOutSucceeds
            },
            copyToClipboard: { _ in
                recorder.record("clipboard")
            }
        )
    }

    @Test
    func untrustedGoesStraightToDisclosedClipboard() {
        let recorder = CallRecorder()
        let injector = makeInjector(trusted: false, axSucceeds: true, typeOutSucceeds: true, recorder: recorder)

        #expect(injector.insert("hello") == .copiedToClipboard)
        #expect(recorder.calls == ["clipboard"])
    }

    @Test
    func trustedAXInsertionWinsWithoutTouchingClipboard() {
        let recorder = CallRecorder()
        let injector = makeInjector(trusted: true, axSucceeds: true, typeOutSucceeds: true, recorder: recorder)

        #expect(injector.insert("hello") == .insertedDirectly)
        #expect(recorder.calls == ["ax"])
    }

    @Test
    func axRefusalFallsToTypeOutWithoutTouchingClipboard() {
        let recorder = CallRecorder()
        let injector = makeInjector(trusted: true, axSucceeds: false, typeOutSucceeds: true, recorder: recorder)

        #expect(injector.insert("hello") == .typedOut)
        #expect(recorder.calls == ["ax", "typeOut"])
    }

    @Test
    func allRungsFailingIsAReportedFailureNotASilentClipboardWrite() {
        let recorder = CallRecorder()
        let injector = makeInjector(trusted: true, axSucceeds: false, typeOutSucceeds: false, recorder: recorder)

        #expect(injector.insert("hello") == .failed)
        #expect(!recorder.calls.contains("clipboard"))
    }

    @Test
    func emptyTextFailsWithoutSideEffects() {
        let recorder = CallRecorder()
        let injector = makeInjector(trusted: true, axSucceeds: true, typeOutSucceeds: true, recorder: recorder)

        #expect(injector.insert("") == .failed)
        #expect(recorder.calls.isEmpty)
    }
}

@Suite
struct UnicodeTypeOutChunkerTests {
    @Test
    func asciiSplitsAtTwentyUnits() {
        let text = String(repeating: "a", count: 45)
        let chunks = UnicodeTypeOutChunker.chunks(for: text)

        #expect(chunks.map(\.count) == [20, 20, 5])
        #expect(chunks.joined() == text)
    }

    @Test
    func exactlyTwentyUnitsIsOneChunk() {
        let text = String(repeating: "a", count: 20)
        #expect(UnicodeTypeOutChunker.chunks(for: text) == [text])
    }

    @Test
    func emptyStringYieldsNoChunks() {
        #expect(UnicodeTypeOutChunker.chunks(for: "").isEmpty)
    }

    @Test
    func surrogatePairsAreNeverSplit() {
        // Each emoji is one scalar of two UTF-16 units; 11 of them is 22 units,
        // which cannot pack evenly into 20-unit chunks without splitting a pair.
        let text = String(repeating: "😀", count: 11)
        let chunks = UnicodeTypeOutChunker.chunks(for: text)

        #expect(chunks.joined() == text)
        for chunk in chunks {
            #expect(chunk.utf16.count <= UnicodeTypeOutChunker.maxUTF16UnitsPerEvent)
            #expect(chunk.utf16.count % 2 == 0)
        }
        #expect(chunks.map { $0.utf16.count } == [20, 2])
    }

    @Test
    func mixedContentPreservesTextExactly() {
        let text = "Hello 世界 😀 — done. Ça va? 123"
        let chunks = UnicodeTypeOutChunker.chunks(for: text)

        #expect(chunks.joined() == text)
        for chunk in chunks {
            #expect(chunk.utf16.count <= UnicodeTypeOutChunker.maxUTF16UnitsPerEvent)
        }
    }
}
