import Combine
import SnapKit
import UIKit

/// iPad 双栏根容器；保留 264pt 侧栏和右侧 Now Playing child 容器边界。
final class PadRootViewController: UIViewController {
    private enum PlayerGuidePreference {
        static let hasSeenKey = "hasSeenPadPlayerGuide"
    }

    let dependencyIdentity: ObjectIdentifier?
    private let nowPlayingViewController: UIViewController
    private let playerGuideDefaults: UserDefaults
    private let libraryViewModel: LibraryViewModel?
    private let playlistViewModel: PlaylistViewModel?
    private let snapshotPublisher: AnyPublisher<PlaybackSnapshot, Never>?
    private let onPlay: (([MusicTrack], Int) -> Void)?
    private let onDeleteTrack: ((MusicTrack) -> Void)?
    private let onTogglePlay: (() -> Void)?
    private var reloadTask: Task<Void, Never>?
    private var playerGuideCancellable: AnyCancellable?
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

    private let playerGuideView: UIView = {
        let container = UIView()
        container.accessibilityIdentifier = "pad.playerGuide"
        container.isAccessibilityElement = true
        container.accessibilityLabel = L10n.text("pad.player_guide")
        container.accessibilityTraits = .staticText
        container.isHidden = true

        let bubbleBody = UIView()
        bubbleBody.accessibilityIdentifier = "pad.playerGuide.body"
        bubbleBody.backgroundColor = Theme.accent.withAlphaComponent(0.12)
        bubbleBody.layer.cornerRadius = 12

        let arrow = PlayerGuideArrowView()

        let icon = UIImageView(image: UIImage(systemName: "hand.tap.fill"))
        icon.tintColor = Theme.accent
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let label = UILabel()
        label.text = L10n.text("pad.player_guide")
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        container.addSubview(bubbleBody)
        container.addSubview(arrow)
        bubbleBody.addSubview(stack)
        bubbleBody.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
        }
        arrow.snp.makeConstraints { make in
            // 与气泡主体轻微重叠，避免主体边框和箭头之间出现缝隙。
            make.top.equalTo(bubbleBody.snp.bottom).offset(-0.5)
            make.bottom.centerX.equalToSuperview()
            make.width.equalTo(20)
            make.height.equalTo(10)
        }
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(
                UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
            )
        }
        return container
    }()

    convenience init() {
        self.init(environment: .shared)
    }

    convenience init(environment: AppEnvironment) {
        self.init(dependencies: AppRootDependencies(environment: environment))
    }

    convenience init(
        dependencies: AppRootDependencies,
        playerGuideDefaults: UserDefaults = .standard
    ) {
        let player = PlayerViewController(
            snapshotPublisher: dependencies.snapshotPublisher,
            onTogglePlay: dependencies.onTogglePlay,
            onPrevious: dependencies.onPrevious,
            onNext: dependencies.onNext,
            onSeek: dependencies.onSeek,
            onCyclePlaybackMode: dependencies.onCyclePlaybackMode,
            onSelectQueueItem: dependencies.onSelectQueueItem,
            onUpdateAudioEffect: dependencies.onUpdateAudioEffect
        )
        let panel = NowPlayingPanelController(playerViewController: player)
        self.init(
            nowPlayingViewController: panel,
            libraryViewModel: dependencies.libraryViewModel,
            playlistViewModel: dependencies.playlistViewModel,
            snapshotPublisher: dependencies.snapshotPublisher,
            onPlay: dependencies.onPlay,
            onDeleteTrack: dependencies.onDeleteTrack,
            onTogglePlay: dependencies.onTogglePlay,
            onOpenPlayer: {},
            dependencyIdentity: dependencies.identity,
            playerGuideDefaults: playerGuideDefaults
        )
        onOpenPlayer = { [weak self, weak panel] in
            self?.markPlayerGuideSeen()
            panel?.show(returnFocusTo: self?.miniPlayerView)
        }
    }

    /// 保留 Task 8 注入点，后续完整播放页仍可使用同一 child containment 边界。
    init(nowPlayingViewController: UIViewController) {
        dependencyIdentity = nil
        self.nowPlayingViewController = nowPlayingViewController
        playerGuideDefaults = .standard
        libraryViewModel = nil
        playlistViewModel = nil
        snapshotPublisher = nil
        onPlay = nil
        onDeleteTrack = nil
        onTogglePlay = nil
        super.init(nibName: nil, bundle: nil)
    }

    init(
        nowPlayingViewController: UIViewController,
        libraryViewModel: LibraryViewModel,
        playlistViewModel: PlaylistViewModel? = nil,
        snapshotPublisher: AnyPublisher<PlaybackSnapshot, Never>,
        onPlay: @escaping ([MusicTrack], Int) -> Void,
        onDeleteTrack: @escaping (MusicTrack) -> Void = { _ in },
        onTogglePlay: @escaping () -> Void,
        onOpenPlayer: @escaping () -> Void,
        dependencyIdentity: ObjectIdentifier? = nil,
        playerGuideDefaults: UserDefaults = .standard
    ) {
        self.dependencyIdentity = dependencyIdentity
        self.nowPlayingViewController = nowPlayingViewController
        self.playerGuideDefaults = playerGuideDefaults
        self.libraryViewModel = libraryViewModel
        self.playlistViewModel = playlistViewModel
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
        playerGuideCancellable?.cancel()
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
        titleLabel.text = L10n.text("app.name")
        titleLabel.textColor = .label

        let libraryButton = sidebarButton(title: L10n.text("tab.library"), symbol: "music.note.list")
        libraryButton.accessibilityIdentifier = "pad.library"
        libraryButton.addAction(UIAction { [weak self] _ in
            guard let navigation = self?.libraryNavigationController else { return }
            self?.showContent(navigation)
        }, for: .touchUpInside)

        let searchButton = sidebarButton(title: L10n.text("tab.search"), symbol: "magnifyingglass")
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
        let library = LibraryViewController(
            viewModel: viewModel,
            playlistViewModel: playlistViewModel
        )
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
        contentView.addSubview(playerGuideView)
        mini.snp.makeConstraints { make in
            make.leading.trailing.equalTo(contentView.safeAreaLayoutGuide).inset(12)
            make.bottom.equalTo(contentView.safeAreaLayoutGuide).inset(12)
        }
        playerGuideView.snp.makeConstraints { make in
            make.trailing.equalTo(mini)
            make.leading.greaterThanOrEqualTo(contentView.safeAreaLayoutGuide).offset(12)
            make.bottom.equalTo(mini.snp.top).offset(-8)
            make.height.greaterThanOrEqualTo(44)
            make.width.lessThanOrEqualTo(360)
        }
        playerGuideCancellable = snapshotPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.renderPlayerGuide(hasTrack: snapshot.track != nil)
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
            contentView.bringSubviewToFront(playerGuideView)
        }
    }

    private func renderPlayerGuide(hasTrack: Bool) {
        playerGuideView.isHidden = !hasTrack
            || playerGuideDefaults.bool(forKey: PlayerGuidePreference.hasSeenKey)
    }

    private func markPlayerGuideSeen() {
        // 用户真正打开右侧播放器后才完成引导，避免未播放时误消耗提示。
        playerGuideDefaults.set(true, forKey: PlayerGuidePreference.hasSeenKey)
        playerGuideView.isHidden = true
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

/// 气泡底部的向下三角箭头；独立视图便于在尺寸变化后重新绘制清晰路径。
private final class PlayerGuideArrowView: UIView {
    override class var layerClass: AnyClass { CAShapeLayer.self }

    private var shapeLayer: CAShapeLayer {
        guard let shapeLayer = layer as? CAShapeLayer else {
            preconditionFailure("PlayerGuideArrowView 必须使用 CAShapeLayer")
        }
        return shapeLayer
    }

    init() {
        super.init(frame: .zero)
        accessibilityIdentifier = "pad.playerGuide.arrow"
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PlayerGuideArrowView 仅支持纯代码初始化")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let path = UIBezierPath()
        path.move(to: CGPoint(x: bounds.minX, y: bounds.minY))
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.minY))
        path.addLine(to: CGPoint(x: bounds.midX, y: bounds.maxY))
        path.close()

        shapeLayer.path = path.cgPath
        shapeLayer.fillColor = Theme.accent.withAlphaComponent(0.12).cgColor
        shapeLayer.lineJoin = .round
    }
}
