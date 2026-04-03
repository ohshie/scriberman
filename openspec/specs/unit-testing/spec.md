## ADDED Requirements

### Requirement: A unit test target exists and runs
The app MUST have a `ScribermanTests` Xcode test target that builds and runs against the main app target using `@testable import Scriberman`. All tests MUST be written using Swift Testing (`import Testing`). XCTest SHALL NOT be used.

#### Scenario: Tests run in Xcode
- **WHEN** a developer runs the test suite in Xcode (Cmd+U)
- **THEN** all tests in `ScribermanTests` are discovered and executed with no build errors

#### Scenario: No XCTest imports remain
- **WHEN** any file in `ScribermanTests` is inspected
- **THEN** it contains `import Testing` and does NOT contain `import XCTest`

### Requirement: TimeFormatter is covered by unit tests
`TimeFormatter.format(seconds:)` SHALL be tested for all formatting branches.

#### Scenario: Sub-hour duration formats as MM:SS
- **WHEN** `TimeFormatter.format(seconds: 90)` is called
- **THEN** the result is `"01:30"`

#### Scenario: Zero seconds formats as 00:00
- **WHEN** `TimeFormatter.format(seconds: 0)` is called
- **THEN** the result is `"00:00"`

#### Scenario: Hour-or-more duration formats as HH:MM:SS
- **WHEN** `TimeFormatter.format(seconds: 3661)` is called
- **THEN** the result is `"01:01:01"`

#### Scenario: Negative input is treated as zero
- **WHEN** `TimeFormatter.format(seconds: -5)` is called
- **THEN** the result is `"00:00"`

### Requirement: RecordingStatus round-trips through persistence
`RecordingStatus` SHALL correctly encode to and decode from its persisted string representation.

#### Scenario: All non-error statuses round-trip
- **WHEN** `RecordingStatus.recorded`, `.transcribing`, and `.done` are converted via `persistedValue` then reconstructed via `init(persistedValue:errorMessage:)`
- **THEN** the reconstructed value equals the original

#### Scenario: Error status round-trips with message
- **WHEN** `RecordingStatus.error("something went wrong")` is persisted and reconstructed
- **THEN** the reconstructed value is `.error("something went wrong")`

#### Scenario: Unknown persisted value defaults to recorded
- **WHEN** `RecordingStatus(persistedValue: "unknown", errorMessage: nil)` is called
- **THEN** the result is `.recorded`

### Requirement: TokenStitcher is covered by unit tests
`TokenStitcher` SHALL be tested for its token normalization and stitching logic.

#### Scenario: Sentencepiece prefix is removed
- **WHEN** `TokenStitcher.normalize(tokenPiece: "▁hello")` is called
- **THEN** the result is `" hello"`

#### Scenario: Tokens are joined and whitespace-normalized
- **WHEN** `TokenStitcher.stitch(["▁hello", "▁world"])` is called
- **THEN** the result is `"hello world"` (leading space trimmed, single space between words)

#### Scenario: Punctuation is not preceded by space
- **WHEN** `TokenStitcher.stitch(["▁hello", ",", "▁world"])` is called
- **THEN** the result is `"hello, world"`

#### Scenario: Contractions are handled
- **WHEN** `TokenStitcher.stitch(["▁it", "▁'", "s"])` is called
- **THEN** the result is `"it's"`

#### Scenario: Empty token list returns empty string
- **WHEN** `TokenStitcher.stitch([])` is called
- **THEN** the result is `""`

### Requirement: TranscriptAligner is covered by unit tests
`TranscriptAligner` SHALL be tested for its three alignment branches.

#### Scenario: Tokens and diarized segments produce aligned transcript
- **WHEN** tokens with time ranges overlap a speaker segment
- **THEN** `TranscriptAligner.align(...)` returns a segment with the correct speaker ID and stitched text

#### Scenario: No tokens and no diarized segments produce single fallback segment
- **WHEN** `tokenTimings` is empty and `diarizedSegments` is empty and `fullText` is non-empty
- **THEN** the result contains one segment with `speakerId: "S1"` and the full text

