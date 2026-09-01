import Combine
import SnapKit
import UIKit

/// 单个播放列表的歌曲页；播放仍由根容器注入的现有队列 closure 处理。
final class PlaylistTracksViewController: UIViewController,
    UICollectionViewDataSource,
    UICollectionViewDelegateFlowLayout {
    let playlistID: String
    private(set) var tracks = [MusicTrack]()

    private let viewModel: PlaylistViewModel
    private let onPlay: (([MusicTrack], Int) -> Void)?
    private let playAllButton = UIButton(type: .system)
    private let shuffleButton = UIButton(type: .system)
    private let emptyLabel = UILabel()
    private let actionsStack = UIStackView()
    private var collectionView: UICollectionView!
    private var cancellable: AnyCancellable?

    init(
        playlistID: String,
        viewModel: PlaylistViewModel,
        onPlay: (([MusicTrack], Int) -> Void)?
    ) {
        self.playlistID = playlistID
        self.viewModel = viewModel
        self.onPlay = onPlay
        tracks = viewModel.tracks(for: playlistID)
        super.init(nibName: nil, bundle: nil)
        title = viewModel.playlists.first(where: { $0.id == playlistID })?.name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PlaylistTracksViewController 仅支持纯代码初始化")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        configureActions()
        configureCollectionView()
        configureEmptyState()
        bindViewModel()
        refreshContent()
    }

    func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        tracks.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: TrackCell.reuseIdentifier,
            for: indexPath
        ) as! TrackCell
        cell.configure(with: tracks[indexPath.item])
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let resolvedTracks = viewModel.tracks(for: playlistID)
        guard resolvedTracks.indices.contains(indexPath.item) else { return }
        onPlay?(resolvedTracks, indexPath.item)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        CGSize(width: collectionView.bounds.width, height: 66)
    }

    private func configureActions() {
        configureActionButton(
            playAllButton,
            title: L10n.text("list.play_all"),
            identifier: "playlist.playAll"
        ) { [weak self] in
            guard let self else { return }
            let resolvedTracks = viewModel.tracks(for: playlistID)
            guard resolvedTracks.isEmpty == false else { return }
            onPlay?(resolvedTracks, 0)
        }
        configureActionButton(
            shuffleButton,
            title: L10n.text("list.shuffle"),
            identifier: "playlist.shuffle"
        ) { [weak self] in
            guard let self else { return }
            let resolvedTracks = viewModel.tracks(for: playlistID)
            guard resolvedTracks.isEmpty == false else { return }
            onPlay?(resolvedTracks.shuffled(), 0)
        }
        actionsStack.addArrangedSubview(playAllButton)
        actionsStack.addArrangedSubview(shuffleButton)
        actionsStack.axis = .horizontal
        actionsStack.distribution = .fillEqually
        actionsStack.spacing = 8
        view.addSubview(actionsStack)
        actionsStack.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(12)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(16)
            make.height.greaterThanOrEqualTo(44)
        }
    }

    private func configureActionButton(
        _ button: UIButton,
        title: String,
        identifier: String,
        action: @escaping () -> Void
    ) {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.baseForegroundColor = Theme.accent
        button.configuration = configuration
        button.accessibilityIdentifier = identifier
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }

    private func configureCollectionView() {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 6
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = Theme.background
        collectionView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 78, right: 0)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(TrackCell.self, forCellWithReuseIdentifier: TrackCell.reuseIdentifier)
        view.addSubview(collectionView)
        collectionView.snp.makeConstraints { make in
            make.top.equalTo(actionsStack.snp.bottom).offset(12)
            make.leading.trailing.bottom.equalTo(view.safeAreaLayoutGuide)
        }
    }

    private func configureEmptyState() {
        emptyLabel.text = L10n.text("playlist.empty")
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.accessibilityIdentifier = "playlist.empty"
        view.addSubview(emptyLabel)
        emptyLabel.snp.makeConstraints { make in
            make.center.equalTo(collectionView)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(28)
        }
    }

    private func bindViewModel() {
        cancellable = viewModel.$playlists
            .combineLatest(viewModel.$resolutionRevision)
            .sink { [weak self] _, _ in
                self?.refreshContent()
            }
    }

    private func refreshContent() {
        guard isViewLoaded else { return }
        title = viewModel.playlists.first(where: { $0.id == playlistID })?.name
        tracks = viewModel.tracks(for: playlistID)
        let isEmpty = tracks.isEmpty
        playAllButton.isEnabled = !isEmpty
        shuffleButton.isEnabled = !isEmpty
        emptyLabel.isHidden = !isEmpty
        collectionView.reloadData()
    }
}
