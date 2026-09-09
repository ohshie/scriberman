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

    // MARK: - Tag assignment menu

    private func jobsViewSource() throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try String(
            contentsOf: testsDirectory.appendingPathComponent("../UI/JobsView.swift"),
            encoding: .utf8
        )
    }

    @Test
    func testTheListOffersTagAssignmentOnRightClick() throws {
        let source = try jobsViewSource()
        #expect(source.contains(".contextMenu"))
        #expect(source.contains("tagMenu(for: item)"))
    }

    /// Only recordings carry tags. An empty `contextMenu` body shows no menu, which is what pending
    /// and imported rows should do.
    @Test
    func testOnlyRecordingRowsProduceATagMenu() throws {
        let source = try jobsViewSource()
        // Bounded to this function. A fixed-width window would spill into `deleteButton`, which
        // legitimately switches over every case.
        let menuRange = try #require(source.range(of: "private func tagMenu(for item"))
        let rest = source[menuRange.upperBound...]
        let end = rest.range(of: "private func ")?.lowerBound ?? rest.endIndex
        let body = rest[..<end]
        #expect(body.contains("if case .recording(let session) = item"))
        #expect(!body.contains("case .imported"))
        #expect(!body.contains("case .pending"))
    }

    private func assignmentMenuSource() throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try String(
            contentsOf: testsDirectory.appendingPathComponent("../UI/TagAssignmentMenu.swift"),
            encoding: .utf8
        )
    }

    @Test
    func testTheDefaultTagIsNotListedForAssignment() throws {
        let source = try assignmentMenuSource()
        // `assignableTags` excludes it; the menu does not filter separately.
        #expect(source.contains("assignableTags(in: modelContext)"))
    }

    @Test
    func testAtThreeTagsFurtherTagsAreDisabledRatherThanHidden() throws {
        let source = try assignmentMenuSource()
        #expect(source.contains(".disabled(!isCarried && realCount >= TagService.maximumTagsPerRecording)"))
        // Disabled, not filtered out of the list.
        #expect(!source.contains("assignable.filter"))
    }

    @Test
    func testCarriedTagsAreMarkedAndToggleBothWays() throws {
        let source = try assignmentMenuSource()
        #expect(source.contains("systemImage: \"checkmark\""))
        #expect(source.contains("try service.unassign(tag, from: session, in: modelContext)"))
        #expect(source.contains("try service.assign(tag, to: session, in: modelContext)"))
    }

    /// The list and the detail toolbar share one menu body, so they cannot drift on which tags are
    /// offered or when they are unavailable.
    @Test
    func testTheListAndTheDetailToolbarShareOneAssignmentMenu() throws {
        let jobs = try jobsViewSource()
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let detail = try String(
            contentsOf: testsDirectory.appendingPathComponent("../UI/TranscriptDetailView.swift"),
            encoding: .utf8
        )
        #expect(jobs.contains("TagAssignmentMenuContent(session: session)"))
        #expect(detail.contains("TagAssignmentMenuContent(session: recording)"))
    }

    /// Tags are a session action, so the control sits with Transform and Delete.
    @Test
    func testTheDetailToolbarCarriesATagsControl() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let detail = try String(
            contentsOf: testsDirectory.appendingPathComponent("../UI/TranscriptDetailView.swift"),
            encoding: .utf8
        )
        #expect(detail.contains("Label(\"Tags\", systemImage: \"tag\")"))
        // Only recordings carry tags; an imported session shows no control.
        #expect(detail.contains("if let recording = session as? RecordingSession"))
    }

    /// The chips must survive a filter that matches nothing. They used to live inside the branch
    /// that the empty state replaces, so filtering to zero removed the only way to unfilter.
    @Test
    func testFilterChipsRenderOutsideTheEmptyStateBranch() throws {
        let source = try jobsViewSource()
        let chipsRange = try #require(source.range(of: "tagFilterChips"))
        let emptyStateRange = try #require(source.range(of: "if items.isEmpty && pendingSession == nil"))
        // Chips are placed before the branch, not inside its else.
        #expect(chipsRange.lowerBound < emptyStateRange.lowerBound)
        #expect(!source.contains("private var listContent"))
    }

    /// A recording carrying only the default tag has nothing assignable, so without this the menu
    /// is empty and looks broken.
    @Test
    func testTheAssignmentMenuIsNeverEmpty() throws {
        let source = try assignmentMenuSource()
        #expect(source.contains("Button(\"Add new tag\")"))
        #expect(source.contains("openSettings()"))
        // Outside the ForEach, so it is present whatever the tag list contains.
        let forEachRange = try #require(source.range(of: "ForEach(assignable)"))
        let buttonRange = try #require(source.range(of: "Button(\"Add new tag\")"))
        #expect(buttonRange.lowerBound > forEachRange.lowerBound)
    }

    @Test
    func testTheNameFieldLosesFocusOnAClickElsewhere() throws {
        let source = try tagSettingsSourceForRow()
        #expect(source.contains("@FocusState private var focusedTagID"))
        #expect(source.contains(".focused($focusedTagID, equals: tag.id)"))
        #expect(source.contains("focusedTagID = nil"))
    }

    private func tagSettingsSourceForRow() throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try String(
            contentsOf: testsDirectory.appendingPathComponent("../UI/TagSettingsView.swift"),
            encoding: .utf8
        )
    }

    // MARK: - Named tags in the row

    private func tagLineSource() throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try String(
            contentsOf: testsDirectory.appendingPathComponent("../UI/SessionTagLineView.swift"),
            encoding: .utf8
        )
    }

    @Test
    func testTagsAreNamedNotJustColoured() throws {
        let source = try tagLineSource()
        #expect(source.contains("Text(tag.name)"))
        #expect(source.contains("Circle()"))
    }

    /// Without a backdrop the chip sits directly on the list's selection fill and a tag coloured
    /// near the accent disappears into it. A `List` gives no way to cut its selection around a
    /// subview, so the chip has to be drawn over it.
    @Test
    func testEachTagChipHasItsOwnBackdrop() throws {
        let source = try tagLineSource()
        #expect(source.contains("glassEffect(.regular, in: Capsule())"))
        #expect(source.contains(".tint(Color(tagHex: tag.colorHex))"))
    }

    /// Tag colours are random and user-chosen, so some would be unreadable as text. Colour stays in
    /// the dot and the tint.
    @Test
    func testTheTagNameIsNotDrawnInTheTagColour() throws {
        let source = try tagLineSource()
        let nameRange = try #require(source.range(of: "Text(tag.name)"))
        let rest = source[nameRange.upperBound...].prefix(160)
        #expect(!rest.contains("foregroundStyle(Color(tagHex"))
    }

    @Test
    func testTheDefaultTagIsNeverNamed() throws {
        let source = try tagLineSource()
        #expect(source.contains("tags.filter { !$0.isDefault }"))
    }

    @Test
    func testAnUntaggedRecordingShowsNoTagLine() throws {
        let source = try tagLineSource()
        // The whole line is conditional on there being a named tag.
        #expect(source.contains("if !namedTags.isEmpty"))
    }

    @Test
    func testNamesTruncateInOrderRatherThanWrapping() throws {
        let source = try tagLineSource()
        #expect(source.contains("lineLimit(1)"))
        #expect(source.contains("truncationMode(.tail)"))
        // Earlier tags outrank later ones, so the first keeps its name longest.
        #expect(source.contains("layoutPriority(priority(for: tag))"))
        #expect(source.contains("Double(namedTags.count - index)"))
    }

    /// The chip reads on both backgrounds because of its own backdrop, so the row still never needs
    /// to know whether it is selected.
    @Test
    func testTheChipWorksWithoutKnowingAboutSelection() throws {
        let source = try tagLineSource()
        #expect(!source.contains("isSelected"))
    }

    @Test
    func testTheRowRendersTheTagLine() throws {
        let source = try sourceForFile(named: "RecordingSessionRow.swift")
        #expect(source.contains("SessionTagLineView(tags: session.tags)"))
    }

    @Test
    func testImportedRowsHaveNoTagLine() throws {
        let source = try sourceForFile(named: "ImportedSessionRow.swift")
        #expect(!source.contains("SessionTagLineView"))
    }

    // MARK: - Row layout

    @Test
    func testTheTimestampSharesTheDurationLine() throws {
        for file in ["RecordingSessionRow.swift", "ImportedSessionRow.swift"] {
            let source = try sourceForFile(named: file)
            // The timestamp sits inside the caption HStack, after a Spacer, rather than in a
            // Text of its own below it.
            let captionRange = try #require(source.range(of: "Text(durationText(session.duration))"))
            let rest = source[captionRange.upperBound...]
            let hstackEnd = try #require(rest.range(of: "}"))
            let sameLine = rest[..<hstackEnd.lowerBound]
            #expect(sameLine.contains("Spacer(minLength:"))
            #expect(sameLine.contains("relativeTimestampText(for: session.createdAt)"))
        }
    }

    @Test
    func testTheTimestampOccupiesNoLineOfItsOwn() throws {
        for file in ["RecordingSessionRow.swift", "ImportedSessionRow.swift"] {
            let source = try sourceForFile(named: file)
            // Exactly one reference, and it is the one on the duration line.
            let occurrences = source.components(separatedBy: "relativeTimestampText").count - 1
            #expect(occurrences == 1)
        }
    }

    /// The text column has to fill for a trailing alignment to resolve against anything.
    @Test
    func testTheTextColumnFillsAvailableWidth() throws {
        for file in ["RecordingSessionRow.swift", "ImportedSessionRow.swift"] {
            let source = try sourceForFile(named: file)
            #expect(source.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
            #expect(!source.contains("Spacer(minLength: 12)"))
        }
    }

    // MARK: - Tag dots

    @Test
    func testRecordingRowHasNoLeadingElement() throws {
        let source = try sourceForFile(named: "RecordingSessionRow.swift")
        // No glyph, and no dots either — the 24pt leading column is gone entirely.
        #expect(!source.contains("sourceGlyph"))
        #expect(!source.contains("mic.fill"))
        #expect(!source.contains("app.fill"))
        #expect(!source.contains("tagDots"))
        #expect(!source.contains("TagDotsView"))
    }

    @Test
    func testDoneRowsRenderNoAccessory() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let statusTag = try String(
            contentsOf: testsDirectory.appendingPathComponent("../UI/StatusTagView.swift"),
            encoding: .utf8
        )
        #expect(!statusTag.contains("Image(systemName: \"checkmark\")"))
        // Two done sessions differing only in transcript/AI data cannot render differently, since
        // the view no longer receives either fact.
        #expect(!statusTag.contains("hasTranscript"))
        #expect(!statusTag.contains("hasAITransformation"))
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
