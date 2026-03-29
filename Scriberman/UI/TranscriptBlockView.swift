import SwiftUI

struct TranscriptBlockView: View {
    let block: TranscriptBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(speakerColor)
                    .frame(width: 10, height: 10)

                Text(block.speaker.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(speakerColor)

                Text(timeRange)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()

                Image(systemName: block.audioSource == .app ? "speaker.wave.2.fill" : "mic.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(block.text)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var timeRange: String {
        "\(TimeFormatter.formatWithMilliseconds(seconds: block.startTime)) - \(TimeFormatter.formatWithMilliseconds(seconds: block.endTime))"
    }

    private var speakerColor: Color {
        Color(hex: block.speaker.colorHex) ?? .accentColor
    }
}

private extension Color {
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }

        guard value.count == 6, let rgb = Int(value, radix: 16) else {
            return nil
        }

        let red = Double((rgb >> 16) & 0xFF) / 255.0
        let green = Double((rgb >> 8) & 0xFF) / 255.0
        let blue = Double(rgb & 0xFF) / 255.0

        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1.0)
    }
}
