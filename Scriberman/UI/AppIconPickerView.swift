import SwiftUI

/// Side-by-side clickable thumbnails for choosing the app icon.
struct AppIconPickerView: View {
    @Bindable var preferences: AppIconPreferences

    private static let thumbnailSize: CGFloat = 64

    var body: some View {
        HStack(spacing: 16) {
            ForEach(AppIconOption.allCases) { option in
                Button {
                    preferences.selectedIcon = option
                } label: {
                    thumbnail(for: option)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(for: option))
                .accessibilityAddTraits(preferences.selectedIcon == option ? [.isSelected] : [])
            }
        }
    }

    private func thumbnail(for option: AppIconOption) -> some View {
        let isSelected = preferences.selectedIcon == option
        return VStack(spacing: 6) {
            Group {
                if let image = option.image {
                    Image(nsImage: image)
                        .resizable()
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.quaternary)
                }
            }
            .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 3)
            }

            Text(label(for: option))
                .font(.caption)
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .contentShape(Rectangle())
    }

    private func label(for option: AppIconOption) -> String {
        switch option {
        case .classic: return "Classic"
        case .purple: return "Purple"
        }
    }
}
