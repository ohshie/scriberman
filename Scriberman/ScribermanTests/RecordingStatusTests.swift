import Foundation
import SwiftData
import Testing
@testable import Scriberman

struct RecordingStatusTests {
    
    
    @Test
    func testNonErrorStatusesRoundTripPersistence() {
        let statuses: [RecordingStatus] = [.recording, .recorded, .converting, .transcribing, .retranscribing, .done]

        for status in statuses {
            let reconstructed = RecordingStatus(persistedValue: status.persistedValue, errorMessage: nil)
            #expect(reconstructed == status)
        }
    }

    
    
    @Test
    func testErrorStatusRoundTripsWithMessage() {
        let status = RecordingStatus.error("something went wrong")
        let reconstructed = RecordingStatus(
            persistedValue: status.persistedValue,
            errorMessage: "something went wrong"
        )

        #expect(reconstructed == .error("something went wrong"))
    }

    
    
    @Test
    func testUnknownPersistedValueFallsBackToRecorded() {
        #expect(
            RecordingStatus(persistedValue: "unknown", errorMessage: nil)
            == .recorded
        )
    }

    
    
    @Test
    func testRecordingSessionStoresCapturedAppNameWhenProvided() {
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 10,
            micAudioURL: "/tmp/audio.wav",
            title: "Session",
            capturedAppName: "Zoom",
            status: .recorded
        )

        #expect(session.capturedAppName == "Zoom")
    }

    
    
    @Test
    func testRecordingSessionCapturedAppNameDefaultsToNil() {
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 10,
            micAudioURL: "/tmp/audio.wav",
            title: "Session",
            status: .recorded
        )

        #expect(session.capturedAppName == nil)
    }

    
    
    @Test
    func testRecordingSessionStoresAppAudioURLWhenProvided() {
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 10,
            micAudioURL: "/tmp/mic.wav",
            appAudioURL: "/tmp/app.wav",
            title: "Session",
            status: .recorded
        )

        #expect(session.micAudioURL == "/tmp/mic.wav")
        #expect(session.appAudioURL == "/tmp/app.wav")
    }

    
    
    @Test
    func testRecordingSessionAppAudioURLDefaultsToNil() {
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 10,
            micAudioURL: "/tmp/mic.wav",
            title: "Session",
            status: .recorded
        )

        #expect(session.micAudioURL == "/tmp/mic.wav")
        #expect(session.appAudioURL == nil)
    }

    
    
    @Test
    func testRecordingSessionStoresMixdownURLWhenProvided() {
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 10,
            micAudioURL: "/tmp/mic.wav",
            mixdownURL: "/tmp/recording.m4a",
            title: "Session",
            status: .recorded
        )

        #expect(session.mixdownURL == "/tmp/recording.m4a")
    }

    
    
    @Test
    func testRecordingSessionMixdownURLDefaultsToNil() {
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 10,
            micAudioURL: "/tmp/mic.wav",
            title: "Session",
            status: .recorded
        )

        #expect(session.mixdownURL == nil)
    }

    @Test
    func testRecordingStatusRecordingPersistsAndRoundTripsInSwiftData() throws {
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 5,
            micAudioURL: "/tmp/mic.wav",
            title: "S",
            status: .recording
        )
        context.insert(session)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<RecordingSession>())
        #expect(fetched.first?.status == .recording)
        #expect(fetched.first?.statusRawValue == "recording")
    }

    @Test
    func testRecordingSessionRowShowsPulsingDotForRecordingStatus() throws {
        let source = try sourceForFile(named: "RecordingSessionRow.swift")
        #expect(source.contains("case .recording:"))
        #expect(source.contains("Circle()"))
        #expect(source.contains(".fill(Color(\"StatusRecordingColor\"))"))
        #expect(source.contains("isPulsing"))
    }

    // MARK: - Interrupted-capture marker

    @Test
    func testRecordingSessionRowShowsTheInterruptedCaptureMarker() throws {
        let source = try sourceForFile(named: "RecordingSessionRow.swift")
        #expect(source.contains("session.wasCaptureInterrupted"))
        #expect(source.contains("Capture was interrupted and resumed"))
        #expect(source.contains("exclamationmark.triangle.fill"))
    }

    /// An interrupted recording succeeded and its audio is usable, so it must not borrow the
    /// `.error` treatment.
    @Test
    func testInterruptedCaptureIsNotShownAsAnError() throws {
        let source = try sourceForFile(named: "RecordingSessionRow.swift")
        let markerRange = try #require(source.range(of: "session.wasCaptureInterrupted"))
        let block = source[markerRange.lowerBound...].prefix(400)
        #expect(!block.contains("xmark"))
        #expect(!block.contains(".red"))
    }

    /// The screen-capture warning and the interrupted-capture marker are independent conditions;
    /// a recording that hit both shows both rather than one replacing the other.
    @Test
    func testBothCaptureCaveatsCanAppearTogether() throws {
        let source = try sourceForFile(named: "RecordingSessionRow.swift")
        let screenWarning = try #require(source.range(of: "session.screenCaptureWarning != nil"))
        let interrupted = try #require(source.range(of: "session.wasCaptureInterrupted"))
        #expect(screenWarning.upperBound < interrupted.lowerBound)
        // Separate `if` conditions, not an `else if` chain.
        let between = String(source[screenWarning.upperBound..<interrupted.lowerBound])
        #expect(!between.contains("else"))
    }

    // MARK: - Tag dots

    @Test
    func testRecordingRowShowsTagDotsInsteadOfASourceGlyph() throws {
        let source = try sourceForFile(named: "RecordingSessionRow.swift")
        #expect(source.contains("tagDots"))
        #expect(source.contains("TagDotsView"))
        // The glyph is removed, not hidden behind a branch that a minimum of one tag makes dead.
        #expect(!source.contains("sourceGlyph"))
        #expect(!source.contains("mic.fill"))
        #expect(!source.contains("app.fill"))
    }

    /// The source is not lost — it is already caption text on the line below.
    @Test
    func testRecordingRowStillNamesItsSource() throws {
        let source = try sourceForFile(named: "RecordingSessionRow.swift")
        #expect(source.contains("Text(sourceName)"))
        #expect(source.contains("capturedAppName ?? \"Microphone\""))
    }

    @Test
    func testImportedRowKeepsItsSourceGlyph() throws {
        let source = try sourceForFile(named: "ImportedSessionRow.swift")
        #expect(source.contains("sourceGlyph"))
    }

    @Test
    func testAtMostThreeDotsAreShown() throws {
        let source = try sourceForFile(named: "RecordingSessionRow.swift")
        // A recording cannot carry more than three, but the row must not depend on that holding.
        #expect(source.contains("prefix(3)"))
    }

    @Test
    func testTagDotsArrangeOneTwoAndThree() throws {
        let source = try sourceForFile(named: "TagDotsView.swift")
        #expect(source.contains("case 1:"))
        #expect(source.contains("case 2:"))
        #expect(source.contains("VStack"))
        #expect(source.contains("HStack"))
        #expect(source.contains("alignment: .center"))
    }

    @Test
    func testTagColourFallsBackRatherThanRenderingNothing() {
        // An unparseable hex must not make a dot invisible.
        #expect(TagColor.components(fromHex: "zzzzzz") == nil)
        let fallback = TagColor.components(fromHex: RecordingTag.Defaults.colorHex)
        #expect(fallback != nil)
    }

    // MARK: - Incomplete-capture marker

    @Test
    func testRecordingSessionRowShowsTheIncompleteCaptureMarker() throws {
        let source = try sourceForFile(named: "RecordingSessionRow.swift")
        #expect(source.contains("session.hasIncompleteCapturedAudio"))
        #expect(source.contains("Recorded, but some segments may be missing"))
    }

    /// A recording with missing segments still succeeded, so it must not borrow the error look.
    @Test
    func testIncompleteCaptureIsNotShownAsAnError() throws {
        let source = try sourceForFile(named: "RecordingSessionRow.swift")
        let markerRange = try #require(source.range(of: "session.hasIncompleteCapturedAudio"))
        let block = source[markerRange.lowerBound...].prefix(400)
        #expect(!block.contains("xmark"))
        #expect(!block.contains(".red"))
    }

    /// All four capture caveats are independent conditions, shown together rather than one
    /// replacing another.
    @Test
    func testAllCaptureCaveatsCanAppearTogether() throws {
        let source = try sourceForFile(named: "RecordingSessionRow.swift")
        let screen = try #require(source.range(of: "session.screenCaptureWarning != nil"))
        let interrupted = try #require(source.range(of: "session.wasCaptureInterrupted"))
        let incomplete = try #require(source.range(of: "session.hasIncompleteCapturedAudio"))
        #expect(screen.upperBound < interrupted.lowerBound)
        #expect(interrupted.upperBound < incomplete.lowerBound)
        let between = String(source[interrupted.upperBound..<incomplete.lowerBound])
        #expect(!between.contains("else"))
    }

    @Test
    func testIncompleteCaptureMarkerCoversBothConditions() {
        let session = RecordingSession(duration: 600, micAudioURL: "/tmp/a.wav", title: "t")
        #expect(!session.hasIncompleteCapturedAudio)

        session.partiallyCoveredSources = ["app"]
        #expect(session.hasIncompleteCapturedAudio)

        session.partiallyCoveredSources = nil
        session.captureWriteFailureCount = 2
        #expect(session.hasIncompleteCapturedAudio)

        session.captureWriteFailureCount = nil
        #expect(!session.hasIncompleteCapturedAudio)
    }

    @Test
    func testEmptyPartiallyCoveredListIsNotAMarker() {
        let session = RecordingSession(duration: 600, micAudioURL: "/tmp/a.wav", title: "t")
        session.partiallyCoveredSources = []
        #expect(!session.hasPartiallyCoveredSource)
        #expect(!session.hasIncompleteCapturedAudio)
    }

    @Test
    func testInterruptedCaptureMarkerIsDrivenByThePersistedCount() {
        let session = RecordingSession(duration: 10, micAudioURL: "/tmp/a.wav", title: "t")
        #expect(!session.wasCaptureInterrupted)

        session.captureInterruptionCount = 1
        #expect(session.wasCaptureInterrupted)

        session.captureInterruptionCount = nil
        #expect(!session.wasCaptureInterrupted)
    }

    private func sourceForFile(named fileName: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileURL = testsDirectory.appendingPathComponent("../UI/\(fileName)")
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    @Test
    func testRecordingSessionMixdownAttemptCountDefaultsToZero() {
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 10,
            micAudioURL: "/tmp/mic.wav",
            title: "Session",
            status: .recording
        )

        #expect(session.mixdownAttemptCount == 0)
    }

    @Test
    func testRecordingSessionStoresProvidedMixdownAttemptCount() {
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 10,
            micAudioURL: "/tmp/mic.wav",
            title: "Session",
            status: .recorded,
            mixdownAttemptCount: 3
        )

        #expect(session.mixdownAttemptCount == 3)
    }

    
    
    @Test
    func testRecordingSessionRetranscriptRoundTripsWithoutAffectingOriginalTranscript() {
        let original = Transcript(
            fullText: "original",
            segments: [
                TranscriptSegment(
                    speakerId: "S1",
                    text: "original",
                    startTime: 0,
                    endTime: 1,
                    audioSource: .mic
                )
            ],
            speakers: [TranscriptSpeaker(id: "S1", label: "Speaker 1", colorHex: "#111111")]
        )
        let retranscript = Transcript(
            fullText: "retry",
            segments: [
                TranscriptSegment(
                    speakerId: "S2",
                    text: "retry",
                    startTime: 0,
                    endTime: 1,
                    audioSource: .mic
                )
            ],
            speakers: [TranscriptSpeaker(id: "S2", label: "Speaker 2", colorHex: "#222222")]
        )
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 10,
            micAudioURL: "/tmp/mic.wav",
            title: "Session",
            status: .recorded
        )

        session.transcript = original
        session.retranscript = retranscript

        #expect(session.transcript?.fullText == "original")
        #expect(session.retranscript?.fullText == "retry")
        #expect(session.transcriptData != nil)
        #expect(session.retranscriptData != nil)
    }

    @MainActor
    
    
    @Test
    func testTranscriptDetailViewModelPrefersRetranscript() {
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 10,
            micAudioURL: "/tmp/mic.wav",
            appAudioURL: "/tmp/app.wav",
            mixdownURL: "/tmp/recording.m4a",
            title: "Session",
            status: .done
        )
        session.transcript = Transcript(
            fullText: "original",
            segments: [TranscriptSegment(speakerId: "S1", text: "original", startTime: 0, endTime: 1, audioSource: .mic)],
            speakers: [TranscriptSpeaker(id: "S1", label: "Speaker", colorHex: "#111111")]
        )
        session.retranscript = Transcript(
            fullText: "retry",
            segments: [TranscriptSegment(speakerId: "app:S1", text: "retry", startTime: 0, endTime: 1, audioSource: .app)],
            speakers: [TranscriptSpeaker(id: "app:S1", label: "Speaker", colorHex: "#222222")]
        )

        let viewModel = TranscriptDetailViewModel(session: session, aiProviderService: makeAIProviderService())
        #expect(viewModel.displayedTranscript?.fullText == "retry")
        #expect(viewModel.finalTranscriptText == "retry")
        #expect(viewModel.originalTranscriptText == "original")
        #expect(viewModel.isReprocessed)
    }

    @MainActor
    
    
    @Test
    func testTranscriptDetailViewModelApplicationNameAndReprocessedFlag() {
        let recording = TranscriptDetailViewModel(session: RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 10,
            micAudioURL: "/tmp/mic.wav",
            title: "Session",
            capturedAppName: "Zoom",
            status: .done
        ), aiProviderService: makeAIProviderService())
        #expect(recording.applicationName == "Zoom")
        #expect(!(recording.isReprocessed))

        let imported = TranscriptDetailViewModel(session: ImportedSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 4,
            mixdownURL: "/tmp/mix.m4a",
            title: "Imported",
            originalFileName: "sample.wav",
            originalFormat: "wav",
            status: .done
        ), aiProviderService: makeAIProviderService())
        #expect(imported.applicationName == nil)
    }

    @MainActor
    private func makeAIProviderService() -> AIProviderService {
        let defaults = UserDefaults(suiteName: "RecordingStatusTests.\(UUID().uuidString)") ?? .standard
        let keychainStore = MockKeychainStore()
        return AIProviderService(
            keychainStore: keychainStore,
            store: AIProviderStore(defaults: defaults)
        )
    }
}

