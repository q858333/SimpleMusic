import Foundation

struct DownloadJob: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        case queued
        case downloading
        case success
        case failure
        case cancelled
        case interrupted
    }

    enum FailureReason: String, Codable {
        case unsupportedURL
        case invalidPayload
        case cellularDisabled
        case generic
        case recovery
    }

    let id: UUID
    let sourceURL: URL
    var displayName: String
    var state: State
    var progress: Double
    let createdAt: Date
    var attempt: UInt64
    var failureReason: FailureReason?
    var reservedFileName: String?
}
