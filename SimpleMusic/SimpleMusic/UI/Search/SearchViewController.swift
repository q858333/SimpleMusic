import Combine
import SnapKit
import UIKit

/// 只在共享资料库列表中即时筛选；选择后把准确队列和索引交给播放协调器上层。
final class SearchViewController: UIViewController,
    UICollectionViewDataSource,
    UICollectionViewDelegate,
    UISearchResultsUpdating {
    let viewModel: LibraryViewModel
    let playlistViewModel: PlaylistViewModel?
    let downloadFeatureEnabled: Bool
    var onSelectTrack: (([MusicTrack], Int) -> Void)?
    var onDeleteTrack: ((MusicTrack) -> Void)?

    let searchController = UISearchController(searchResultsController: nil)
    private(set) var collectionView: UICollectionView!
    private var results = [MusicTrack]()
    private var cancellable: AnyCancellable?

    private let emptyStateView = BrandedEmptyStateView(
        identifier: "search.empty.visual",
        artworkIdentifier: "search.empty.artwork",
        messageIdentifier: "search.empty",
        message: L10n.text("search.empty_library")
    )

    init(
        viewModel: LibraryViewModel,
        playlistViewModel: PlaylistViewModel? = nil,
        downloadFeatureEnabled: Bool = true
    ) {
        self.viewModel = viewModel
        self.playlistViewModel = playlistViewModel
        self.downloadFeatureEnabled = downloadFeatureEnabled
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SearchViewController 仅支持纯代码初始化")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.text("search.title")
        view.backgroundColor = Theme.background
        buildSearch()
        buildCollectionView()
        bindViewModel()
        applyCurrentFilter()
    }

    func updateSearchResults(for searchController: UISearchController) {
        applyCurrentFilter()
    }

    func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        results.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: TrackCell.reuseIdentifier,
            for: indexPath
        ) as! TrackCell
        let track = results[indexPath.item]
        cell.configure(with: track, showsDownloadStatus: downloadFeatureEnabled)
        if playlistViewModel != nil || (downloadFeatureEnabled && track.isDownloaded) {
            cell.onMore = { [weak self] in
                self?.presentTrackMoreActions(
                        for: track,
                        playlistViewModel: self?.playlistViewModel,
                        allowsDownloadedTrackDeletion: self?.downloadFeatureEnabled ?? false,
                    onDelete: { [weak self] in self?.onDeleteTrack?(track) }
                )
            }
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard results.indices.contains(indexPath.item) else { return }
        onSelectTrack?(results, indexPath.item)
    }

    private func buildSearch() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = L10n.text("search.placeholder")
        searchController.searchBar.accessibilityLabel = L10n.text("search.placeholder")
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
    }

    private func buildCollectionView() {
        let layout = UICollectionViewCompositionalLayout { _, environment in
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .estimated(66)
                )
            )
            let group = NSCollectionLayoutGroup.vertical(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .estimated(66)
                ),
                subitems: [item]
            )
            group.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 2
            return section
        }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = Theme.background
        collectionView.alwaysBounceVertical = true
        collectionView.contentInset.bottom = 78
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(TrackCell.self, forCellWithReuseIdentifier: TrackCell.reuseIdentifier)

        view.addSubview(collectionView)
        view.addSubview(emptyStateView)
        collectionView.snp.makeConstraints { make in
            make.edges.equalTo(view.safeAreaLayoutGuide)
        }
        emptyStateView.snp.makeConstraints { make in
            make.center.equalTo(view.safeAreaLayoutGuide)
            make.leading.greaterThanOrEqualTo(view.safeAreaLayoutGuide).offset(32)
            make.trailing.lessThanOrEqualTo(view.safeAreaLayoutGuide).offset(-32)
            make.width.lessThanOrEqualTo(280)
        }
    }

    private func bindViewModel() {
        cancellable = viewModel.$tracks.sink { [weak self] _ in
            self?.applyCurrentFilter()
        }
    }

    private func applyCurrentFilter() {
        results = viewModel.filter(query: searchController.searchBar.text ?? "")
        collectionView?.reloadData()
        let query = searchController.searchBar.text?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        emptyStateView.message = L10n.text(query.isEmpty ? "search.empty_library" : "search.no_results")
        emptyStateView.isHidden = !results.isEmpty
    }
}
