import Combine
import SnapKit
import UIKit

/// 资料库首页：展示真实来源状态、分类入口和当前统一歌曲列表。
final class LibraryViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    let viewModel: LibraryViewModel
    var onSelectTrack: (([MusicTrack], Int) -> Void)?
    var onDeleteTrack: ((MusicTrack) -> Void)?
    var onDownload: (() -> Void)?
    var onSettings: (() -> Void)?

    private var collectionView: UICollectionView!
    private var sections = [Section]()
    private var cancellable: AnyCancellable?

    init(viewModel: LibraryViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LibraryViewController 仅支持纯代码初始化")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "资料库"
        navigationController?.navigationBar.prefersLargeTitles = true
        view.backgroundColor = Theme.background
        configureNavigationActions()
        buildCollectionView()
        bindViewModel()
        rebuildSections()
    }

    private func configureNavigationActions() {
        let download = navigationButton(
            symbol: "arrow.down.circle",
            accessibilityLabel: "下载音频",
            action: { [weak self] in self?.onDownload?() }
        )
        let settings = navigationButton(
            symbol: "gearshape",
            accessibilityLabel: "打开设置",
            action: { [weak self] in self?.onSettings?() }
        )
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(customView: settings),
            UIBarButtonItem(customView: download)
        ]
    }

    private func navigationButton(
        symbol: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
        configuration.baseForegroundColor = Theme.accent
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = accessibilityLabel
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        button.snp.makeConstraints { make in
            make.width.height.greaterThanOrEqualTo(44)
        }
        return button
    }

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        sections.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        sections[section].items.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        switch sections[indexPath.section].items[indexPath.item] {
        case let .notice(message, symbol):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: InfoCell.reuseIdentifier,
                for: indexPath
            ) as! InfoCell
            cell.configure(message: message, symbol: symbol)
            return cell
        case let .category(category, symbol):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: CategoryCell.reuseIdentifier,
                for: indexPath
            ) as! CategoryCell
            cell.configure(title: category.title, symbol: symbol)
            return cell
        case let .track(track):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: TrackCell.reuseIdentifier,
                for: indexPath
            ) as! TrackCell
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
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind,
            withReuseIdentifier: SectionHeader.reuseIdentifier,
            for: indexPath
        ) as! SectionHeader
        header.configure(title: sections[indexPath.section].title)
        return header
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let section = sections[indexPath.section]
        switch section.items[indexPath.item] {
        case let .category(category, _):
            let list = TrackListViewController(
                category: category,
                viewModel: viewModel,
                onPlay: onSelectTrack
            )
            list.onDelete = onDeleteTrack
            navigationController?.pushViewController(list, animated: true)
        case .track:
            guard section.kind == .recentAdded else { return }
            let queue = section.items.compactMap { item -> MusicTrack? in
                guard case let .track(track) = item else { return nil }
                return track
            }
            guard queue.indices.contains(indexPath.item) else { return }
            onSelectTrack?(queue, indexPath.item)
        case .notice:
            break
        }
    }

    private func buildCollectionView() {
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.backgroundColor = Theme.background
        collectionView.alwaysBounceVertical = true
        collectionView.contentInset.bottom = 78
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(TrackCell.self, forCellWithReuseIdentifier: TrackCell.reuseIdentifier)
        collectionView.register(InfoCell.self, forCellWithReuseIdentifier: InfoCell.reuseIdentifier)
        collectionView.register(CategoryCell.self, forCellWithReuseIdentifier: CategoryCell.reuseIdentifier)
        collectionView.register(
            SectionHeader.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: SectionHeader.reuseIdentifier
        )
        view.addSubview(collectionView)
        collectionView.snp.makeConstraints { make in
            make.edges.equalTo(view.safeAreaLayoutGuide)
        }
    }

    private func bindViewModel() {
        cancellable = Publishers.CombineLatest4(
            viewModel.$tracks,
            viewModel.$systemState,
            viewModel.$localState,
            viewModel.$storageWarning
        ).sink { [weak self] _, _, _, _ in
            self?.rebuildSections()
        }
    }

    private func rebuildSections() {
        var next = [Section]()
        let messages = statusMessages()
        if !messages.isEmpty {
            next.append(Section(kind: .notices, title: nil, items: messages))
        }
        next.append(
            Section(
                kind: .categories,
                title: nil,
                items: [
                    .category(.songs, "music.note"),
                    .category(.albums, "square.stack"),
                    .category(.artists, "person.2"),
                    .category(.downloaded, "arrow.down.circle")
                ]
            )
        )
        next.append(
            Section(
                kind: .recentAdded,
                title: "最近添加",
                items: viewModel.tracks.map(Item.track)
            )
        )
        sections = next
        collectionView?.reloadData()
        collectionView?.collectionViewLayout.invalidateLayout()
    }

    private func statusMessages() -> [Item] {
        var messages = [Item]()
        if let storageWarning = viewModel.storageWarning {
            messages.append(.notice(storageWarning, "externaldrive.badge.exclamationmark"))
        }
        switch viewModel.systemState {
        case .permissionRequired:
            messages.append(.notice("尚未授权系统音乐资料库，只显示已下载歌曲。", "lock"))
        case let .failed(message):
            messages.append(.notice(message, "exclamationmark.triangle"))
        default:
            break
        }
        if case let .failed(message) = viewModel.localState {
            messages.append(.notice(message, "exclamationmark.triangle"))
        }

        let finishedSystem = ![.idle, .loading].contains(viewModel.systemState)
        let finishedLocal = ![.idle, .loading].contains(viewModel.localState)
        if viewModel.tracks.isEmpty, finishedSystem, finishedLocal {
            messages.append(
                .notice("资料库还是空的\n授权系统音乐或添加本地音频后会显示在这里。", "music.note.list")
            )
        }
        return messages
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, _ in
            guard let self, sections.indices.contains(sectionIndex) else { return nil }
            let section = sections[sectionIndex]
            let layoutSection: NSCollectionLayoutSection

            switch section.kind {
            case .categories:
                let item = NSCollectionLayoutItem(
                    layoutSize: NSCollectionLayoutSize(
                        widthDimension: .fractionalWidth(0.25),
                        heightDimension: .fractionalHeight(1)
                    )
                )
                item.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: NSCollectionLayoutSize(
                        widthDimension: .fractionalWidth(1),
                        heightDimension: .absolute(82)
                    ),
                    subitems: [item]
                )
                layoutSection = NSCollectionLayoutSection(group: group)
            case .recentAdded:
                layoutSection = Self.verticalSection(estimatedHeight: 66, spacing: 6)
            case .notices:
                layoutSection = Self.verticalSection(estimatedHeight: 76, spacing: 8)
            }

            layoutSection.contentInsets = NSDirectionalEdgeInsets(
                top: section.title == nil ? 8 : 0,
                leading: 16,
                bottom: 16,
                trailing: 16
            )
            if section.title != nil {
                layoutSection.boundarySupplementaryItems = [Self.headerItem()]
            }
            return layoutSection
        }
    }

    private static func verticalSection(
        estimatedHeight: CGFloat,
        spacing: CGFloat
    ) -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(estimatedHeight)
            )
        )
        let group = NSCollectionLayoutGroup.vertical(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(estimatedHeight)
            ),
            subitems: [item]
        )
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = spacing
        return section
    }

    private static func headerItem() -> NSCollectionLayoutBoundarySupplementaryItem {
        NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .absolute(42)
            ),
            elementKind: UICollectionView.elementKindSectionHeader,
            alignment: .top
        )
    }
}

