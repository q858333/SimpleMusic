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
        delegate.apnsTokenStore = store
        delegate.remoteNotificationRegistrar = { _ in registrationCount += 1 }

        XCTAssertTrue(delegate.application(.shared, didFinishLaunchingWithOptions: nil))
        delegate.application(
            .shared,
            didRegisterForRemoteNotificationsWithDeviceToken: Data([0x01, 0xA2])
        )

        XCTAssertEqual(registrationCount, 1)
        XCTAssertEqual(store.currentToken, "01a2")
    }
}