struct RecordingSessionTests {
    
    
    @Test
    func testRecordingSessionAITransformationHistoryRoundTrips() {
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 42,
            micAudioURL: "/tmp/mic.wav",
            title: "Demo",
            status: .done
        )
        let transformations = [
            AITransformation(
                promptName: "Summary",
                modelID: "gpt-5.2",
                resultText: "Short summary",
                createdAt: Date(timeIntervalSince1970: 100)
            ),
            AITransformation(
                promptName: "Action Items",
                modelID: "gpt-5.2",
                resultText: "1. Follow up",
                createdAt: Date(timeIntervalSince1970: 200)
            )
        ]

        session.aiTransformations = transformations

        #expect(session.aiTransformations == transformations)
        #expect(session.aiTransformationsData != nil)
    }

    
    
    @Test
    func testImportedSessionAITransformationHistoryRoundTrips() {
        let session = ImportedSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 12,
            mixdownURL: "/tmp/mix.m4a",
            title: "Imported",
            originalFileName: "sample.wav",
            originalFormat: "wav",
            status: .done
        )
        let transformations = [
            AITransformation(
                promptName: "Summary",
                modelID: "gpt-5.2",
                resultText: "Imported summary",
                createdAt: Date(timeIntervalSince1970: 300)
            )
        ]

        session.aiTransformations = transformations

        #expect(session.aiTransformations == transformations)
        #expect(session.aiTransformationsData != nil)
    }

    
    
    @Test
    func testTranscriptDetailViewIncludesAITransformationUIElements() throws {
        let source = try transcriptDetailSource()

        #expect(source.contains("Label(\"Transform\", systemImage: \"sparkles\")"))
        #expect(source.contains("await viewModel.runTransformation()"))
        #expect(source.contains("AITransformationPreviewCard("))
        #expect(source.contains("SkeletonView()"))
        #expect(source.contains("Add prompts in Settings"))
        #expect(source.contains("shouldWarnAboutTranscriptLength"))
        #expect(source.contains("NSPasteboard.general"))
        #expect(source.contains("latestTransformation.resultText"))
        #expect(!source.contains("Picker(\"Prompt\""))
        #expect(!source.contains("MetadataCell("))
    }

    
    
    @Test
    func testAITransformationPreviewCardIncludesCopyButtonContract() throws {
        let source = try sourceForFile(named: "AITransformationPreviewCard.swift")

        #expect(source.contains("let onCopy: () -> Void"))
        #expect(source.contains("Label(\"Copy\", systemImage: \"doc.on.doc\")"))
        #expect(source.contains(".buttonStyle(.plain)"))
        #expect(source.contains(".labelStyle(.iconOnly)"))
    }

    
    
    @Test
    func testTranscriptDetailViewIncludesPreviewAndStudyNavigation() throws {
        let source = try transcriptDetailSource()

        #expect(source.contains("TranscriptPreviewView("))
        #expect(source.contains("onTap: viewModel.displayedTranscript == nil ? nil : onOpenStudy"))
        #expect(!(source.contains("Label(\"Study Transcript\", systemImage: \"book.pages\")")))
        #expect(!(source.contains(".sheet(isPresented: $showingStudyTranscript)")))
    }

    
    
    @Test
    func testTranscriptConversationViewsUseAdaptiveStylesForLightDarkMode() throws {
        let blockSource = try sourceForFile(named: "TranscriptBlockView.swift")
        let previewSource = try sourceForFile(named: "TranscriptPreviewView.swift")
        let studySource = try sourceForFile(named: "TranscriptStudyView.swift")

        #expect(blockSource.contains(".background(.thinMaterial"))
        #expect(blockSource.contains(".foregroundStyle(.primary)"))
        #expect(!(blockSource.contains("Color.white")))
        #expect(!(blockSource.contains("Color.black")))

        #expect(previewSource.contains(".background(.thinMaterial"))
        #expect(studySource.contains(".background(.bar)"))
    }

    private func transcriptDetailSource() throws -> String {
        try sourceForFile(named: "TranscriptDetailView.swift")
    }

    private func sourceForFile(named fileName: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileURL = testsDirectory.appendingPathComponent("../UI/\(fileName)")
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
