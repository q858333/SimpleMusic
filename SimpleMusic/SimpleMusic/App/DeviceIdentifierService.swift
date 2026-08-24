import Foundation
import Security
import UIKit

protocol DeviceIdentifierStoring: AnyObject {
    func loadDeviceIdentifier() throws -> String?
    func saveDeviceIdentifier(_ value: String) throws
}

struct DeviceIdentifierKeychainError: Error {
    let status: OSStatus
}

/// 使用通用密码条目保存设备号；数据只保留在当前设备，不参与 iCloud 钥匙串同步。
final class KeychainDeviceIdentifierStore: DeviceIdentifierStoring {
    private let service: String
    private let account: String

    init(
        service: String = Bundle.main.bundleIdentifier ?? "DB.SimpleMusic",
        account: String = "device_identifier"
    ) {
        self.service = service
        self.account = account
    }

    func loadDeviceIdentifier() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw DeviceIdentifierKeychainError(status: status)
        }
        guard
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8),
            !value.isEmpty
        else {
            throw DeviceIdentifierKeychainError(status: errSecDecode)
        }
        return value
    }

    func saveDeviceIdentifier(_ value: String) throws {
        let data = Data(value.utf8)
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(item as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw DeviceIdentifierKeychainError(status: addStatus)
        }

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard updateStatus == errSecSuccess else {
            throw DeviceIdentifierKeychainError(status: updateStatus)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

/// 第一次取值时缓存 IDFV；以后始终以钥匙串中的设备号为准。
final class DeviceIdentifierService {
    private let storage: any DeviceIdentifierStoring
    private let idfvProvider: () -> UUID?
    private let lock = NSLock()

    init(
        storage: any DeviceIdentifierStoring = KeychainDeviceIdentifierStore(),
        idfvProvider: @escaping () -> UUID? = { UIDevice.current.identifierForVendor }
    ) {
        self.storage = storage
        self.idfvProvider = idfvProvider
    }

    func deviceIdentifier() throws -> String {
        lock.lock()
        defer { lock.unlock() }

        if let cachedValue = try storage.loadDeviceIdentifier() {
            return cachedValue
        }

        // IDFV 极少数情况下可能为空；UUID 兜底仍只生成一次并写入钥匙串。
        let generatedValue = (idfvProvider() ?? UUID()).uuidString
        try storage.saveDeviceIdentifier(generatedValue)
        return generatedValue
    }
}
