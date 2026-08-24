import XCTest
@testable import SimpleMusic

final class DeviceIdentifierServiceTests: XCTestCase {
    func testReturnsCachedIdentifierWithoutReadingIDFV() throws {
        let storage = DeviceIdentifierStorageStub(value: "cached-device-id")
        var idfvReadCount = 0
        let service = DeviceIdentifierService(storage: storage) {
            idfvReadCount += 1
            return UUID()
        }

        XCTAssertEqual(try service.deviceIdentifier(), "cached-device-id")
        XCTAssertEqual(idfvReadCount, 0)
        XCTAssertTrue(storage.savedValues.isEmpty)
    }

    func testStoresIDFVAndReusesIt() throws {
        let storage = DeviceIdentifierStorageStub()
        let idfv = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        var idfvReadCount = 0
        let service = DeviceIdentifierService(storage: storage) {
            idfvReadCount += 1
            return idfv
        }

        XCTAssertEqual(try service.deviceIdentifier(), idfv.uuidString)
        XCTAssertEqual(try service.deviceIdentifier(), idfv.uuidString)
        XCTAssertEqual(idfvReadCount, 1)
        XCTAssertEqual(storage.savedValues, [idfv.uuidString])
    }

    func testCachesGeneratedUUIDWhenIDFVIsUnavailable() throws {
        let storage = DeviceIdentifierStorageStub()
        let service = DeviceIdentifierService(storage: storage) { nil }

        let firstValue = try service.deviceIdentifier()
        let secondValue = try service.deviceIdentifier()

        XCTAssertNotNil(UUID(uuidString: firstValue))
        XCTAssertEqual(secondValue, firstValue)
        XCTAssertEqual(storage.savedValues, [firstValue])
    }
}

private final class DeviceIdentifierStorageStub: DeviceIdentifierStoring {
    var value: String?
    private(set) var savedValues = [String]()

    init(value: String? = nil) {
        self.value = value
    }

    func loadDeviceIdentifier() throws -> String? {
        value
    }

    func saveDeviceIdentifier(_ value: String) throws {
        self.value = value
        savedValues.append(value)
    }
}

@MainActor
final class DeviceRegistrationServiceTests: XCTestCase {
    func testRegisterWithoutTokenSendsDeviceMetadataToWorker() async throws {
        let endpoint = URL(string: "https://example.com/api/v1/devices/register")!
        var capturedRequest: URLRequest?
        let service = DeviceRegistrationService(
            endpoint: endpoint,
            deviceIdentifierProvider: { "11111111-2222-3333-4444-555555555555" },
            apnsEnvironmentProvider: { "development" },
            metadataProvider: {
                DeviceRegistrationMetadata(
                    appVersion: "1.2.3",
                    systemVersion: "18.6",
                    deviceModel: "iPhone"
                )
            },
            requestExecutor: { request in
                capturedRequest = request
                return (
                    Data(#"{"success":true,"data":{"deviceId":"11111111-2222-3333-4444-555555555555"}}"#.utf8),
                    HTTPURLResponse(
                        url: endpoint,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )

        try await service.register(apnsToken: nil)

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["deviceId"] as? String, "11111111-2222-3333-4444-555555555555")
        XCTAssertNil(json["apnsToken"])
        XCTAssertNil(json["apnsEnvironment"])
        XCTAssertEqual(json["appVersion"] as? String, "1.2.3")
        XCTAssertEqual(json["systemVersion"] as? String, "18.6")
        XCTAssertEqual(json["deviceModel"] as? String, "iPhone")
    }

    func testRegisterWithTokenIncludesCurrentAPNsEnvironment() async throws {
        let endpoint = URL(string: "https://example.com/api/v1/devices/register")!
        var capturedRequest: URLRequest?
        let service = DeviceRegistrationService(
            endpoint: endpoint,
            deviceIdentifierProvider: { "11111111-2222-3333-4444-555555555555" },
            apnsEnvironmentProvider: { "production" },
            metadataProvider: {
                DeviceRegistrationMetadata(
                    appVersion: "1.2.3",
                    systemVersion: "18.6",
                    deviceModel: "iPad"
                )
            },
            requestExecutor: { request in
                capturedRequest = request
                return (
                    Data(#"{"success":true,"data":{"deviceId":"11111111-2222-3333-4444-555555555555"}}"#.utf8),
                    HTTPURLResponse(
                        url: endpoint,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )

        try await service.register(apnsToken: "01a2ff")

        let body = try XCTUnwrap(capturedRequest?.httpBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["apnsToken"] as? String, "01a2ff")
        XCTAssertEqual(json["apnsEnvironment"] as? String, "production")
    }

    func testRegisterRejectsNonSuccessHTTPResponse() async {
        let endpoint = URL(string: "https://example.com/api/v1/devices/register")!
        let service = DeviceRegistrationService(
            endpoint: endpoint,
            deviceIdentifierProvider: { "11111111-2222-3333-4444-555555555555" },
            apnsEnvironmentProvider: { "development" },
            metadataProvider: {
                DeviceRegistrationMetadata(
                    appVersion: nil,
                    systemVersion: nil,
                    deviceModel: nil
                )
            },
            requestExecutor: { _ in
                (
                    Data(#"{"success":false,"error":{"code":"internal_error"}}"#.utf8),
                    HTTPURLResponse(
                        url: endpoint,
                        statusCode: 500,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )

        do {
            try await service.register(apnsToken: nil)
            XCTFail("Expected registration to reject an HTTP error")
        } catch let error as DeviceRegistrationError {
            XCTAssertEqual(error, .httpStatus(500))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

@MainActor
final class APNsTokenStoreTests: XCTestCase {
    func testConvertsVariableLengthTokenToLowercaseHexAndPublishesChange() {
        let center = NotificationCenter()
        let store = APNsTokenStore(notificationCenter: center)
        var publishedToken: String?
        let observer = center.addObserver(
            forName: .apnsDeviceTokenDidChange,
            object: store,
            queue: nil
        ) { notification in
            publishedToken = notification.userInfo?[APNsTokenStore.tokenUserInfoKey] as? String
        }
        defer { center.removeObserver(observer) }

        let token = store.update(deviceToken: Data([0x00, 0x0A, 0xFF, 0x31, 0x80]))

        XCTAssertEqual(token, "000aff3180")
        XCTAssertEqual(store.currentToken, token)
        XCTAssertEqual(publishedToken, token)
    }

    func testAppDelegateRegistersAtLaunchAndForwardsLatestToken() {
        let delegate = AppDelegate()
        let store = APNsTokenStore(notificationCenter: NotificationCenter())
        var registrationCount = 0
        var uploadedTokens = [String?]()
        delegate.apnsTokenStore = store
        delegate.remoteNotificationRegistrar = { _ in registrationCount += 1 }
        delegate.deviceRegistrationHandler = { token in uploadedTokens.append(token) }

        XCTAssertTrue(delegate.application(.shared, didFinishLaunchingWithOptions: nil))
        delegate.application(
            .shared,
            didRegisterForRemoteNotificationsWithDeviceToken: Data([0x01, 0xA2])
        )

        XCTAssertEqual(registrationCount, 1)
        XCTAssertEqual(store.currentToken, "01a2")
        XCTAssertEqual(uploadedTokens.count, 2)
        XCTAssertNil(uploadedTokens[0])
        XCTAssertEqual(uploadedTokens[1], "01a2")
    }
}
