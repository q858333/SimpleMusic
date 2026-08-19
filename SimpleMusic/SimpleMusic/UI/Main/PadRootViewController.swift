import Combine
import SnapKit
import UIKit

/// iPad 双栏根容器；保留 264pt 侧栏和右侧 Now Playing child 容器边界。
final class PadRootViewController: UIViewController {
    let dependencyIdentity: ObjectIdentifier?
    private let nowPlayingViewController: UIViewController
    private let libraryViewModel: LibraryViewModel?
    private let snapshotPublisher: AnyPublisher<PlaybackSnapshot, Never>?
    private let onPlay: (([MusicTrack], Int) -> Void)?
    private let onDeleteTrack: ((MusicTrack) -> Void)?
    private let onTogglePlay: (() -> Void)?
    private var reloadTask: Task<Void, Never>?
    private var activeContentController: UIViewController?
    private var libraryController: LibraryViewController?
    private var searchController: SearchViewController?
    private var libraryNavigationController: UINavigationController?
    private var searchNavigationController: UINavigationController?
    private var miniPlayerView: MiniPlayerView?

    var onOpenPlayer: (() -> Void)?

    private let sidebarView: UIView = {
        let view = UIView()
        view.accessibilityIdentifier = "pad.sidebar"
        view.backgroundColor = Theme.surface
        return view
    }()

    private let contentView: UIView = {
        let view = UIView()
        view.accessibilityIdentifier = "pad.content"
        view.backgroundColor = Theme.background
        return view
    }()

    convenience init() {
        self.init(environment: .shared)
    }

    convenience init(environment: AppEnvironment) {
        self.init(dependencies: AppRootDependencies(environment: environment))
    }

    convenience init(dependencies: AppRootDependencies) {
        let player = PlayerViewController(
            snapshotPublisher: dependencies.snapshotPublisher,
            onTogglePlay: dependencies.onTogglePlay,
            onPrevious: dependencies.onPrevious,
            onNext: dependencies.onNext,
            onSeek: dependencies.onSeek
        )
        let panel = NowPlayingPanelController(playerViewController: player)
        self.init(
            nowPlayingViewController: panel,
            libraryViewModel: dependencies.libraryViewModel,
            snapshotPublisher: dependencies.snapshotPublisher,
            onPlay: dependencies.onPlay,
            onDeleteTrack: dependencies.onDeleteTrack,
            onTogglePlay: dependencies.onTogglePlay,
            onOpenPlayer: {},
            dependencyIdentity: dependencies.identity
        )
        onOpenPlayer = { [weak self, weak panel] in
            panel?.show(returnFocusTo: self?.miniPlayerView)
        }
    }

    /// 保留 Task 8 注入点，后续完整播放页仍可使用同一 child containment 边界。
    init(nowPlayingViewController: UIViewController) {
        dependencyIdentity = nil
        self.nowPlayingViewController = nowPlayingViewController
        libraryViewModel = nil
        snapshotPublisher = nil
        onPlay = nil
        onDeleteTrack = nil
        onTogglePlay = nil
        super.init(nibName: nil, bundle: nil)
    }

    init(
        nowPlayingViewController: UIViewController,
        libraryViewModel: LibraryViewModel,
        snapshotPublisher: AnyPublisher<PlaybackSnapshot, Never>,
        onPlay: @escaping ([MusicTrack], Int) -> Void,
        onDeleteTrack: @escaping (MusicTrack) -> Void = { _ in },
        onTogglePlay: @escaping () -> Void,
        onOpenPlayer: @escaping () -> Void,
        dependencyIdentity: ObjectIdentifier? = nil
    ) {
        self.dependencyIdentity = dependencyIdentity
        self.nowPlayingViewController = nowPlayingViewController
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
        fatalError("PadRootViewController 仅支持纯代码初始化")
    }

    deinit {
        reloadTask?.cancel()
        miniPlayerView?.stop()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        buildColumns()
        installNowPlayingChild()
        buildSidebar()
        if let libraryViewModel {
            installLibraryPages(viewModel: libraryViewModel)
            reloadTask = Task { [weak libraryViewModel] in
                await libraryViewModel?.requestReload()
            }
        }
    }

