import Combine
import CoreData
import MediaPlayer
import UIKit
import XCTest
@testable import SimpleMusic

private enum TestStoreError: Error {
    case unavailable
    case failed
}

final class AppCoordinatorTests: XCTestCase {
    /// 如果启动后的过渡页退回 Storyboard 通用控制器，此测试应失败。
    @MainActor
    func testDefaultLaunchRouteUsesDedicatedLaunchViewController() throws {
        let window = UIWindow(frame: .zero)
        let coordinator = AppCoordinator(
            window: window,
            authorizationStatus: { .authorized },
            requestAuthorization: { .authorized },
            rootKind: .phone,
            makeMainViewController: { _ in UIViewController() }
        )

        coordinator.start()

        let launch = try XCTUnwrap(window.rootViewController as? LaunchViewController)
        launch.loadViewIfNeeded()
        let icon = try XCTUnwrap(
            findView(identifier: "launch.icon", in: launch.view) as? UIImageView
        )
        let title = try XCTUnwrap(
            findView(identifier: "launch.title", in: launch.view) as? UILabel
        )
        let subtitle = try XCTUnwrap(
            findView(identifier: "launch.subtitle", in: launch.view) as? UILabel
        )
        let launchRed = UIColor(red: 250 / 255, green: 45 / 255, blue: 72 / 255, alpha: 1)
        let expectedIcon = try XCTUnwrap(UIImage(named: "music-note-white"))

        XCTAssertEqual(launch.view.backgroundColor, launchRed)
        XCTAssertEqual(icon.image?.pngData(), expectedIcon.pngData())
        XCTAssertEqual(title.textColor, .white)
        XCTAssertEqual(subtitle.text, L10n.text("launch.subtitle"))
        XCTAssertEqual(subtitle.textColor, UIColor(white: 1, alpha: 0.85))
        XCTAssertEqual(subtitle.numberOfLines, 1)
    }

    @MainActor
    func testLaunchAgreementRequestsAPNsOnOpenAndDefersDeviceRegistrationUntilAccepting() async throws {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let deviceRegistration = expectation(description: "device registration starts")
        let apnsAuthorization = expectation(description: "APNs authorization starts")
        var deviceRegistrationCount = 0
        var apnsAuthorizationCount = 0
        var routeCount = 0
        var scheduledRoute: (@MainActor () -> Void)?
        let controller = LaunchViewController(
            registerDevice: {
                deviceRegistrationCount += 1
                deviceRegistration.fulfill()
            },
            requestAPNsAuthorization: {
                apnsAuthorizationCount += 1
                apnsAuthorization.fulfill()
            },
            agreementDefaults: defaults,
            onAgreementAccepted: { routeCount += 1 },
            scheduleRoute: { scheduledRoute = $0 }
        )
        controller.loadViewIfNeeded()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()

        XCTAssertNotNil(findView(identifier: "launch.agreement", in: controller.view))
        XCTAssertEqual(deviceRegistrationCount, 0)
        await fulfillment(of: [apnsAuthorization], timeout: 1)
        XCTAssertEqual(apnsAuthorizationCount, 1)
        XCTAssertEqual(routeCount, 0)

        let acceptButton = try XCTUnwrap(
            findView(identifier: "launch.agreement.accept", in: controller.view) as? UIButton
        )
        acceptButton.sendActions(for: .touchUpInside)
        await fulfillment(of: [deviceRegistration], timeout: 1)

        XCTAssertTrue(defaults.bool(forKey: LaunchViewController.agreementAcceptedDefaultsKey))
        XCTAssertEqual(deviceRegistrationCount, 1)
        XCTAssertEqual(apnsAuthorizationCount, 1)
        XCTAssertEqual(routeCount, 0)
        try XCTUnwrap(scheduledRoute)()
        XCTAssertEqual(routeCount, 1)
    }

    @MainActor
    func testAcceptedColdStartRequestsAPNsAndRegistersDeviceBeforeDelayedRoute() async throws {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: LaunchViewController.agreementAcceptedDefaultsKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let deviceRegistration = expectation(description: "device registration starts")
        let apnsAuthorization = expectation(description: "APNs authorization starts")
        var routeCount = 0
        var scheduledRoute: (@MainActor () -> Void)?
        let controller = LaunchViewController(
            registerDevice: { deviceRegistration.fulfill() },
            requestAPNsAuthorization: { apnsAuthorization.fulfill() },
            agreementDefaults: defaults,
            onAgreementAccepted: { routeCount += 1 },
            scheduleRoute: { scheduledRoute = $0 }
        )

        controller.loadViewIfNeeded()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        await fulfillment(of: [apnsAuthorization, deviceRegistration], timeout: 1)

        XCTAssertNil(findView(identifier: "launch.agreement", in: controller.view))
        XCTAssertEqual(routeCount, 0)
        try XCTUnwrap(scheduledRoute)()
        XCTAssertEqual(routeCount, 1)
    }

