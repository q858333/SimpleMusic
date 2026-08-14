import Foundation

@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()
    private init() {}
}
