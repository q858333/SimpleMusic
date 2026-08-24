import Foundation

extension Notification.Name {
    static let apnsDeviceTokenDidChange = Notification.Name("SimpleMusic.apnsDeviceTokenDidChange")
}

/// 保存当前进程收到的最新 APNs Token，并通知需要同步后端的调用方。
/// APNs Token 可能变化，因此不写入钥匙串或 UserDefaults。
@MainActor
final class APNsTokenStore {
    static let shared = APNsTokenStore()
    static let tokenUserInfoKey = "token"

    private let notificationCenter: NotificationCenter
    private(set) var currentToken: String?

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    @discardableResult
    func update(deviceToken: Data) -> String {
        // APNs Token 长度不是固定值，逐字节转换可保留前导零。
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        currentToken = token
        notificationCenter.post(
            name: .apnsDeviceTokenDidChange,
            object: self,
            userInfo: [Self.tokenUserInfoKey: token]
        )
        return token
    }
}
