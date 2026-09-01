import Combine
import SnapKit
import UIKit

enum LibraryCategory: Equatable {
    case songs
    case albums
    case artists
    case downloaded
    case album(String)
    case artist(String)

    var title: String {
        switch self {
        case .songs: return L10n.text("category.songs")
        case .albums: return L10n.text("category.albums")
        case .artists: return L10n.text("category.artists")
        case .downloaded: return L10n.text("category.downloaded")
        case let .album(name), let .artist(name): return name
        }
    }

    var isGrouped: Bool {
        self == .albums || self == .artists
    }

    func filteredTracks(from tracks: [MusicTrack]) -> [MusicTrack] {
        switch self {
        case .songs, .albums, .artists:
            return tracks
        case .downloaded:
            return tracks.filter { if case .downloaded = $0.source { return true }; return false }
        case let .album(name):
            return tracks.filter { $0.album == name }
        case let .artist(name):
            return tracks.filter { $0.artist == name }
        }
    }

    func child(named name: String) -> LibraryCategory? {
        switch self {
        case .albums: return .album(name)
        case .artists: return .artist(name)
        default: return nil
        }
    }
}

/// 四个资料库入口共享的列表容器；后续动作都基于同一份 MusicTrack 队列。
final class TrackListViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    let category: LibraryCategory
    let playlistViewModel: PlaylistViewModel?
    private(set) var tracks: [MusicTrack]
    var onPlay: (([MusicTrack], Int) -> Void)?
    var onDelete: ((MusicTrack) -> Void)?

    private let viewModel: LibraryViewModel?
    private var groups = [(name: String, tracks: [MusicTrack])]()
    private var sortKey = SortKey.album
    private var hasSelectedSort = false
    private var collectionView: UICollectionView!
    private var cancellable: AnyCancellable?

    init(
        category: LibraryCategory,
        title: String? = nil,
        tracks: [MusicTrack],
        playlistViewModel: PlaylistViewModel? = nil,
        onPlay: (([MusicTrack], Int) -> Void)?
    ) {
        self.category = category
        self.playlistViewModel = playlistViewModel
        viewModel = nil
        self.tracks = category.filteredTracks(from: tracks)
        self.onPlay = onPlay
        super.init(nibName: nil, bundle: nil)
        self.title = title ?? category.title
        rebuildGroups()
    }

    init(
        category: LibraryCategory,
        viewModel: LibraryViewModel,
        playlistViewModel: PlaylistViewModel? = nil,
        onPlay: (([MusicTrack], Int) -> Void)?
    ) {
        self.category = category
        self.playlistViewModel = playlistViewModel
        self.viewModel = viewModel
        tracks = category.filteredTracks(from: viewModel.tracks)
        self.onPlay = onPlay
        super.init(nibName: nil, bundle: nil)
        title = category.title
        rebuildGroups()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TrackListViewController 仅支持纯代码初始化")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        buildActionsAndList()
        bindViewModel()
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        isGrouped ? groups.count : tracks.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        if isGrouped {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: TrackGroupCell.reuseIdentifier,
                for: indexPath
            ) as! TrackGroupCell
            let group = groups[indexPath.item]
            cell.configure(title: group.name, count: group.tracks.count)
            return cell
        }

        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: TrackCell.reuseIdentifier,
            for: indexPath
        ) as! TrackCell
        let track = tracks[indexPath.item]
        cell.configure(with: track)
        if playlistViewModel != nil || track.isDownloaded {
            cell.onMore = { [weak self] in
                self?.presentTrackMoreActions(
                    for: track,
                    playlistViewModel: self?.playlistViewModel,
                    onDelete: { [weak self] in self?.onDelete?(track) }
                )
            }
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if isGrouped {
            let group = groups[indexPath.item]
            guard let childCategory = category.child(named: group.name) else { return }
            let list: TrackListViewController
            if let viewModel {
                list = TrackListViewController(
                    category: childCategory,
                    viewModel: viewModel,
                    playlistViewModel: playlistViewModel,
                    onPlay: onPlay
                )
            } else {
                list = TrackListViewController(
                    category: childCategory,
                    tracks: tracks,
                    playlistViewModel: playlistViewModel,
                    onPlay: onPlay
                )
            }
            list.onDelete = onDelete
            navigationController?.pushViewController(list, animated: true)
        } else {
            onPlay?(tracks, indexPath.item)
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        CGSize(width: collectionView.bounds.width, height: isGrouped ? 58 : 66)
    }

    private var isGrouped: Bool {
        category.isGrouped
    }

    private func buildActionsAndList() {
        let playAll = actionButton(title: L10n.text("list.play_all"), identifier: "list.playAll") { [weak self] in
            guard let self, !tracks.isEmpty else { return }
            onPlay?(tracks, 0)
        }
        let shuffle = actionButton(title: L10n.text("list.shuffle"), identifier: "list.shuffle") { [weak self] in
            guard let self, !tracks.isEmpty else { return }
            onPlay?(tracks.shuffled(), 0)
        }
        let sort = actionButton(title: L10n.text("list.sort"), identifier: "list.sort") { [weak self] in
            self?.sortTracks()
        }
        let actions = UIStackView(arrangedSubviews: [playAll, shuffle, sort])
        actions.axis = .horizontal
        actions.distribution = .fillEqually
        actions.spacing = 8

        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 6
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = Theme.background
        collectionView.contentInset.bottom = 24
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(TrackCell.self, forCellWithReuseIdentifier: TrackCell.reuseIdentifier)
        collectionView.register(
            TrackGroupCell.self,
            forCellWithReuseIdentifier: TrackGroupCell.reuseIdentifier
        )

        view.addSubview(actions)
        view.addSubview(collectionView)
        actions.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(12)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(16)
            make.height.greaterThanOrEqualTo(44)
        }
        collectionView.snp.makeConstraints { make in
            make.top.equalTo(actions.snp.bottom).offset(12)
            make.leading.trailing.bottom.equalTo(view.safeAreaLayoutGuide)
        }
    }

    private func actionButton(
        title: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> UIButton {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.baseForegroundColor = Theme.accent
        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = title
        Theme.installPressFeedback(on: button)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func sortTracks() {
        sortKey = sortKey.next
        hasSelectedSort = true
        applySelectedSort()
        rebuildGroups()
        collectionView.reloadData()
    }

    private func bindViewModel() {
        guard let viewModel else { return }
        cancellable = viewModel.$tracks.sink { [weak self] tracks in
            self?.replaceTracks(with: tracks)
        }
    }

    private func replaceTracks(with allTracks: [MusicTrack]) {
        tracks = category.filteredTracks(from: allTracks)
        applySelectedSort()
        rebuildGroups()
        collectionView?.reloadData()
    }

    private func applySelectedSort() {
        guard hasSelectedSort else { return }
        tracks.sort { lhs, rhs in
            sortKey.value(for: lhs).localizedCaseInsensitiveCompare(sortKey.value(for: rhs)) == .orderedAscending
        }
    }

    private func rebuildGroups() {
        guard isGrouped else {
            groups = []
            return
        }
        let grouped = Dictionary(grouping: tracks) { track in
            category == .albums ? track.album : track.artist
        }
        groups = grouped.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { ($0, grouped[$0] ?? []) }
    }

    private enum SortKey {
        case title
        case artist
        case album

        var next: SortKey {
            switch self {
            case .title: return .artist
            case .artist: return .album
            case .album: return .title
            }
        }

        func value(for track: MusicTrack) -> String {
            switch self {
            case .title: return track.title
            case .artist: return track.artist
            case .album: return track.album
            }
        }
    }
}

private final class TrackGroupCell: UICollectionViewCell {
    static let reuseIdentifier = "TrackGroupCell"
    private let titleLabel = UILabel()
    private let countLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.surface
        layer.cornerRadius = 12
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        countLabel.font = .preferredFont(forTextStyle: .caption1)
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.textColor = .secondaryLabel
        contentView.addSubview(titleLabel)
        contentView.addSubview(countLabel)
        titleLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(14)
            make.centerY.equalToSuperview()
        }
        countLabel.snp.makeConstraints { make in
            make.leading.greaterThanOrEqualTo(titleLabel.snp.trailing).offset(8)
            make.trailing.equalToSuperview().inset(14)
            make.centerY.equalToSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TrackGroupCell 仅支持纯代码初始化")
    }

    func configure(title: String, count: Int) {
        titleLabel.text = title
        let countText = L10n.plural("tracks.count", count: count)
        countLabel.text = countText
        accessibilityLabel = L10n.format("track_group.accessibility", title, countText)
    }
}
