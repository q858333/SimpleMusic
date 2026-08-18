import MediaPlayer
import UIKit
import XCTest
@testable import SimpleMusic

final class AppCoordinatorTests: XCTestCase {
    /// 如果设备类型映射交换或 iPad 错走手机根界面，此测试应失败。
    @MainActor
    func testRootKindMatchesPhoneAndPadIdioms() {
        XCTAssertEqual(AppCoordinator.rootKind(for: .phone), .phone)
        XCTAssertEqual(AppCoordinator.rootKind(for: .pad), .pad)
    }

    /// 如果非首次授权状态仍展示授权页，或首次状态跳过授权页，此测试应失败。
    @MainActor
    func testInitialRouteShowsPermissionOnlyForNotDeterminedStatus() {
        let permissionWindow = UIWindow(frame: .zero)
        let permissionCoordinator = makeCoordinator(
            window: permissionWindow,
            status: .notDetermined
        )

        permissionCoordinator.start()

        XCTAssertTrue(permissionWindow.rootViewController is PermissionViewController)

        for status in [
            MPMediaLibraryAuthorizationStatus.authorized,
            .denied,
            .restricted
        ] {
            let window = UIWindow(frame: .zero)
            let main = UIViewController()
            let coordinator = makeCoordinator(window: window, status: status) { main }

            coordinator.start()

            XCTAssertTrue(window.rootViewController === main, "状态 \(status.rawValue) 应直接进入主界面")
        }
    }

    /// 如果允许按钮重复触发请求，或权限结果不是允许时无法进入主界面，此测试应失败。
    @MainActor
    func testAllowRequestsOnceAndEntersMainOnceRegardlessOfResult() async throws {
        let window = UIWindow(frame: .zero)
        let main = UIViewController()
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
            }
        )
        coordinator.start()
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
        var mainCount = 0
        let coordinator = AppCoordinator(
            window: window,
            authorizationStatus: { .notDetermined },
            requestAuthorization: { .authorized },
            rootKind: .phone,
            makeMainViewController: { _ in
                mainCount += 1
                return main
            }
        )
        coordinator.start()
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

    /// 如果主题颜色或卡片圆角偏离已批准设计 token，此测试应失败。
    @MainActor
    func testThemeMatchesApprovedDesignTokens() {
        XCTAssertEqual(Theme.background, .systemGroupedBackground)
        XCTAssertEqual(Theme.surface, .secondarySystemGroupedBackground)
        XCTAssertEqual(Theme.cardRadius, 16)
        XCTAssertEqual(Theme.accent, UIColor(red: 250 / 255, green: 45 / 255, blue: 72 / 255, alpha: 1))
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

    @MainActor
    private func makeCoordinator(
        window: UIWindow,
        status: MPMediaLibraryAuthorizationStatus,
        makeMain: (@MainActor () -> UIViewController)? = nil
    ) -> AppCoordinator {
        AppCoordinator(
            window: window,
            authorizationStatus: { status },
            requestAuthorization: { status },
            rootKind: .phone,
            makeMainViewController: { _ in makeMain?() ?? UIViewController() }
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

    private func hasMinimumHeight(_ height: CGFloat, view: UIView) -> Bool {
        view.constraints.contains {
            $0.firstAttribute == .height && $0.relation == .greaterThanOrEqual && $0.constant >= height
        }
    }
}
