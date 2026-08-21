import Combine
import MediaPlayer
import UIKit

enum AppRootKind: Equatable {
    case phone
    case pad
}

/// 根容器所需的最小依赖包；identity 让测试无需构造第二个真实 AppEnvironment。
@MainActor
struct AppRootDependencies {
    let identity: ObjectIdentifier
    let libraryViewModel: LibraryViewModel
    let snapshotPublisher: AnyPublisher<PlaybackSnapshot, Never>
    let onPlay: ([MusicTrack], Int) -> Void
    let onDeleteTrack: (MusicTrack) -> Void
    let onTogglePlay: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onSeek: (TimeInterval) -> Void
    let makeDownloadViewController: @MainActor () -> UIViewController
    let makeSettingsViewController: @MainActor () -> UIViewController

    init(environment: AppEnvironment) {
        let viewModel = environment.libraryViewModel
        let play: ([MusicTrack], Int) -> Void = { [playbackCoordinator = environment.playbackCoordinator] queue, index in
            do {
                try playbackCoordinator.play(queue: queue, startAt: index)
            } catch {
                NSLog("无法开始播放：%@", String(describing: error))
            }
        }
        identity = ObjectIdentifier(environment)
        libraryViewModel = viewModel
        snapshotPublisher = environment.playbackCoordinator.snapshotPublisher
        onPlay = play
        onDeleteTrack = { [weak viewModel] track in
            Task { await viewModel?.deleteDownloadedTrack(track) }
        }
        onTogglePlay = { [playbackCoordinator = environment.playbackCoordinator] in
            playbackCoordinator.togglePlay()
        }
        onPrevious = { [playbackCoordinator = environment.playbackCoordinator] in
            do {
                try playbackCoordinator.previous()
            } catch {
                NSLog("无法播放上一首：%@", String(describing: error))
            }
        }
        onNext = { [playbackCoordinator = environment.playbackCoordinator] in
            do {
                try playbackCoordinator.next()
            } catch {
                NSLog("无法播放下一首：%@", String(describing: error))
            }
        }
        onSeek = { [playbackCoordinator = environment.playbackCoordinator] seconds in
            playbackCoordinator.seek(to: seconds)
        }
        makeDownloadViewController = {
            guard let downloadQueue = environment.downloadQueue else {
                return DownloadUnavailableViewController(
                    message: environment.downloadStorageWarning ?? L10n.text("storage.download.unavailable_short")
                )
            }
            // 手机弹层与 iPad 路由都复用环境中的应用级队列。
            return DownloadSheetViewController(downloadQueue: downloadQueue)
        }
        makeSettingsViewController = {
            SettingsViewController(
                settingsStore: environment.settingsStore,
                libraryService: environment.musicLibraryService,
                onAuthorizationChange: {
                    await viewModel.requestReload()
                }
            )
        }
    }

    init(
        identity: AnyObject,
        libraryViewModel: LibraryViewModel,
        snapshotPublisher: AnyPublisher<PlaybackSnapshot, Never>,
        onPlay: @escaping ([MusicTrack], Int) -> Void,
        onDeleteTrack: @escaping (MusicTrack) -> Void = { _ in },
        onTogglePlay: @escaping () -> Void,
        onPrevious: @escaping () -> Void = {},
        onNext: @escaping () -> Void = {},
        onSeek: @escaping (TimeInterval) -> Void = { _ in },
        makeDownloadViewController: @escaping @MainActor () -> UIViewController = { UIViewController() },
        makeSettingsViewController: @escaping @MainActor () -> UIViewController = { UIViewController() }
    ) {
        self.identity = ObjectIdentifier(identity)
        self.libraryViewModel = libraryViewModel
        self.snapshotPublisher = snapshotPublisher
        self.onPlay = onPlay
        self.onDeleteTrack = onDeleteTrack
        self.onTogglePlay = onTogglePlay
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onSeek = onSeek
        self.makeDownloadViewController = makeDownloadViewController
        self.makeSettingsViewController = makeSettingsViewController
    }
}

/// 负责首次权限分流和设备根容器选择；业务页面由后续模块注入根壳。
@MainActor
final class AppCoordinator {
    typealias AuthorizationStatus = () -> MPMediaLibraryAuthorizationStatus
    typealias AuthorizationRequest = () async -> MPMediaLibraryAuthorizationStatus
    typealias MainViewControllerFactory = (AppRootKind) -> UIViewController
    typealias LaunchViewControllerFactory = @MainActor () -> UIViewController
    typealias LaunchTransitionScheduler = @MainActor (@escaping @MainActor () -> Void) -> Void