private extension LibraryViewController {
    enum SectionKind {
        case notices
        case categories
        case recentAdded
    }

    enum Item {
        case notice(String, String)
        case category(LibraryCategory, String)
        case track(MusicTrack)
    }

    struct Section {
        let kind: SectionKind
        let title: String?
        let items: [Item]
    }
}

private final class InfoCell: UICollectionViewCell {
    static let reuseIdentifier = "LibraryInfoCell"
    private let iconView = UIImageView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.surface
        layer.cornerRadius = Theme.cardRadius
        iconView.tintColor = Theme.accent
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textColor = .secondaryLabel
        contentView.addSubview(iconView)
        contentView.addSubview(label)
        iconView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(14)
            make.centerY.equalToSuperview()
            make.size.equalTo(24)
        }
        label.snp.makeConstraints { make in
            make.leading.equalTo(iconView.snp.trailing).offset(12)
            make.trailing.equalToSuperview().inset(14)
            make.top.bottom.equalToSuperview().inset(14)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("InfoCell 仅支持纯代码初始化") }

    func configure(message: String, symbol: String) {
        label.text = message
        iconView.image = UIImage(systemName: symbol)
        accessibilityLabel = message
    }
}

private final class CategoryCell: UICollectionViewCell {
    static let reuseIdentifier = "LibraryCategoryCell"
    private let iconView = UIImageView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.surface
        layer.cornerRadius = Theme.cardRadius
        iconView.tintColor = Theme.accent
        iconView.contentMode = .scaleAspectFit
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        contentView.addSubview(iconView)
        contentView.addSubview(label)
        iconView.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(13)
            make.centerX.equalToSuperview()
            make.size.equalTo(24)
        }
        label.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(4)
            make.top.equalTo(iconView.snp.bottom).offset(8)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("CategoryCell 仅支持纯代码初始化") }

    func configure(title: String, symbol: String) {
        label.text = title
        iconView.image = UIImage(systemName: symbol)
        accessibilityLabel = title
    }
}

private final class SectionHeader: UICollectionReusableView {
    static let reuseIdentifier = "LibrarySectionHeader"
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .title3)
        label.adjustsFontForContentSizeCategory = true
        addSubview(label)
        label.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SectionHeader 仅支持纯代码初始化") }

    func configure(title: String?) {
        label.text = title
    }
}
