import CoreGraphics
import Foundation
import SwiftData

/// The status, capture-options, start and stop routes. Every start and stop goes through the
/// capture coordinator; after one, the session is requested in the window as the menu-bar
/// commands do.
@MainActor
final class ExtensionAPIRecording {
    private let coordinator: CaptureCoordinator
    private let audioDeviceService: any AudioDeviceServiceProtocol
    private let appAudioService: any AppAudioServiceProtocol
    private let screenCaptureService: any ScreenCaptureServiceProtocol
    private let permissionService: PermissionServiceProtocol
    private let menuBarSettings: MenuBarSettings
    private let context: ModelContext
    private let requestSession: @MainActor (AppState.SessionRequest) -> Void
    private let saveContext: @MainActor (ModelContext) throws -> Void
    private let tagService = TagService()

    init(
        coordinator: CaptureCoordinator,
        audioDeviceService: any AudioDeviceServiceProtocol,
        appAudioService: any AppAudioServiceProtocol,
        screenCaptureService: any ScreenCaptureServiceProtocol,
        permissionService: PermissionServiceProtocol,
        menuBarSettings: MenuBarSettings,
        context: ModelContext,
        requestSession: @escaping @MainActor (AppState.SessionRequest) -> Void,
        saveContext: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.coordinator = coordinator
        self.audioDeviceService = audioDeviceService
        self.appAudioService = appAudioService
        self.screenCaptureService = screenCaptureService
        self.permissionService = permissionService
        self.menuBarSettings = menuBarSettings
        self.context = context
        self.requestSession = requestSession
        self.saveContext = saveContext
    }

    // MARK: - Routes

    func status() -> HTTPResponse {
        let current = coordinator.current
        let session = current.flatMap { try? RecordingSession.fetch(id: $0.id, in: context) }
        return ExtensionAPIHandler.json(StatusBody(
            state: Self.stateName(coordinator.phase),
            session: session.map(SessionBody.init),
            capture: session == nil ? nil : current.map { CaptureBody($0.capture) }
        ))
    }

    func captureOptions() async -> HTTPResponse {
        audioDeviceService.refreshDevices()
        appAudioService.refreshRunningApps()
        if permissionService.screenRecordingStatus == .granted {
            await screenCaptureService.refreshAvailableDisplays()
        }
        let tags = (try? tagService.assignableTags(in: context)) ?? []
        return ExtensionAPIHandler.json(CaptureOptionsBody(
            microphones: audioDeviceService.availableDevices.map { .init(uid: $0.uid, name: $0.name) },
            apps: appAudioService.runningApps.map { .init(bundleId: $0.bundleID, name: $0.name) },
            displays: screenCaptureService.availableDisplays.map { .init(id: $0.displayID, name: $0.name) },
            tags: tags.map(TagBody.init),
            lastUsedMicrophoneUid: menuBarSettings.lastUsedMicUID,
            lastUsedAppBundleId: menuBarSettings.lastUsedAppBundleID
        ))
    }

    func quickStart() async -> HTTPResponse {
        started(await coordinator.quickStart(origin: .api, context: context))
    }

    func start(body: Data) async -> HTTPResponse {
        let choice: CaptureChoice
        switch makeChoice(from: body) {
        case .success(let made):
            choice = made
        case .failure(let refusal):
            return refusal.response
        }
        return started(await coordinator.start(choice, origin: .api, context: context))
    }

    func stop() async -> HTTPResponse {
        guard coordinator.phase != .idle, let session = await coordinator.stop(context: context) else {
            return ExtensionAPIHandler.error(.notRecording, status: 409)
        }
        requestSession(.recording(session.id))
        return ExtensionAPIHandler.json(StopBody(session: SessionBody(session)))
    }

    // MARK: - Update

    private struct UpdateRequest: Decodable {
        let title: String?
        let tagIds: [String]?
    }

    /// `PATCH /v1/recordings/current`: renames the session being recorded and adds tags to it, all
    /// or nothing. Every tag is checked before anything changes; title and tags are saved together
    /// through the recording view's title path, which leaves `transcript.md` to the stop, and a
    /// failed save is rolled back. Not registered with undo.
    func updateCurrent(body: Data) -> HTTPResponse {
        guard let request = try? JSONDecoder().decode(UpdateRequest.self, from: body),
              request.title != nil || request.tagIds != nil
        else {
            return ExtensionAPIHandler.error(.invalidRequest, status: 400)
        }
        if let title = request.title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ExtensionAPIHandler.error(.invalidRequest, status: 400)
        }
        guard coordinator.phase == .recording, let current = coordinator.current else {
            return ExtensionAPIHandler.error(.notRecording, status: 409)
        }
        // Fetched now, so a session deleted since the request began is not found.
        guard let session = try? RecordingSession.fetch(id: current.id, in: context) else {
            return ExtensionAPIHandler.error(.notFound, status: 404)
        }

