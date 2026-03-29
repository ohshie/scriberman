import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    private let workspaceService: WorkspaceService
    private let modelInstallService: ModelInstallService
    let speakerEmbeddingStore: SpeakerEmbeddingStore

    @Published var workspacePathText: String = "Not configured"
    @Published var workspaceStatusText: String = "Select a workspace to enable model installs."

    @Published var modelStates: [ModelGroup: ModelGroupReadinessState] = [:]
    @Published var modelStatusMessages: [ModelGroup: String] = [:]
    @Published var modelDownloadProgress: [ModelGroup: Double] = [:]
    @Published var canDownloadModels = false

    @Published var speakerThreshold: Double {
        didSet { UserDefaults.standard.set(speakerThreshold, forKey: "speakerThreshold") }
    }
    @Published var minSilenceGap: Double {
        didSet { UserDefaults.standard.set(minSilenceGap, forKey: "minSilenceGap") }
    }

    init(workspaceService: WorkspaceService, modelInstallService: ModelInstallService, speakerEmbeddingStore: SpeakerEmbeddingStore) {
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
        case .downloading, .installing:
            return "Installing"
        case .error:
            return "Error"
        }
    }

    func downloadTapped(for group: ModelGroup) async {
        guard canDownloadModels else {
            modelStates[group] = .error
            modelStatusMessages[group] = "Configure or re-authorize workspace before downloading."
            return
        }

        modelStates[group] = .downloading
        modelStatusMessages[group] = nil

        do {
            _ = try await modelInstallService.installModelGroup(
                group,
                progress: { [weak self] state in
                    Task { @MainActor in
                        self?.modelStates[group] = state
                    }
                },
                downloadProgress: { [weak self] value in
                    Task { @MainActor in
                        self?.modelDownloadProgress[group] = value
                    }
                }
            )

            modelStates[group] = .ready
            modelStatusMessages[group] = nil
            modelDownloadProgress[group] = nil
        } catch {
            modelStates[group] = .error
            modelStatusMessages[group] = error.localizedDescription
            modelDownloadProgress[group] = nil
        }
    }
}