    private func buildColumns() {
        view.addSubview(sidebarView)
        view.addSubview(contentView)

        sidebarView.snp.makeConstraints { make in
            make.leading.top.bottom.equalToSuperview()
            make.width.equalTo(264)
        }
        contentView.snp.makeConstraints { make in
            make.leading.equalTo(sidebarView.snp.trailing)
            make.top.trailing.bottom.equalToSuperview()
        }
    }

    private func installNowPlayingChild() {
        // UIKit child containment 顺序必须是 addChild → 挂载 view → didMove。
        addChild(nowPlayingViewController)
        let hostView = nowPlayingViewController is NowPlayingPanelController ? view! : contentView
        hostView.addSubview(nowPlayingViewController.view)
        nowPlayingViewController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        nowPlayingViewController.didMove(toParent: self)
        if !(nowPlayingViewController is NowPlayingPanelController) {
            nowPlayingViewController.view.isHidden = libraryViewModel != nil
        }
    }

    private func buildSidebar() {
        let titleLabel = UILabel()
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.text = "听见"
        titleLabel.textColor = .label

        let libraryButton = sidebarButton(title: "资料库", symbol: "music.note.list")
        libraryButton.accessibilityIdentifier = "pad.library"
        libraryButton.addAction(UIAction { [weak self] _ in
            guard let navigation = self?.libraryNavigationController else { return }
            self?.showContent(navigation)
        }, for: .touchUpInside)

        let searchButton = sidebarButton(title: "搜索", symbol: "magnifyingglass")
        searchButton.accessibilityIdentifier = "pad.search"
        searchButton.addAction(UIAction { [weak self] _ in
            guard let navigation = self?.searchNavigationController else { return }
            self?.showContent(navigation)
        }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [titleLabel, libraryButton, searchButton])
        stack.axis = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(28, after: titleLabel)
        sidebarView.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.top.equalTo(sidebarView.safeAreaLayoutGuide).offset(28)
            make.leading.trailing.equalToSuperview().inset(20)
        }
    }

    private func installLibraryPages(viewModel: LibraryViewModel) {
        let library = LibraryViewController(viewModel: viewModel)
        let search = SearchViewController(viewModel: viewModel)
        library.onSelectTrack = { [weak self] queue, index in self?.onPlay?(queue, index) }
        search.onSelectTrack = { [weak self] queue, index in self?.onPlay?(queue, index) }
        library.onDeleteTrack = onDeleteTrack
        search.onDeleteTrack = onDeleteTrack
        libraryController = library
        searchController = search
        let libraryNavigation = UINavigationController(rootViewController: library)
        let searchNavigation = UINavigationController(rootViewController: search)
        libraryNavigationController = libraryNavigation
        searchNavigationController = searchNavigation
        showContent(libraryNavigation)

        guard let snapshotPublisher, let onTogglePlay else { return }
        let mini = MiniPlayerView(
            snapshotPublisher: snapshotPublisher,
            onTogglePlay: onTogglePlay,
            onOpenPlayer: { [weak self] in self?.onOpenPlayer?() }
        )
        miniPlayerView = mini
        contentView.addSubview(mini)
        mini.snp.makeConstraints { make in
            make.leading.trailing.equalTo(contentView.safeAreaLayoutGuide).inset(12)
            make.bottom.equalTo(contentView.safeAreaLayoutGuide).inset(12)
        }
    }

    private func showContent(_ controller: UIViewController) {
        guard controller !== activeContentController else { return }
        if let activeContentController {
            activeContentController.willMove(toParent: nil)
            activeContentController.view.removeFromSuperview()
            activeContentController.removeFromParent()
        }
        addChild(controller)
        contentView.addSubview(controller.view)
        controller.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        controller.didMove(toParent: self)
        activeContentController = controller
        if let miniPlayerView {
            contentView.bringSubviewToFront(miniPlayerView)
        }
    }

    private func sidebarButton(title: String, symbol: String) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePadding = 12
        configuration.baseForegroundColor = Theme.accent
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        let button = UIButton(configuration: configuration)
        button.contentHorizontalAlignment = .leading
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.snp.makeConstraints { make in
            make.height.greaterThanOrEqualTo(44)
        }
        return button
    }
}
