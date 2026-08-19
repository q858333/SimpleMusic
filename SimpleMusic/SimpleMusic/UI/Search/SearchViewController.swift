import Combine
import SnapKit
import UIKit

/// 只在共享资料库列表中即时筛选；选择后把准确队列和索引交给播放协调器上层。
final class SearchViewController: UIViewController,
    UICollectionViewDataSource,
    UICollectionViewDelegate,
    UISearchResultsUpdating {
    let viewModel: LibraryViewModel
    var onSelectTrack: (([MusicTrack], Int) -> Void)?
    var onDeleteTrack: ((MusicTrack) -> Void)?

    let searchController = UISearchController(searchResultsController: nil)
    private(set) var collectionView: UICollectionView!
    private var results = [MusicTrack]()
    private var cancellable: AnyCancellable?

    private let emptyLabel: UILabel = {
        let label = UILabel()
        label.accessibilityIdentifier = "search.empty"
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    init(viewModel: LibraryViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SearchViewController 仅支持纯代码初始化")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "搜索"
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
        cell.configure(with: track)
        if case .downloaded = track.source {
            cell.onMore = { [weak self] in
                self?.presentLocalTrackDeletionPrompt(for: track) {
                    self?.onDeleteTrack?(track)
                }
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
        searchController.searchBar.placeholder = "搜索歌曲、艺人或专辑"
        searchController.searchBar.accessibilityLabel = "搜索歌曲、艺人或专辑"
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
        view.addSubview(emptyLabel)
        collectionView.snp.makeConstraints { make in
            make.edges.equalTo(view.safeAreaLayoutGuide)
        }
        emptyLabel.snp.makeConstraints { make in
            make.center.equalTo(view.safeAreaLayoutGuide)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(32)
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
        emptyLabel.text = query.isEmpty ? "资料库中没有歌曲" : "没有找到匹配的歌曲"
        emptyLabel.isHidden = !results.isEmpty
    }
}