    private let window: UIWindow
    private let authorizationStatus: AuthorizationStatus
    private let requestAuthorization: AuthorizationRequest
    private let rootKind: AppRootKind
    private let makeMainViewController: MainViewControllerFactory
    private let makeLaunchViewController: LaunchViewControllerFactory
    private let scheduleLaunchTransition: LaunchTransitionScheduler
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
        let dependencies = AppRootDependencies(environment: environment)
        self.init(
            window: window,
            authorizationStatus: { environment.musicLibraryService.authorizationStatus },
            requestAuthorization: { await environment.musicLibraryService.requestAuthorization() },
            rootKind: Self.rootKind(for: userInterfaceIdiom),
            makeMainViewController: Self.makeMainViewControllerFactory(dependencies: dependencies)
        )
    }

    init(
        window: UIWindow,
        authorizationStatus: @escaping AuthorizationStatus,
        requestAuthorization: @escaping AuthorizationRequest,
        rootKind: AppRootKind,
        makeMainViewController: @escaping MainViewControllerFactory,
        makeLaunchViewController: @escaping LaunchViewControllerFactory = AppCoordinator.makeLaunchViewController,
        scheduleLaunchTransition: @escaping LaunchTransitionScheduler = AppCoordinator.scheduleLaunchTransition
    ) {
        self.window = window
        self.authorizationStatus = authorizationStatus
        self.requestAuthorization = requestAuthorization
        self.rootKind = rootKind
        self.makeMainViewController = makeMainViewController
        self.makeLaunchViewController = makeLaunchViewController
        self.scheduleLaunchTransition = scheduleLaunchTransition
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        window.rootViewController = makeLaunchViewController()
        window.makeKeyAndVisible()
        scheduleLaunchTransition { [weak self] in
            self?.showInitialRoute()
        }
    }

    private func showInitialRoute() {
        if authorizationStatus() == .notDetermined {
            showPermission()
        } else {
            showMainInterface()
        }
    }

    /// 运行时直接复用系统启动 storyboard，避免维护两套品牌布局。
    private static func makeLaunchViewController() -> UIViewController {
        let storyboard = UIStoryboard(
            name: "LaunchScreen",
            bundle: Bundle(for: AppDelegate.self)
        )
        guard let controller = storyboard.instantiateInitialViewController() else {
            preconditionFailure("LaunchScreen.storyboard 必须配置 initialViewController")
        }
        return controller
    }

    /// 系统启动页结束后继续显示同款 App 内页面一秒，再恢复原有路由。
    private static func scheduleLaunchTransition(
        _ transition: @escaping @MainActor () -> Void
    ) {
        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            transition()
        }
    }

    static func rootKind(for idiom: UIUserInterfaceIdiom) -> AppRootKind {
        idiom == .pad ? .pad : .phone
    }

    static func makeMainViewControllerFactory(
        dependencies: AppRootDependencies
    ) -> MainViewControllerFactory {
        { kind in
            let root: UIViewController
            switch kind {
            case .phone:
                let controller = MainTabBarController(dependencies: dependencies)
                controller.onOpenPlayer = { [weak controller] in
                    guard let controller, controller.presentedViewController == nil else { return }
                    let player = Self.makePlayerViewController(dependencies: dependencies)
                    player.modalPresentationStyle = .fullScreen
                    player.onDismiss = { [weak player] in
                        player?.dismiss(animated: true)
                    }
                    controller.present(player, animated: true)
                }
                root = controller
            case .pad:
                root = PadRootViewController(dependencies: dependencies)
            }
            root.loadViewIfNeeded()
            wireLibraryActions(in: root, dependencies: dependencies)
            return root
        }
    }

    private static func wireLibraryActions(
        in root: UIViewController,
        dependencies: AppRootDependencies
    ) {
        guard let library = descendantLibraryController(in: root) else { return }
        library.onDownload = { [weak library] in
            guard let library, library.presentedViewController == nil else { return }
            let content = dependencies.makeDownloadViewController()
            let navigation = UINavigationController(rootViewController: content)
            navigation.modalPresentationStyle = .pageSheet
            library.present(navigation, animated: true)
        }
        library.onSettings = { [weak library] in
            guard let library else { return }
            if let navigation = library.navigationController {
                guard navigation.transitionCoordinator == nil,
                      !(navigation.topViewController is SettingsViewController) else { return }
                let settings = dependencies.makeSettingsViewController()
                // 设置及其子页面使用完整内容区域，返回资料库后 Tab Bar 会自动恢复。
                settings.hidesBottomBarWhenPushed = true
                navigation.pushViewController(settings, animated: true)
            } else {
                guard library.presentedViewController == nil else { return }
                let settings = dependencies.makeSettingsViewController()
                library.present(UINavigationController(rootViewController: settings), animated: true)
            }
        }
    }

    private static func descendantLibraryController(in root: UIViewController) -> LibraryViewController? {
        if let library = root as? LibraryViewController { return library }
        for child in root.children {
            if let library = descendantLibraryController(in: child) { return library }
        }
        return nil
    }

    private static func makePlayerViewController(
        dependencies: AppRootDependencies
    ) -> PlayerViewController {
        PlayerViewController(
            snapshotPublisher: dependencies.snapshotPublisher,
            onTogglePlay: dependencies.onTogglePlay,
            onPrevious: dependencies.onPrevious,
            onNext: dependencies.onNext,
            onSeek: dependencies.onSeek
        )
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