        let realTags = session.tags.filter { !$0.isDefault }
        let tagIDs: [UUID]
        switch validatedTags(request.tagIds ?? [], alongside: realTags.map(\.id)) {
        case .success(let ids):
            tagIDs = ids
        case .failure(let refusal):
            return refusal.response
        }
        let added = tagIDs.filter { id in !realTags.contains { $0.id == id } }
        if !added.isEmpty {
            let newTags = added.compactMap { id in
                try? context.fetch(FetchDescriptor<RecordingTag>(predicate: #Predicate { $0.id == id })).first
            }
            // As `TagService.assign` does, a chosen tag displaces the default.
            session.tags = realTags + newTags
        }

        let result = TranscriptDetailViewModel.saveTitle(
            request.title ?? session.title,
            of: session,
            context: context,
            saveContext: saveContext
        )
        guard result == .saved else {
            return ExtensionAPIHandler.error(.saveFailed, status: 500)
        }
        return ExtensionAPIHandler.json(UpdateBody(session: SessionBody(session)))
    }

    // MARK: - Start

    private struct StartRequest: Decodable {
        let title: String?
        let microphoneUid: String?
        let appBundleId: String?
        let screen: Bool?
        let displayId: CGDirectDisplayID?
        let tagIds: [String]?
    }

    private struct Refusal: Error {
        let response: HTTPResponse

        init(_ code: ExtensionAPIErrorCode, status: Int = 400) {
            response = ExtensionAPIHandler.error(code, status: status)
        }
    }

    /// The capture choice a start body asks for, checked against what Scriberman lists now and
    /// against the tag rules, so an invalid choice is refused before any capture begins.
    private func makeChoice(from body: Data) -> Result<CaptureChoice, Refusal> {
        guard let request = try? JSONDecoder().decode(StartRequest.self, from: body) else {
            return .failure(Refusal(.invalidRequest))
        }

        var microphone: AudioInputDevice?
        if let uid = request.microphoneUid {
            audioDeviceService.refreshDevices()
            guard let found = audioDeviceService.availableDevices.first(where: { $0.uid == uid }) else {
                return .failure(Refusal(.invalidRequest))
            }
            microphone = found
        }

        var app: CapturedApp?
        if let bundleID = request.appBundleId {
            appAudioService.refreshRunningApps()
            guard let found = appAudioService.runningApps.first(where: { $0.bundleID == bundleID }) else {
                return .failure(Refusal(.invalidRequest))
            }
            app = found
        }

        var displayID: CGDirectDisplayID?
        if request.screen == true {
            guard let id = request.displayId,
                  screenCaptureService.availableDisplays.contains(where: { $0.displayID == id })
            else {
                return .failure(Refusal(.invalidRequest))
            }
            displayID = id
        }

        let tagIDs: [UUID]
        switch validatedTags(request.tagIds ?? []) {
        case .success(let ids):
            tagIDs = ids
        case .failure(let refusal):
            return .failure(refusal)
        }

        let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .success(CaptureChoice(
            title: title.isEmpty ? CaptureCoordinator.quickStartTitle : title,
            microphone: microphone,
            app: app,
            displayID: displayID,
            tagIDs: tagIDs
        ))
    }

    /// The distinct tag ids `texts` names, each an existing assignable tag, refused when together
    /// with `existing` they come to more than a recording may carry.
    private func validatedTags(_ texts: [String], alongside existing: [UUID] = []) -> Result<[UUID], Refusal> {
        var ids: [UUID] = []
        for text in texts {
            guard let id = UUID(uuidString: text) else {
                return .failure(Refusal(.invalidRequest))
            }
            if !ids.contains(id) {
                ids.append(id)
            }
        }
        for id in ids {
            let descriptor = FetchDescriptor<RecordingTag>(predicate: #Predicate { $0.id == id })
            guard let tag = try? context.fetch(descriptor).first else {
                return .failure(Refusal(.unknownTag))
            }
            guard !tag.isDefault else {
                return .failure(Refusal(.tagNotAssignable))
            }
        }
        guard Set(existing).union(ids).count <= TagService.maximumTagsPerRecording else {
            return .failure(Refusal(.tooManyTags))
        }
        return .success(ids)
    }

    private func started(_ result: Result<CaptureStart, CaptureCoordinator.StartError>) -> HTTPResponse {
        switch result {
        case .success(let started):
            requestSession(.recording(started.session.id))
            return ExtensionAPIHandler.json(StartBody(
                session: SessionBody(started.session),
                capture: CaptureBody(started.capture)
            ))
        case .failure(.alreadyRecording):
            return ExtensionAPIHandler.error(.alreadyRecording, status: 409)
        case .failure(.workspaceUnavailable):
            return ExtensionAPIHandler.error(.workspaceUnavailable, status: 409)
        case .failure(.permissionMissing):
            return ExtensionAPIHandler.error(.permissionMissing, status: 409)
        case .failure(.modelsMissing):
            return ExtensionAPIHandler.error(.modelsMissing, status: 409)
        case .failure(.notStarted):
            return ExtensionAPIHandler.error(.captureFailed, status: 500)
        }
    }

    // MARK: - Bodies

    private static func stateName(_ phase: CaptureCoordinator.Phase) -> String {
        switch phase {
        case .idle: "idle"
        case .starting: "starting"
        case .recording: "recording"
        case .stopping: "stopping"
        }
    }

    private struct TagBody: Encodable {
        let id: String
        let name: String

        init(_ tag: RecordingTag) {
            id = tag.id.uuidString
            name = tag.name
        }
    }

    private struct SessionBody: Encodable {
        let id: String
        let title: String
        let startedAt: String
        let tags: [TagBody]

        init(_ session: RecordingSession) {
            id = "recording:\(session.id.uuidString)"
            title = session.title
            startedAt = ISO8601DateFormatter().string(from: session.createdAt)
            tags = session.tags
                .filter { !$0.isDefault }
                .sorted { $0.createdAt < $1.createdAt }
                .map(TagBody.init)
        }
    }

    private struct CaptureBody: Encodable {
        let microphoneUid: String?
        let appBundleId: String?
        let displayId: CGDirectDisplayID?

        init(_ sources: CaptureSources) {
            microphoneUid = sources.microphoneUID
            appBundleId = sources.appBundleID
            displayId = sources.displayID
        }

        // Absent sources are sent as null rather than left out.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(microphoneUid, forKey: .microphoneUid)
            try container.encode(appBundleId, forKey: .appBundleId)
            try container.encode(displayId, forKey: .displayId)
        }

        private enum CodingKeys: String, CodingKey {
            case microphoneUid, appBundleId, displayId
        }
    }

    private struct StatusBody: Encodable {
        let state: String
        let session: SessionBody?
        let capture: CaptureBody?

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(state, forKey: .state)
            try container.encode(session, forKey: .session)
            try container.encode(capture, forKey: .capture)
        }

        private enum CodingKeys: String, CodingKey {
            case state, session, capture
        }
    }

