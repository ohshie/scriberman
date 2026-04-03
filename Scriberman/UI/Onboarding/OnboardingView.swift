import AppKit
import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @State private var displayedStep: OnboardingStep = .screenRecording

    private let stepTransition = AnyTransition.asymmetric(
        insertion: .move(edge: .trailing),
        removal: .move(edge: .leading)
    )

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                stepDots
                    .padding(.top, 24)

                ZStack {
                    stepView(for: displayedStep)
                        .id(displayedStep)
                        .transition(stepTransition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 16)

            Divider()

            HStack {
                Button("Quit Scriberman") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: [.command])

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .interactiveDismissDisabled(true)
        .onAppear {
            syncDisplayedStep(required: appState.requiredOnboardingStep, animate: false)
        }
        .onChange(of: appState.requiredOnboardingStep) { _, newValue in
            syncDisplayedStep(required: newValue, animate: true)
        }
    }

    private var stepDots: some View {
        HStack(spacing: 10) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                dot(for: step)
            }
        }
    }

    @ViewBuilder
    private func dot(for step: OnboardingStep) -> some View {
        let currentIndex = displayedStep.rawValue
        let stepIndex = step.rawValue

        if stepIndex < currentIndex {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 10, height: 10)
        } else if stepIndex == currentIndex {
            Circle()
                .stroke(Color.accentColor, lineWidth: 2)
                .frame(width: 10, height: 10)
                .background(
                    Circle()
                        .fill(Color.accentColor.opacity(0.2))
                        .frame(width: 6, height: 6)
                )
        } else {
            Circle()
                .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                .frame(width: 10, height: 10)
                .opacity(0.8)
        }
    }

    @ViewBuilder
    private func stepView(for step: OnboardingStep) -> some View {
        switch step {
        case .screenRecording:
            ScreenRecordingOnboardingStep {
                syncDisplayedStep(required: appState.requiredOnboardingStep, animate: true)
            }
        case .microphone:
            MicrophoneOnboardingStep {
                syncDisplayedStep(required: appState.requiredOnboardingStep, animate: true)
            }
        case .workspace:
            WorkspaceOnboardingStep {
                syncDisplayedStep(required: appState.requiredOnboardingStep, animate: true)
            }
        case .models:
            ModelsOnboardingStep {
                syncDisplayedStep(required: appState.requiredOnboardingStep, animate: true)
            }
        }
    }

    private func syncDisplayedStep(required: OnboardingStep?, animate: Bool) {
        guard let required else {
            return
        }

        let shouldAnimateForward = animate && required.rawValue > displayedStep.rawValue
        if shouldAnimateForward {
            withAnimation(.easeInOut(duration: 0.22)) {
                displayedStep = required
            }
        } else {
            displayedStep = required
        }
    }
}
