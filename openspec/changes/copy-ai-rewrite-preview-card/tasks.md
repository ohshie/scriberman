## 1. Update AITransformationPreviewCard

- [x] 1.1 Add `onCopy: () -> Void` parameter to `AITransformationPreviewCard`
- [x] 1.2 Restructure the card header as an `HStack` with the prompt name text and a trailing `doc.on.doc` copy button
- [x] 1.3 Wire the copy button to call `onCopy` using `buttonStyle(.plain)` and `.labelStyle(.iconOnly)`

## 2. Update TranscriptDetailView

- [x] 2.1 Pass an `onCopy` closure to `AITransformationPreviewCard` that writes `latestTransformation.resultText` to `NSPasteboard.general`
