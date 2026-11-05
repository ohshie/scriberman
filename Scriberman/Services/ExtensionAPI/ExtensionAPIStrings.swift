import Foundation

/// User-facing text for the extension API: the Settings section, the pairing prompt and the
/// error messages. Generated for ticket 13 by a Haiku subagent on the maintainer's instruction
/// and used as produced.
enum ExtensionAPIStrings {
    // MARK: - Settings

    static let sectionTitle = "Local API"
    static let enableToggle = "Enable local API"
    static let enableHelp = "Allows Tinycast and other local apps on this Mac to control Scriberman. Only paired programs can connect."
    static let portLabel = "Port"

    static func portHelp(min: Int, max: Int) -> String {
        "Enter a number from \(min) to \(max). The default is 47615."
    }

    static func portInvalid(min: Int, max: Int) -> String {
        "Enter a number from \(min) to \(max)."
    }

    static func listening(port: Int) -> String {
        "Listening on 127.0.0.1 port \(port)."
    }

    static let off = "API is off."
    static let starting = "Starting the API."

    static func portInUse(port: Int) -> String {
        "Port \(port) is already used by another program."
    }

    static func bindFailed(port: Int, detail: String) -> String {
        "Could not start on port \(port). \(detail)"
    }

    static let pairedClientsTitle = "Paired Clients"
    static let noClients = "No clients are paired."

    static func pairedOn(_ date: String) -> String {
        "Paired on \(date)."
    }

    static let signingIdentifierLabel = "Signing identifier"
    static let teamLabel = "Team identifier"
    static let noTeam = "No team"
    static let pairAgainNotice = "Paired with an older version of Scriberman. Remove it and pair it again to use it."
    static let revokeButton = "Remove"

    // MARK: - Pairing prompt

    static let pairingTitle = "Pairing request"

    static func claimedName(_ name: String) -> String {
        "Client name: \(name). This name is the client's own claim and is not verified."
    }

    static let approveButton = "Allow"
    static let denyButton = "Deny"

    // MARK: - Errors

    /// For an AI provider failure that came without a description.
    static let providerFailed = "The AI provider returned an error."
}

extension ExtensionAPIErrorCode {
    /// The `message` sent with this code.
    var message: String {
        switch self {
        case .invalidRequest: "The request is malformed."
        case .notFoundRoute: "No such API route exists."
        case .unsupportedVersion: "The API version in the path is not supported."
        case .forbiddenHost: "The Host header must be the local address."
        case .forbiddenOrigin: "Requests from web pages are not allowed."
        case .unauthorized: "The client is not paired, its pairing was removed, or the signing headers are missing."
        case .badSignature: "The request signature or body hash does not match."
        case .staleRequest: "The request timestamp is too far from the Scriberman clock."
        case .replayedRequest: "This request was already used."
        case .forbiddenCaller: "The calling program's code signature is not accepted or does not match the one recorded at pairing."
        case .payloadTooLarge: "The upload is too large. The limit is 1 GiB."
        case .insufficientDiskSpace: "There is not enough free disk space to import this file."
        case .pairingBusy: "Another pairing request is already waiting for approval."
        case .pairingDenied: "The pairing was denied or ended because the API was turned off."
        case .pairingExpired: "The pairing request expired before it was answered."
        case .alreadyRecording: "A recording is already in progress."
        case .notRecording: "No recording is in progress."
        case .workspaceUnavailable: "The Scriberman workspace folder is not set up or cannot be accessed."
        case .modelsMissing: "The transcription models are not installed."
        case .permissionMissing: "A required macOS permission for the microphone or screen and audio capture is not granted."
        case .eventUnavailable: "This calendar event is no longer available as a suggestion."
        case .notFound: "The session, prompt, transformation or operation was not found."
        case .unknownTag: "A tag in the request does not exist."
        case .tagNotAssignable: "A tag in the request cannot be assigned to sessions."
        case .tooManyTags: "The request assigns more tags than a session can have."
        case .noTranscript: "The session has no transcript yet."
        case .aiNotConfigured: "No AI provider is set up in Scriberman."
        case .transformationRunning: "An AI prompt is already running on this session."
        case .notAudio: "The uploaded file is not an audio file that Scriberman can import."
        case .invalidFileName: "The file name of the upload is not valid."
        case .importNotRecorded: "The file was received, but the import could not be recorded."
        case .captureFailed: "Recording could not start for another reason."
        case .saveFailed: "Scriberman could not save the change. Nothing was changed."
        }
    }
}