    private struct StartBody: Encodable {
        let session: SessionBody
        let capture: CaptureBody
    }

    private struct StopBody: Encodable {
        let session: SessionBody
    }

    private struct UpdateBody: Encodable {
        let session: SessionBody
    }

    private struct CaptureOptionsBody: Encodable {
        struct Microphone: Encodable {
            let uid: String
            let name: String
        }

        struct App: Encodable {
            let bundleId: String
            let name: String
        }

        struct Display: Encodable {
            let id: CGDirectDisplayID
            let name: String
        }

        let microphones: [Microphone]
        let apps: [App]
        let displays: [Display]
        let tags: [TagBody]
        let lastUsedMicrophoneUid: String?
        let lastUsedAppBundleId: String?

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(microphones, forKey: .microphones)
            try container.encode(apps, forKey: .apps)
            try container.encode(displays, forKey: .displays)
            try container.encode(tags, forKey: .tags)
            try container.encode(lastUsedMicrophoneUid, forKey: .lastUsedMicrophoneUid)
            try container.encode(lastUsedAppBundleId, forKey: .lastUsedAppBundleId)
        }

        private enum CodingKeys: String, CodingKey {
            case microphones, apps, displays, tags, lastUsedMicrophoneUid, lastUsedAppBundleId
        }
    }
}
