import SwiftUI

struct TranscriptSegmentRow: View {
    let speakerLabel: String
    let segment: TranscriptSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(speakerLabel) [\(TimeFormatter.format(seconds: segment.startTime)) – \(TimeFormatter.format(seconds: segment.endTime))]")
                .font(.subheadline)
                .fontWeight(.semibold)
            Text(segment.text)
                .font(.body)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 4)
    }
}