#### Scenario: No tokens with diarized segments produces single segment from first speaker
- **WHEN** `tokenTimings` is empty and `diarizedSegments` is non-empty
- **THEN** the result contains one segment attributed to the first diarized speaker

#### Scenario: Segments with no overlapping tokens are dropped
- **WHEN** a diarized segment's time range has no overlapping tokens
- **THEN** that segment is absent from the result

#### Scenario: Speaker colors are assigned in palette order
- **WHEN** a transcript has two speakers
- **THEN** the first speaker gets `#4F46E5` and the second gets `#16A34A`

### Requirement: MarkdownRenderer is covered by unit tests
`MarkdownRenderer` SHALL be tested for its markdown output and filename sanitization.

#### Scenario: Rendered markdown contains session title as H1
- **WHEN** `MarkdownRenderer.render(session:transcript:)` is called
- **THEN** the output starts with `# <session title>`

#### Scenario: Rendered markdown contains speaker labels and time ranges
- **WHEN** a transcript has segments with known speakers and time ranges
- **THEN** each segment appears as `**Speaker N** [MM:SS – MM:SS]` followed by its text

#### Scenario: Segments are sorted by start time
- **WHEN** transcript segments are provided out of order
- **THEN** the rendered markdown lists them in ascending `startTime` order

#### Scenario: Default filename sanitizes forward slashes
- **WHEN** `MarkdownRenderer.defaultFileName(for: "Recording 03/27")` is called
- **THEN** the result is `"Recording 03-27.md"`

#### Scenario: Default filename uses fallback for empty title
- **WHEN** `MarkdownRenderer.defaultFileName(for: "")` is called
- **THEN** the result is `"Transcript.md"`

### Requirement: StudioViewModel state machine is covered by unit tests
`StudioViewModel` SHALL be tested for its state transitions using mock service implementations.

#### Scenario: Successful start recording transitions to recording state
- **WHEN** `startRecording()` is called and the mock recording service succeeds
- **THEN** `recordingState` becomes `.recording(duration: 0, level: 0)`

#### Scenario: Failed start recording sets error message and stays idle
- **WHEN** `startRecording()` is called and the mock recording service throws
- **THEN** `recordingState` remains `.idle` and `errorMessage` is non-nil

#### Scenario: Stop recording transitions to stopped state
- **WHEN** `stopRecording()` is called and the mock returns a session
- **THEN** `recordingState` becomes `.stopped(session:, ctaSecondsRemaining: 15)`

#### Scenario: Consume CTA returns session and resets to idle
- **WHEN** `consumeSessionForTranscribeCTA()` is called while in `.stopped` state
- **THEN** the returned value is the stopped session and `recordingState` becomes `.idle`

#### Scenario: Clear CTA only acts on stopped state
- **WHEN** `clearStoppedCTAIfNeeded()` is called while in `.idle` state
- **THEN** `recordingState` remains `.idle`

### Requirement: JobsViewModel state transitions are covered by unit tests
`JobsViewModel` SHALL be tested for session status changes using in-memory SwiftData.

#### Scenario: Retry resets error session to recorded
- **WHEN** `retry(session:context:)` is called on a session with `.error` status
- **THEN** the session status becomes `.recorded` and `errorMessage` is nil

#### Scenario: Transcribe is skipped for non-recorded sessions
- **WHEN** `transcribe(session:context:)` is called on a session with `.done` status
- **THEN** the session status remains `.done` (no state change)

### Requirement: Unit tests are required for new code
All new services, extracted logic types, and ViewModels introduced after this change SHALL have corresponding unit tests in `ScribermanTests` using Swift Testing. Tests MUST pass before a feature branch is merged.

#### Scenario: New logic type is added without tests
- **WHEN** a new pure logic type (e.g., a formatter or transformer) is added to the codebase
- **THEN** a corresponding test file MUST exist in `ScribermanTests` covering its core scenarios using Swift Testing macros (`#expect`, `#require`)

#### Scenario: New ViewModel is added without tests
- **WHEN** a new ViewModel is introduced
- **THEN** a corresponding test file MUST exist in `ScribermanTests` covering its state machine or core logic using Swift Testing