    @MainActor
    func testCoordinatorKeepsLaunchUntilAgreementAcceptanceThenRoutes() async throws {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let window = UIWindow(frame: .zero)
        let main = UIViewController()
        var scheduledRoute: (@MainActor () -> Void)?
        let launch = LaunchViewController(
            registerDevice: {},
            requestAPNsAuthorization: {},
            agreementDefaults: defaults,
            scheduleRoute: { scheduledRoute = $0 }
        )
        let coordinator = AppCoordinator(
            window: window,
            authorizationStatus: { .authorized },
            requestAuthorization: { .authorized },
            rootKind: .phone,
            makeMainViewController: { _ in main },
            makeLaunchViewController: { launch }
        )

        coordinator.start()

        XCTAssertTrue(window.rootViewController === launch)
        launch.loadViewIfNeeded()
        let acceptButton = try XCTUnwrap(
            findView(identifier: "launch.agreement.accept", in: launch.view) as? UIButton
        )
        acceptButton.sendActions(for: .touchUpInside)
        XCTAssertTrue(window.rootViewController === launch)
        try XCTUnwrap(scheduledRoute)()
        await waitUntil { window.rootViewController === main }

        XCTAssertTrue(window.rootViewController === main)
    }

    func testPersistentStoreFailureFallsBackToMemoryWithoutRemovingOriginalStore() throws {
        let persistent = NSPersistentContainer(name: "SimpleMusic")
        let memory = NSPersistentContainer(name: "SimpleMusic")
        let memoryDescription = NSPersistentStoreDescription()
        memoryDescription.type = NSInMemoryStoreType
        memory.persistentStoreDescriptions = [memoryDescription]
        let originalStore = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("user-store".utf8).write(to: originalStore)
        defer { try? FileManager.default.removeItem(at: originalStore) }
        var loadedContainers = [NSPersistentContainer]()
        let factory = PersistentStoreFactory(
            makePersistentContainer: { persistent },
            makeMemoryContainer: { memory },
            load: { container, completion in
                loadedContainers.append(container)
                completion(container === persistent ? TestStoreError.failed : nil)
            }
        )

        let result = factory.resolve()

        XCTAssertTrue(result.container === memory)
        let warning = try XCTUnwrap(result.warning)
        XCTAssertTrue(warning.contains(L10n.text("storage.persistence.unavailable")))
        XCTAssertTrue(warning.contains("failed"))
        XCTAssertEqual(loadedContainers.count, 2)
        XCTAssertEqual(try Data(contentsOf: originalStore), Data("user-store".utf8))
    }

    func testPersistentStoreWarningJoinsMultipleErrorsWithLanguageNeutralSeparator() throws {
        let persistent = NSPersistentContainer(name: "SimpleMusic")
        let memory = NSPersistentContainer(name: "SimpleMusic")
        let factory = PersistentStoreFactory(
            makePersistentContainer: { persistent },
            makeMemoryContainer: { memory },
            load: { container, completion in
                completion(container === persistent ? TestStoreError.failed : TestStoreError.unavailable)
            }
        )

        let warning = try XCTUnwrap(factory.resolve().warning)

        XCTAssertTrue(warning.contains("failed; unavailable"), warning)
    }

    @MainActor
    func testSaveFailurePostsNotificationInsteadOfCrashing() throws {
        let container = NSPersistentContainer(name: "SimpleMusic")
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }

        let appDelegate = AppDelegate()
        appDelegate.persistentStoreFactory = PersistentStoreFactory(
            makePersistentContainer: { container },
            load: { _, completion in completion(nil) }
        )
        appDelegate.saveContextOperation = { _ in throw TestStoreError.unavailable }
        let center = NotificationCenter()
        appDelegate.appNotificationCenter = center
        var notificationCount = 0
        let token = center.addObserver(
            forName: .persistentStoreSaveDidFail,
            object: appDelegate,
            queue: nil
        ) { _ in notificationCount += 1 }
        defer { center.removeObserver(token) }
        _ = NSEntityDescription.insertNewObject(
            forEntityName: "DownloadedTrackEntity",
            into: appDelegate.persistentContainer.viewContext
        )

