import Foundation

@MainActor
final class AppState: ObservableObject {
    let services: ServiceContainer
    let studioViewModel: StudioViewModel
    let jobsViewModel: JobsViewModel
    let settingsViewModel: SettingsViewModel

    init(services: ServiceContainer = .live()) {
        self.services = services
        self.studioViewModel = StudioViewModel(workspaceService: services.workspaceService)
        self.jobsViewModel = JobsViewModel(workspaceService: services.workspaceService)
        self.settingsViewModel = SettingsViewModel(
            workspaceService: services.workspaceService,
            modelInstallService: services.modelInstallService
        )
    }
}
