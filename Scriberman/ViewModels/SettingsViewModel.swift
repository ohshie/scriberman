import Foundation
import Observation

enum BundleInstallPhase: Equatable {
    case idle
    case allReady
    case downloading(label: String, progress: Double)
    case warmingUp
    case error(String)
}

@MainActor
@Observable
final class SettingsViewModel {
    private let workspaceService: any WorkspaceServiceProtocol
    private let modelInstallService: any ModelInstallServicing
    let speakerEmbeddingStore: SpeakerEmbeddingStore

    var workspacePathText: String = "Not configured"
    var workspaceStatusText: String = "Select a workspace to enable model installs."

    var modelStates: [ModelGroup: ModelGroupReadinessState] = [:]
    var modelStatusMessages: [ModelGroup: String] = [:]
    var bundlePhase: BundleInstallPhase = .idle
    var canDownloadModels = false

    var speakerThreshold: Double {
        didSet { UserDefaults.standard.set(speakerThreshold, forKey: "speakerThreshold") }
    }
    var minSilenceGap: Double {
        didSet { UserDefaults.standard.set(minSilenceGap, forKey: "minSilenceGap") }
    }

    init(workspaceService: any WorkspaceServiceProtocol, modelInstallService: any ModelInstallServicing, speakerEmbeddingStore: SpeakerEmbeddingStore) {
        self.workspaceService = workspaceService
        self.modelInstallService = modelInstallService
        self.speakerEmbeddingStore = speakerEmbeddingStore

        let threshold = UserDefaults.standard.double(forKey: "speakerThreshold")
        self.speakerThreshold = threshold == 0 ? 0.65 : threshold

        let gap = UserDefaults.standard.double(forKey: "minSilenceGap")
        self.minSilenceGap = gap == 0 ? 0.5 : gap

        ModelGroup.allCases.forEach { group in
            modelStates[group] = .missing
        }
    }

    func refresh() async {
        let workspaceValue = await workspaceService.currentWorkspace()
        canDownloadModels = await modelInstallService.canInstallModels()

        if let workspaceValue {
            workspacePathText = workspaceValue.rootURL.path
            workspaceStatusText = "Workspace is configured and accessible."
        } else {
            workspacePathText = "Not configured"
            workspaceStatusText = "Select a workspace to enable model installs."
        }

        for group in ModelGroup.allCases {
            modelStates[group] = await modelInstallService.state(for: group)
            if modelStates[group] != .error {
                modelStatusMessages[group] = nil
            }
        }

        guard !Self.isInProgress(bundlePhase) else {
            return
        }

        bundlePhase = modelStates.values.allSatisfy { $0 == .ready } ? .allReady : .idle
    }

    var currentModelNameText: String {
        ModelGroup.asrParakeetV3.title
    }

    var currentModelStatusText: String {
        switch modelStates[.asrParakeetV3] ?? .missing {
        case .ready:
            return "Installed"
        case .missing:
            return "Not selected"
        case .downloading:
            return "Installing"
        case .error:
            return "Error"
        }
    }

    func downloadAllTapped() async {
        guard canDownloadModels else {
            bundlePhase = .error("Configure or re-authorize workspace before downloading.")
            return
        }

        modelStatusMessages = [:]

        let groupsInOrder: [(group: ModelGroup, label: String, start: Double)] = [
            (.asrParakeetV3, "Downloading ASR…", 0.0),
            (.vadSilero, "Downloading VAD…", 0.8 / 3.0),
            (.offlineDiarization, "Downloading Diarizer…", (0.8 / 3.0) * 2.0)
        ]
        let segmentWidth = 0.8 / 3.0
        var activeGroup: ModelGroup?

        do {
            for item in groupsInOrder {
                let group = item.group
                activeGroup = group
                bundlePhase = .downloading(label: item.label, progress: item.start)
                modelStates[group] = .downloading

                _ = try await modelInstallService.installModelGroup(
                    group,
                    progress: { [weak self] state in
                        Task { @MainActor in
                            self?.modelStates[group] = state
                        }
                    },
                    downloadProgress: { [weak self] value in
                        Task { @MainActor in
                            let clamped = min(max(value, 0.0), 1.0)
                            let progress = min(item.start + (clamped * segmentWidth), 0.8)
                            self?.bundlePhase = .downloading(label: item.label, progress: progress)
                        }
                    }
                )

                modelStates[group] = .ready
                modelStatusMessages[group] = nil
            }
            activeGroup = nil

            if let workspace = await workspaceService.currentWorkspace() {
                bundlePhase = .warmingUp
                await modelInstallService.warmUpModels(workspace: workspace)
            }

            bundlePhase = .allReady
        } catch {
            if let activeGroup {
                modelStates[activeGroup] = .error
                modelStatusMessages[activeGroup] = error.localizedDescription
            }
            bundlePhase = .error(error.localizedDescription)
        }
    }

    private static func isInProgress(_ phase: BundleInstallPhase) -> Bool {
        switch phase {
        case .downloading, .warmingUp:
            return true
        default:
            return false
        }
    }
}
