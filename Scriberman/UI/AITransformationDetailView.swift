import AppKit
import MarkdownUI
import SwiftUI

struct AITransformationDetailView: View {
    @State private var transformations: [AITransformation]
    @State private var selectedID: UUID
    @State private var isEditing = false
    @State private var editText = ""

    init(transformations: [AITransformation], initialTransformationID: UUID) {
        _transformations = State(initialValue: transformations)
        _selectedID = State(initialValue: initialTransformationID)
    }

    private var selectedTransformation: AITransformation? {
        transformations.first(where: { $0.id == selectedID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if transformations.count > 1 {
                Picker("History", selection: $selectedID) {
                    ForEach(transformations) { transformation in
                        Text(transformation.historyLabel).tag(transformation.id)
                    }
                }
            }

            if isEditing {
                TextEditor(text: $editText)
                    .font(.body)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Markdown(selectedTransformation?.resultText ?? "")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 420)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    copyCurrentTransformation()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }

                if isEditing {
                    Button("Cancel") {
                        isEditing = false
                    }

                    Button("Done") {
                        saveEdit()
                    }
                } else {
                    Button("Edit") {
                        beginEditing()
                    }
                    .disabled(selectedTransformation == nil)
                }
            }
        }
        .onChange(of: selectedID) { _, _ in
            if isEditing {
                editText = selectedTransformation?.resultText ?? ""
            }
        }
    }

    private func beginEditing() {
        editText = selectedTransformation?.resultText ?? ""
        isEditing = true
    }

    private func saveEdit() {
        guard let index = transformations.firstIndex(where: { $0.id == selectedID }) else {
            isEditing = false
            return
        }

        transformations[index].resultText = editText
        isEditing = false
    }

    private func copyCurrentTransformation() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selectedTransformation?.resultText ?? "", forType: .string)
    }
}

private extension AITransformation {
    var historyLabel: String {
        "\(promptName) - \(formattedTime)"
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }
}