        appDelegate.saveContext()

        XCTAssertEqual(notificationCount, 1)
        XCTAssertTrue(appDelegate.persistentContainer.viewContext.hasChanges)
    }

    @MainActor
    func testDownloadRootFailureDisablesOnlyDownloadWithReadableExplanation() throws {
        let resolution = DownloadStorageFactory(
            rootProvider: { throw TestStoreError.unavailable }
        ).resolve()

        XCTAssertNil(resolution.store)
        let warning = try XCTUnwrap(resolution.warning)
        XCTAssertEqual(warning, L10n.text("storage.download.unavailable"))
        let controller = DownloadUnavailableViewController(message: warning)
        controller.loadViewIfNeeded()
        let copy = allViews(in: controller.view)
            .compactMap { ($0 as? UILabel)?.text }
            .joined(separator: " ")

        XCTAssertEqual(copy, L10n.text("storage.download.unavailable"))
        XCTAssertEqual(controller.title, L10n.text("download.unavailable.title"))
    }

    @MainActor
    func testEnvironmentUsesShortDownloadWarningWhenStorageWarningIsNil() async {
        let environment = AppEnvironment(
            downloadStorageResolution: DownloadStorageResolution(store: nil, warning: nil)
        )

        await environment.libraryViewModel.reload()

        XCTAssertEqual(
            environment.libraryViewModel.localState,
            .failed(L10n.text("storage.download.unavailable_short"))
        )
    }

    @MainActor
    func testDependenciesUseShortDownloadWarningWhenStorageWarningIsNil() throws {
        let environment = AppEnvironment(
            downloadStorageResolution: DownloadStorageResolution(store: nil, warning: nil)
        )
        let controller = AppRootDependencies(environment: environment).makeDownloadViewController()
        controller.loadViewIfNeeded()
        let copy = allViews(in: controller.view)
            .compactMap { ($0 as? UILabel)?.text }
            .joined(separator: " ")

        XCTAssertEqual(copy, L10n.text("storage.download.unavailable_short"))
    }

    /// 如果下载工厂重新创建队列，关闭再打开页面会丢失任务和进度。
    @MainActor
    func testPhoneAndPadDownloadFactoriesUseEnvironmentSharedQueue() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleMusic-AppCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let fileStore = try DownloadFileStore(rootURL: rootURL)
        let environment = AppEnvironment(
            downloadStorageResolution: DownloadStorageResolution(store: fileStore, warning: nil)
        )
        let dependencies = AppRootDependencies(environment: environment)

        let first = try XCTUnwrap(dependencies.makeDownloadViewController() as? DownloadSheetViewController)
        let second = try XCTUnwrap(dependencies.makeDownloadViewController() as? DownloadSheetViewController)
        let sharedQueue = try XCTUnwrap(environment.downloadQueue)

        XCTAssertTrue(first.downloadQueue === sharedQueue)
        XCTAssertTrue(second.downloadQueue === sharedQueue)
        XCTAssertTrue(first.downloadQueue === second.downloadQueue)
    }

    /// 如果设备类型映射交换或 iPad 错走手机根界面，此测试应失败。
    @MainActor
    func testRootKindMatchesPhoneAndPadIdioms() {
        XCTAssertEqual(AppCoordinator.rootKind(for: .phone), .phone)
        XCTAssertEqual(AppCoordinator.rootKind(for: .pad), .pad)
    }

    /// 如果默认根工厂忽略注入依赖并回退 AppEnvironment.shared，此测试应失败。
    @MainActor
    func testDefaultRootFactoryKeepsInjectedDependenciesForPhoneAndPad() throws {
        let identity = NSObject()
        let viewModel = LibraryViewModel(
            library: CoordinatorStubMusicLibrary(),
            localStore: CoordinatorStubLocalMusicStore()
        )
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(PlaybackSnapshot())
        let dependencies = AppRootDependencies(
            identity: identity,
            libraryViewModel: viewModel,
            snapshotPublisher: snapshots.eraseToAnyPublisher(),
            onPlay: { _, _ in },
            onTogglePlay: {}
        )
        let factory = AppCoordinator.makeMainViewControllerFactory(dependencies: dependencies)

        let phone = try XCTUnwrap(factory(.phone) as? MainTabBarController)
        phone.loadViewIfNeeded()
        let phoneLibrary = try XCTUnwrap(descendant(LibraryViewController.self, in: phone))
        XCTAssertEqual(phone.dependencyIdentity, ObjectIdentifier(identity))
        XCTAssertTrue(phoneLibrary.viewModel === viewModel)

        let pad = try XCTUnwrap(factory(.pad) as? PadRootViewController)
        pad.loadViewIfNeeded()
        let padLibrary = try XCTUnwrap(descendant(LibraryViewController.self, in: pad))
        XCTAssertEqual(pad.dependencyIdentity, ObjectIdentifier(identity))
        XCTAssertTrue(padLibrary.viewModel === viewModel)
    }

    /// 如果根工厂没有把真实删除入口同时交给资料库和搜索，本地“更多”确认后仍会成为空操作。
    @MainActor
    func testDefaultRootFactoryWiresLocalDeletionIntoLibraryAndSearch() throws {
        let track = MusicTrack(
            id: "downloaded",
            title: "本地歌曲",
            artist: "艺人",
            album: "专辑",
            duration: 10,
            artworkData: nil,
            source: .downloaded(fileName: "downloaded.m4a")
        )

        for kind in [AppRootKind.phone, .pad] {
            let viewModel = LibraryViewModel(
                library: CoordinatorStubMusicLibrary(),
                localStore: CoordinatorStubLocalMusicStore()
            )
            var deletedIDs = [String]()
            let dependencies = AppRootDependencies(
                identity: NSObject(),
                libraryViewModel: viewModel,
                snapshotPublisher: Empty<PlaybackSnapshot, Never>().eraseToAnyPublisher(),
                onPlay: { _, _ in },
                onDeleteTrack: { deletedIDs.append($0.id) },
                onTogglePlay: {}
            )
            let root = AppCoordinator.makeMainViewControllerFactory(dependencies: dependencies)(kind)
            root.loadViewIfNeeded()
            let library = try XCTUnwrap(descendant(LibraryViewController.self, in: root))
            library.onDeleteTrack?(track)

            if kind == .pad {
                let searchButton = try XCTUnwrap(
                    findView(identifier: "pad.search", in: root.view) as? UIButton
                )
                searchButton.sendActions(for: .touchUpInside)
            }
            let search = try XCTUnwrap(descendant(SearchViewController.self, in: root))
            search.onDeleteTrack?(track)

            XCTAssertEqual(deletedIDs, [track.id, track.id], "root=\(kind)")
        }
    }

    /// 如果已同意协议的冷启动跳过品牌页，或一秒延迟完成后没有恢复原权限分流，此测试应失败。
    @MainActor
    func testAcceptedColdStartKeepsLaunchVisibleUntilDelayedRouteThenRoutes() throws {
        for status in [
            MPMediaLibraryAuthorizationStatus.notDetermined,
            .authorized
        ] {
            let window = UIWindow(frame: .zero)
            let suiteName = UUID().uuidString
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.set(true, forKey: LaunchViewController.agreementAcceptedDefaultsKey)
            defer { defaults.removePersistentDomain(forName: suiteName) }
            var scheduledRoute: (@MainActor () -> Void)?
            let launch = LaunchViewController(
                registerDevice: {},
                requestAPNsAuthorization: {},
                agreementDefaults: defaults,
                scheduleRoute: { scheduledRoute = $0 }
            )
            let main = UIViewController()
            var mainCount = 0
            let coordinator = AppCoordinator(
                window: window,
                authorizationStatus: { status },
                requestAuthorization: { status },
                rootKind: .phone,
                makeMainViewController: { _ in
                    mainCount += 1
                    return main
                },
                makeLaunchViewController: { launch }
            )

            coordinator.start()

            XCTAssertTrue(window.rootViewController === launch, "status=\(status.rawValue)")
            XCTAssertEqual(mainCount, 0, "status=\(status.rawValue)")
            launch.loadViewIfNeeded()
            launch.viewDidAppear(false)
            try XCTUnwrap(scheduledRoute)()

            if status == .notDetermined {
                XCTAssertTrue(window.rootViewController is PermissionViewController)
            } else {
                XCTAssertTrue(window.rootViewController === main)
            }
        }
    }

    /// 如果非首次授权状态仍展示授权页，或首次状态跳过授权页，此测试应失败。
    @MainActor
    func testInitialRouteShowsPermissionOnlyForNotDeterminedStatus() throws {
        for status in [
            MPMediaLibraryAuthorizationStatus.notDetermined,
            MPMediaLibraryAuthorizationStatus.authorized,
            .denied,
            .restricted
        ] {
            let window = UIWindow(frame: .zero)
            let suiteName = UUID().uuidString
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.set(true, forKey: LaunchViewController.agreementAcceptedDefaultsKey)
            defer { defaults.removePersistentDomain(forName: suiteName) }
            var scheduledRoute: (@MainActor () -> Void)?
            let launch = LaunchViewController(
                registerDevice: {},
                requestAPNsAuthorization: {},
                agreementDefaults: defaults,
                scheduleRoute: { scheduledRoute = $0 }
            )
            let main = UIViewController()
            let coordinator = AppCoordinator(
                window: window,
                authorizationStatus: { status },
                requestAuthorization: { status },
                rootKind: .phone,
                makeMainViewController: { _ in main },
                makeLaunchViewController: { launch }
            )

            coordinator.start()
            launch.loadViewIfNeeded()
            launch.viewDidAppear(false)
            try XCTUnwrap(scheduledRoute)()

            if status == .notDetermined {
                XCTAssertTrue(window.rootViewController is PermissionViewController)
            } else {
                XCTAssertTrue(window.rootViewController === main, "状态 \(status.rawValue) 应进入主界面")
            }
        }
    }

    /// 如果首次授权页仍保留固定语言文案，系统语言切换后会显示错误语言。
    @MainActor
    func testPermissionScreenUsesLocalizedCopy() throws {
        let controller = PermissionViewController(onAllow: {}, onDefer: {})
        controller.loadViewIfNeeded()
        let title = try XCTUnwrap(
            findView(identifier: "permission.title", in: controller.view) as? UILabel
        )
        let allowButton = try XCTUnwrap(
            findView(identifier: "permission.allow", in: controller.view) as? UIButton
        )
        let copy = allViews(in: controller.view)
            .compactMap { ($0 as? UILabel)?.text }

        XCTAssertEqual(title.text, L10n.text("permission.title"))
        XCTAssertEqual(allowButton.title(for: .normal), L10n.text("permission.allow"))
        XCTAssertTrue(copy.contains(L10n.text("permission.body")))
        XCTAssertTrue(copy.contains(L10n.text("permission.direct_link_note")))
    }

    /// 如果 UIButton.Configuration 刷新覆盖 legacy title 样式，允许按钮将不再以白色 headline 实际渲染。
    @MainActor
    func testPermissionAllowButtonRendersLocalizedWhiteHeadlineTitle() throws {
        let controller = PermissionViewController(onAllow: {}, onDefer: {})
        controller.loadViewIfNeeded()
        let allowButton = try XCTUnwrap(
            findView(identifier: "permission.allow", in: controller.view) as? UIButton
        )
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        controller.view.layoutIfNeeded()
        allowButton.setNeedsUpdateConfiguration()
        allowButton.updateConfiguration()
        allowButton.layoutIfNeeded()

        XCTAssertEqual(allowButton.title(for: .normal), L10n.text("permission.allow"))
        XCTAssertEqual(allowButton.titleLabel?.font, UIFont.preferredFont(forTextStyle: .headline))
        XCTAssertEqual(allowButton.titleLabel?.textColor, .white)
    }

    /// 如果主要按钮没有轻量触觉式缩放，视觉升级会退回完全静态的系统控件。
    @MainActor
    func testPermissionButtonUsesSubtlePressFeedback() throws {
        let controller = PermissionViewController(onAllow: {}, onDefer: {})
        controller.loadViewIfNeeded()
        let button = try XCTUnwrap(
            findView(identifier: "permission.allow", in: controller.view) as? UIButton
        )
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(animationsWereEnabled) }

        button.sendActions(for: .touchDown)
        let expectedScale: CGFloat = UIAccessibility.isReduceMotionEnabled ? 1 : 0.97
        XCTAssertEqual(button.transform.a, expectedScale, accuracy: 0.001)

        button.sendActions(for: .touchCancel)
        XCTAssertEqual(button.transform, .identity)
    }

    /// 如果允许按钮重复触发请求，或权限结果不是允许时无法进入主界面，此测试应失败。
    @MainActor
    func testAllowRequestsOnceAndEntersMainOnceRegardlessOfResult() async throws {
        let window = UIWindow(frame: .zero)
        let main = UIViewController()
        let launch = acceptedLaunchViewController()
        var requestCount = 0
        var mainCount = 0
        let coordinator = AppCoordinator(
            window: window,
            authorizationStatus: { .notDetermined },
            requestAuthorization: {
                requestCount += 1
                return .denied
            },
            rootKind: .phone,
            makeMainViewController: { _ in
                mainCount += 1
                return main
            },
            makeLaunchViewController: { launch }
        )
        coordinator.start()
        launch.loadViewIfNeeded()
        launch.viewDidAppear(false)
        let permission = try XCTUnwrap(window.rootViewController as? PermissionViewController)
        permission.loadViewIfNeeded()
        let allowButton = try XCTUnwrap(
            findView(identifier: "permission.allow", in: permission.view) as? UIButton
        )

        allowButton.sendActions(for: .touchUpInside)
        allowButton.sendActions(for: .touchUpInside)
        await waitUntil { window.rootViewController === main }

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(mainCount, 1)
    }

    /// 如果“暂不”重复回调可重复创建主界面，此测试应失败。
    @MainActor
    func testDeferEntersMainOnlyOnce() throws {
        let window = UIWindow(frame: .zero)
        let main = UIViewController()
        let launch = acceptedLaunchViewController()
        var mainCount = 0
        let coordinator = AppCoordinator(
            window: window,
            authorizationStatus: { .notDetermined },
            requestAuthorization: { .authorized },
            rootKind: .phone,
            makeMainViewController: { _ in
                mainCount += 1
                return main
            },
            makeLaunchViewController: { launch }
        )
        coordinator.start()
        launch.loadViewIfNeeded()
        launch.viewDidAppear(false)
        let permission = try XCTUnwrap(window.rootViewController as? PermissionViewController)
        permission.loadViewIfNeeded()
        let deferButton = try XCTUnwrap(
            findView(identifier: "permission.defer", in: permission.view) as? UIButton
        )

        deferButton.sendActions(for: .touchUpInside)
        deferButton.sendActions(for: .touchUpInside)

        XCTAssertTrue(window.rootViewController === main)
        XCTAssertEqual(mainCount, 1)
    }

    /// 如果授权页关键视觉尺寸或按钮触控高度被缩小，此测试应失败。
    @MainActor
    func testPermissionLayoutKeepsIconAndTouchTargetSizes() throws {
        let controller = PermissionViewController(onAllow: {}, onDefer: {})
        controller.loadViewIfNeeded()
        let icon = try XCTUnwrap(findView(identifier: "permission.icon", in: controller.view))
        let allowButton = try XCTUnwrap(
            findView(identifier: "permission.allow", in: controller.view) as? UIButton
        )
        let deferButton = try XCTUnwrap(
            findView(identifier: "permission.defer", in: controller.view) as? UIButton
        )
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        controller.view.layoutIfNeeded()

        XCTAssertTrue(icon.constraints.contains { $0.firstAttribute == .width && $0.constant == 72 })
        XCTAssertTrue(icon.constraints.contains { $0.firstAttribute == .height && $0.constant == 72 })
        XCTAssertEqual(icon.frame.width, 72, accuracy: 0.5)
        XCTAssertEqual(icon.frame.height, 72, accuracy: 0.5)
        XCTAssertEqual(allowButton.frame.width, 345, accuracy: 0.5)
        XCTAssertTrue(hasMinimumHeight(48, view: allowButton))
        XCTAssertTrue(hasMinimumHeight(48, view: deferButton))
        XCTAssertTrue(allowButton.titleLabel?.adjustsFontForContentSizeCategory == true)
        XCTAssertTrue(deferButton.titleLabel?.adjustsFontForContentSizeCategory == true)
    }

    /// 如果 iPad 侧栏不再固定 264 点、内容不再自适应或 child containment 缺失，此测试应失败。
    @MainActor
    func testPadRootUsesFixedSidebarAndContainedAdaptiveContent() throws {
        let nowPlaying = UIViewController()
        let controller = PadRootViewController(nowPlayingViewController: nowPlaying)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        controller.view.layoutIfNeeded()
        let sidebar = try XCTUnwrap(findView(identifier: "pad.sidebar", in: controller.view))
        let content = try XCTUnwrap(findView(identifier: "pad.content", in: controller.view))

        XCTAssertEqual(sidebar.frame.width, 264, accuracy: 0.5)
        XCTAssertEqual(content.frame.width, 570, accuracy: 0.5)
        XCTAssertTrue(nowPlaying.parent === controller)
        XCTAssertTrue(nowPlaying.view.superview === content)
    }

    /// 如果视觉升级退回冷灰系统底色，或深色模式没有独立层次，此测试应失败。
    @MainActor
    func testThemeUsesWarmLayeredPaletteInLightAndDarkModes() {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)

        XCTAssertEqual(
            Theme.background.resolvedColor(with: light),
            UIColor(red: 247 / 255, green: 244 / 255, blue: 241 / 255, alpha: 1)
        )
        XCTAssertEqual(
            Theme.surface.resolvedColor(with: light),
            UIColor(red: 1, green: 253 / 255, blue: 252 / 255, alpha: 1)
        )
        XCTAssertEqual(
            Theme.background.resolvedColor(with: dark),
            UIColor(red: 16 / 255, green: 17 / 255, blue: 20 / 255, alpha: 1)
        )
        XCTAssertEqual(
            Theme.surface.resolvedColor(with: dark),
            UIColor(red: 26 / 255, green: 28 / 255, blue: 32 / 255, alpha: 1)
        )
        XCTAssertEqual(
            Theme.accent.resolvedColor(with: dark),
            UIColor(red: 1, green: 77 / 255, blue: 103 / 255, alpha: 1)
        )
        XCTAssertEqual(Theme.cardRadius, 16)
        XCTAssertEqual(Theme.rowRadius, 12)
        XCTAssertEqual(Theme.buttonRadius, 14)
    }

    /// 如果启动页退回空白页面、品牌图缺失或不再居中，此测试应失败。
    @MainActor
    func testLaunchScreenShowsCenteredDiskToneBrand() throws {
        let storyboard = UIStoryboard(
            name: "LaunchScreen",
            bundle: Bundle(for: AppDelegate.self)
        )
        let controller = try XCTUnwrap(storyboard.instantiateInitialViewController())
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        controller.view.layoutIfNeeded()

        let icon = try XCTUnwrap(
            findView(identifier: "launch.icon", in: controller.view) as? UIImageView
        )
        let title = try XCTUnwrap(
            findView(identifier: "launch.title", in: controller.view) as? UILabel
        )
        let subtitle = try XCTUnwrap(
            findView(identifier: "launch.subtitle", in: controller.view) as? UILabel
        )

        let expectedIcon = try XCTUnwrap(UIImage(named: "music-note-white"))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(controller.view.backgroundColor?.getRed(
            &red,
            green: &green,
            blue: &blue,
            alpha: &alpha
        ) == true)
        XCTAssertEqual(red, 250 / 255, accuracy: 0.001)
        XCTAssertEqual(green, 45 / 255, accuracy: 0.001)
        XCTAssertEqual(blue, 72 / 255, accuracy: 0.001)
        XCTAssertEqual(alpha, 1, accuracy: 0.001)
        XCTAssertEqual(icon.image?.pngData(), expectedIcon.pngData())
        XCTAssertEqual(icon.bounds.size, CGSize(width: 80, height: 80))
        XCTAssertEqual(title.text, "DiskTone")
        XCTAssertEqual(title.textColor, .white)
        XCTAssertTrue(title.font.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertEqual(subtitle.text, L10n.text("launch.subtitle"))
        XCTAssertEqual(subtitle.textColor, UIColor(white: 1, alpha: 0.85))
        XCTAssertEqual(subtitle.numberOfLines, 1)
        let iconFrame = icon.convert(icon.bounds, to: controller.view)
        let titleFrame = title.convert(title.bounds, to: controller.view)
        let subtitleFrame = subtitle.convert(subtitle.bounds, to: controller.view)
        XCTAssertEqual(iconFrame.midX, controller.view.bounds.midX, accuracy: 0.5)
        XCTAssertEqual(titleFrame.midX, controller.view.bounds.midX, accuracy: 0.5)
        XCTAssertEqual(subtitleFrame.midX, controller.view.bounds.midX, accuracy: 0.5)
        XCTAssertGreaterThan(subtitleFrame.minY, titleFrame.maxY)
        XCTAssertEqual(
            (iconFrame.minY + subtitleFrame.maxY) / 2,
            controller.view.bounds.midY,
            accuracy: 0.5
        )
    }

    /// 如果正式入口恢复 Main storyboard 或任一设备支持横屏，此测试应失败。
    func testSourceConfigurationIsPortraitOnlyAndStoryboardFree() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoURL = repositoryRoot.appendingPathComponent("SimpleMusic/Info.plist")
        let infoData = try Data(contentsOf: infoURL)
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
        )
        let sceneManifest = info["UIApplicationSceneManifest"] as? [String: Any]
        let sceneConfigurations = sceneManifest?["UISceneConfigurations"] as? [String: Any]
        let applicationConfigurations = sceneConfigurations?["UIWindowSceneSessionRoleApplication"] as? [[String: Any]]

        XCTAssertEqual(
            info["UISupportedInterfaceOrientations"] as? [String],
            ["UIInterfaceOrientationPortrait"]
        )
        XCTAssertEqual(
            info["UISupportedInterfaceOrientations~ipad"] as? [String],
            ["UIInterfaceOrientationPortrait"]
        )
        XCTAssertEqual(info["UIRequiresFullScreen"] as? Bool, true)
        XCTAssertNil(applicationConfigurations?.first?["UISceneStoryboardFile"])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: repositoryRoot.appendingPathComponent("SimpleMusic/Base.lproj/Main.storyboard").path
            )
        )

        let project = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SimpleMusic.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        XCTAssertFalse(project.contains("INFOPLIST_KEY_UIMainStoryboardFile"))
    }

    /// 如果 App 自身隐私清单缺失、格式无效或 required-reason 声明漂移，此测试应失败。
    func testAppPrivacyManifestDeclaresActualRequiredReasonAPIs() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestURL = repositoryRoot.appendingPathComponent("SimpleMusic/PrivacyInfo.xcprivacy")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let accessedTypes = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let pairs: [(String, [String])] = accessedTypes.compactMap { entry in
            guard let category = entry["NSPrivacyAccessedAPIType"] as? String,
                  let values = entry["NSPrivacyAccessedAPITypeReasons"] as? [String] else {
                return nil
            }
            return (category, values)
        }
        let reasons = Dictionary(uniqueKeysWithValues: pairs)

        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0)
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1"])
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryFileTimestamp"], ["C617.1"])
    }

    /// 如果批准图标没有完整恢复三个 appearance 槽位，或 PNG 不是原生 1024 正方形，此测试应失败。
    @MainActor
    func testAppIconCatalogContainsApproved1024Assets() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iconRoot = repositoryRoot.appendingPathComponent(
            "SimpleMusic/Assets.xcassets/AppIcon.appiconset",
            isDirectory: true
        )
        let contentsData = try Data(contentsOf: iconRoot.appendingPathComponent("Contents.json"))
        let contents = try XCTUnwrap(
            JSONSerialization.jsonObject(with: contentsData) as? [String: Any]
        )
        let images = try XCTUnwrap(contents["images"] as? [[String: Any]])
        let expectedNames = Set([
            "app-icon-record-v3-1024.png",
            "app-icon-record-dark-1024.png",
            "app-icon-record-tinted-1024.png"
        ])
        let actualNames = Set(images.compactMap { $0["filename"] as? String })

        XCTAssertEqual(actualNames, expectedNames)
        for name in expectedNames {
            let image = try XCTUnwrap(UIImage(contentsOfFile: iconRoot.appendingPathComponent(name).path))
            XCTAssertEqual(image.size, CGSize(width: 1024, height: 1024), name)
        }
    }

    @MainActor
    private func acceptedLaunchViewController() -> LaunchViewController {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: LaunchViewController.agreementAcceptedDefaultsKey)
        return LaunchViewController(
            registerDevice: {},
            requestAPNsAuthorization: {},
            agreementDefaults: defaults,
            scheduleRoute: { $0() }
        )
    }

    @MainActor
    private func waitUntil(
        attempts: Int = 20,
        condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<attempts where !condition() {
            await Task.yield()
        }
    }

    private func findView(identifier: String, in root: UIView) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        return root.subviews.lazy.compactMap { self.findView(identifier: identifier, in: $0) }.first
    }

    private func allViews(in root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap(allViews)
    }

    private func descendant<T: UIViewController>(
        _ type: T.Type,
        in root: UIViewController
    ) -> T? {
        if let match = root as? T { return match }
        return root.children.lazy.compactMap { self.descendant(type, in: $0) }.first
    }

    private func hasMinimumHeight(_ height: CGFloat, view: UIView) -> Bool {
        view.constraints.contains {
            $0.firstAttribute == .height && $0.relation == .greaterThanOrEqual && $0.constant >= height
        }
    }
}

@MainActor
private final class CoordinatorStubMusicLibrary: MusicLibraryLoading {
    let authorizationStatus = MPMediaLibraryAuthorizationStatus.authorized

    func loadTracks() async throws -> [SimpleMusic.MusicTrack] { [] }
}

@MainActor
private final class CoordinatorStubLocalMusicStore: LocalMusicLoading {
    func loadTracks() async throws -> [SimpleMusic.MusicTrack] { [] }
}
