import Alamofire
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

struct DeviceRegistrationMetadata {
    let appVersion: String?
    let systemVersion: String?
    let deviceModel: String?
}

enum DeviceRegistrationError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int)
}

struct AppConfiguration: Equatable {
    let downloadsEnabled: Bool
}

enum AppConfigurationError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int)
}

/// 读取 Worker 下发的配置；失败由调用方保留当前配置继续运行。
@MainActor
final class AppConfigurationService {
    typealias RequestExecutor = (URLRequest) async throws -> (Data, URLResponse)

    private struct WorkerResponse: Decodable {
        let success: Bool
        let data: Payload?
    }

    private struct Payload: Decodable {
        let downloadsEnabled: Bool
    }

    private let endpoint: URL
    private let requestExecutor: RequestExecutor

    init(
        endpoint: URL = URL(string: "https://disktoneweb.dengcheez.workers.dev/api/v1/config")!,
        requestExecutor: @escaping RequestExecutor = { request in
            let response = await AF.request(request).serializingData().response
            let data = try response.result.get()
            guard let urlResponse = response.response else {
                throw AppConfigurationError.invalidResponse
            }
            return (data, urlResponse)
        }
    ) {
        self.endpoint = endpoint
        self.requestExecutor = requestExecutor
    }

    func fetch() async throws -> AppConfiguration {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        let (data, response) = try await requestExecutor(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppConfigurationError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AppConfigurationError.httpStatus(httpResponse.statusCode)
        }
        guard
            let payload = try? JSONDecoder().decode(WorkerResponse.self, from: data),
            payload.success,
            let configuration = payload.data
        else {
            throw AppConfigurationError.invalidResponse
        }
        return AppConfiguration(downloadsEnabled: configuration.downloadsEnabled)
    }
}

/// 将本机设备号与可选 APNs Token 上报到 Worker；网络失败由调用方记录，不阻塞启动。
@MainActor
final class DeviceRegistrationService {
    typealias DeviceIdentifierProvider = @MainActor () throws -> String
    typealias MetadataProvider = @MainActor () -> DeviceRegistrationMetadata
    typealias RequestExecutor = (URLRequest) async throws -> (Data, URLResponse)
    typealias RetrySleeper = @MainActor (UInt64) async throws -> Void

    static let shared = DeviceRegistrationService()

    private struct Payload: Encodable {
        let deviceId: String
        let apnsToken: String?
        let apnsEnvironment: String?
        let appVersion: String?
        let systemVersion: String?
        let deviceModel: String?
    }

    private struct WorkerResponse: Decodable {
        let success: Bool
    }

    private let endpoint: URL
    private let deviceIdentifierProvider: DeviceIdentifierProvider
    private let apnsEnvironmentProvider: () -> String
    private let metadataProvider: MetadataProvider
    private let requestExecutor: RequestExecutor
    private let retrySleeper: RetrySleeper

    init(
        endpoint: URL = URL(
            string: "https://disktoneweb.dengcheez.workers.dev/api/v1/devices/register"
        )!,
        deviceIdentifierProvider: @escaping DeviceIdentifierProvider = {
            try DeviceIdentifierService().deviceIdentifier()
        },
        apnsEnvironmentProvider: @escaping () -> String = {
#if DEBUG
            return "development"
#else
            return "production"
#endif
        },
        metadataProvider: @escaping MetadataProvider = {
            DeviceRegistrationMetadata(
                appVersion: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String,
                systemVersion: UIDevice.current.systemVersion,
                deviceModel: UIDevice.current.model
            )
        },
        requestExecutor: @escaping RequestExecutor = { request in
            // 统一使用项目现有的 Alamofire 会话执行设备注册请求。
            let dataResponse = await AF.request(request).serializingData().response
            let data = try dataResponse.result.get()
            guard let response = dataResponse.response else {
                throw DeviceRegistrationError.invalidResponse
            }
            return (data, response)
        },
        retrySleeper: @escaping RetrySleeper = { delay in
            try await Task.sleep(nanoseconds: delay)
        }
    ) {
        self.endpoint = endpoint
        self.deviceIdentifierProvider = deviceIdentifierProvider
        self.apnsEnvironmentProvider = apnsEnvironmentProvider
        self.metadataProvider = metadataProvider
        self.requestExecutor = requestExecutor
        self.retrySleeper = retrySleeper
    }

    /// 首次失败后每隔两秒重试，最多重试三次；最终失败仍交给调用方记录。
    func registerWithRetry(apnsToken: String?) async throws {
        var completedRetryCount = 0
        while true {
            do {
                try await register(apnsToken: apnsToken)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard completedRetryCount < 3 else { throw error }
                completedRetryCount += 1
                try await retrySleeper(2_000_000_000)
            }
        }
    }

    func register(apnsToken: String?) async throws {
        let metadata = metadataProvider()
        let payload = Payload(
            deviceId: try deviceIdentifierProvider(),
            apnsToken: apnsToken,
            // Worker 只允许 Token 与环境成对出现。
            apnsEnvironment: apnsToken == nil ? nil : apnsEnvironmentProvider(),
            appVersion: metadata.appVersion,
            systemVersion: metadata.systemVersion,
            deviceModel: metadata.deviceModel
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await requestExecutor(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeviceRegistrationError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw DeviceRegistrationError.httpStatus(httpResponse.statusCode)
        }
        guard
            let workerResponse = try? JSONDecoder().decode(WorkerResponse.self, from: data),
            workerResponse.success
        else {
            throw DeviceRegistrationError.invalidResponse
        }
    }
}
