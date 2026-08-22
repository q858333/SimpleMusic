import Combine
import SnapKit
import UIKit

/// iPhone 根容器：资料库和搜索共享同一份列表，迷你播放器只转发播放动作。
final class MainTabBarController: UITabBarController {
    let dependencyIdentity: ObjectIdentifier?
    private let libraryViewModel: LibraryViewModel
    private let snapshotPublisher: AnyPublisher<PlaybackSnapshot, Never>
    private let onPlay: ([MusicTrack], Int) -> Void
    private let onDeleteTrack: (MusicTrack) -> Void
    private let onTogglePlay: () -> Void
    private var reloadTask: Task<Void, Never>?
    private var miniBottomConstraint: Constraint?
    private var miniPlayerUsesSafeAreaBottom = false

    var onOpenPlayer: (() -> Void)?

    private lazy var libraryViewController = LibraryViewController(viewModel: libraryViewModel)
    private lazy var searchViewController = SearchViewController(viewModel: libraryViewModel)
    private lazy var miniPlayerView = MiniPlayerView(
        snapshotPublisher: snapshotPublisher,
        onTogglePlay: onTogglePlay,
        onOpenPlayer: { [weak self] in self?.onOpenPlayer?() }
    )

    convenience init() {
        self.init(environment: .shared)
    }

    convenience init(environment: AppEnvironment) {
        self.init(dependencies: AppRootDependencies(environment: environment))
    }

    convenience init(dependencies: AppRootDependencies) {
        self.init(
            libraryViewModel: dependencies.libraryViewModel,
            snapshotPublisher: dependencies.snapshotPublisher,
            onPlay: dependencies.onPlay,
            onDeleteTrack: dependencies.onDeleteTrack,
            onTogglePlay: dependencies.onTogglePlay,
            onOpenPlayer: {},
            dependencyIdentity: dependencies.identity
        )
    }

    init(
        libraryViewModel: LibraryViewModel,
        snapshotPublisher: AnyPublisher<PlaybackSnapshot, Never>,
        onPlay: @escaping ([MusicTrack], Int) -> Void,
        onDeleteTrack: @escaping (MusicTrack) -> Void = { _ in },
        onTogglePlay: @escaping () -> Void,
        onOpenPlayer: @escaping () -> Void,
        dependencyIdentity: ObjectIdentifier? = nil
    ) {
        self.dependencyIdentity = dependencyIdentity
        self.libraryViewModel = libraryViewModel
        self.snapshotPublisher = snapshotPublisher
        self.onPlay = onPlay
        self.onDeleteTrack = onDeleteTrack
        self.onTogglePlay = onTogglePlay
        self.onOpenPlayer = onOpenPlayer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainTabBarController 仅支持纯代码初始化")
    }

    deinit {
        reloadTask?.cancel()
        miniPlayerView.stop()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tabBar.tintColor = Theme.accent
        configurePages()
        installMiniPlayer()
        reloadTask = Task { [weak libraryViewModel] in
            await libraryViewModel?.requestReload()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateMiniPlayerBottomConstraint()
    }

    private func configurePages() {
        libraryViewController.onSelectTrack = { [weak self] queue, index in
            self?.onPlay(queue, index)
        }
        searchViewController.onSelectTrack = { [weak self] queue, index in
            self?.onPlay(queue, index)
        }
        libraryViewController.onDeleteTrack = onDeleteTrack
        searchViewController.onDeleteTrack = onDeleteTrack

        libraryViewController.tabBarItem = UITabBarItem(
            title: L10n.text("tab.library"),
            image: UIImage(systemName: "music.note.list"),
            selectedImage: nil
        )
        searchViewController.tabBarItem = UITabBarItem(
            title: L10n.text("tab.search"),
            image: UIImage(systemName: "magnifyingglass"),
            selectedImage: nil
        )
        let libraryNavigation = UINavigationController(rootViewController: libraryViewController)
        let searchNavigation = UINavigationController(rootViewController: searchViewController)
        libraryNavigation.delegate = self
        searchNavigation.delegate = self
        viewControllers = [libraryNavigation, searchNavigation]
    }

    private func installMiniPlayer() {
        view.addSubview(miniPlayerView)
        miniPlayerView.snp.makeConstraints { make in
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(8)
            miniBottomConstraint = make.bottom
                .equalTo(view.safeAreaLayoutGuide.snp.bottom)
                .constraint
        }
        updateMiniPlayerBottomConstraint()
    }

    private func setMiniPlayerUsesSafeAreaBottom(_ usesSafeArea: Bool) {
        guard miniPlayerUsesSafeAreaBottom != usesSafeArea else { return }
        miniPlayerUsesSafeAreaBottom = usesSafeArea
        updateMiniPlayerBottomConstraint()
    }

    private func updateMiniPlayerBottomConstraint() {
        let offset: CGFloat
        if miniPlayerUsesSafeAreaBottom {
            offset = -8
        } else {
            // 仅使用稳定的根安全区；Tab Bar 被 UIKit 重挂载时也不会产生跨层级约束。
            let tabBarHeightAboveSafeArea = max(
                0,
                tabBar.bounds.height - view.safeAreaInsets.bottom
            )
            offset = -(tabBarHeightAboveSafeArea + 6)
        }
        miniBottomConstraint?.update(offset: offset)
    }
}

extension MainTabBarController: UINavigationControllerDelegate {
    func navigationController(
        _ navigationController: UINavigationController,
        willShow viewController: UIViewController,
        animated: Bool
    ) {
        let previousValue = miniPlayerUsesSafeAreaBottom
        let nextValue = viewController.hidesBottomBarWhenPushed
        guard previousValue != nextValue else { return }

        // Tab Bar 隐藏时改贴安全区底部，让迷你播放器在普通子页面继续悬浮。
        setMiniPlayerUsesSafeAreaBottom(nextValue)
        guard animated,
              let transitionCoordinator = navigationController.transitionCoordinator else {
            view.layoutIfNeeded()
            return
        }
        transitionCoordinator.animate { [weak self] _ in
            self?.view.layoutIfNeeded()
        } completion: { [weak self] context in
            guard context.isCancelled else { return }
            self?.setMiniPlayerUsesSafeAreaBottom(previousValue)
            self?.view.layoutIfNeeded()
        }
    }
}
