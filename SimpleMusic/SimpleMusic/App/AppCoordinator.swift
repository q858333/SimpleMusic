import MediaPlayer
import UIKit

enum AppRootKind: Equatable {
    case phone
    case pad
}

/// 负责首次权限分流和设备根容器选择；业务页面由后续模块注入根壳。
@MainActor
final class AppCoordinator {
    typealias AuthorizationStatus = () -> MPMediaLibraryAuthorizationStatus
    typealias AuthorizationRequest = () async -> MPMediaLibraryAuthorizationStatus
    typealias MainViewControllerFactory = (AppRootKind) -> UIViewController

    private let window: UIWindow
    private let authorizationStatus: AuthorizationStatus
    private let requestAuthorization: AuthorizationRequest
    private let rootKind: AppRootKind
    private let makeMainViewController: MainViewControllerFactory
    private var hasStarted = false
    private var hasEnteredMain = false

    convenience init(
        window: UIWindow,
        environment: AppEnvironment
    ) {
        self.init(
            window: window,
            environment: environment,
            userInterfaceIdiom: UIDevice.current.userInterfaceIdiom
        )
    }

    convenience init(
        window: UIWindow,
        environment: AppEnvironment,
        userInterfaceIdiom: UIUserInterfaceIdiom
    ) {
        self.init(
            window: window,
            authorizationStatus: { environment.musicLibraryService.authorizationStatus },
            requestAuthorization: { await environment.musicLibraryService.requestAuthorization() },
            rootKind: Self.rootKind(for: userInterfaceIdiom),
            makeMainViewController: Self.makeMainViewController(for:)
        )
    }

    init(
        window: UIWindow,
        authorizationStatus: @escaping AuthorizationStatus,
        requestAuthorization: @escaping AuthorizationRequest,
        rootKind: AppRootKind,
        makeMainViewController: @escaping MainViewControllerFactory
    ) {
        self.window = window
        self.authorizationStatus = authorizationStatus
        self.requestAuthorization = requestAuthorization
        self.rootKind = rootKind
        self.makeMainViewController = makeMainViewController
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        if authorizationStatus() == .notDetermined {
            showPermission()
        } else {
            showMainInterface()
        }
        window.makeKeyAndVisible()
    }

    static func rootKind(for idiom: UIUserInterfaceIdiom) -> AppRootKind {
        idiom == .pad ? .pad : .phone
    }

    private static func makeMainViewController(for kind: AppRootKind) -> UIViewController {
        switch kind {
        case .phone:
            return MainTabBarController()
        case .pad:
            return PadRootViewController()
        }
    }

    private func showPermission() {
        let controller = PermissionViewController(
            onAllow: { [weak self] in
                guard let self else { return }
                _ = await requestAuthorization()
                // 授权拒绝或受限也进入主界面，由后续资料库页面持续提示状态。
                showMainInterface()
            },
            onDefer: { [weak self] in
                self?.showMainInterface()
            }
        )
        window.rootViewController = controller
    }

    private func showMainInterface() {
        // 异步权限回调和按钮事件可能接近发生，根界面只能创建一次。
        guard !hasEnteredMain else { return }
        hasEnteredMain = true
        window.rootViewController = makeMainViewController(rootKind)
    }
}
