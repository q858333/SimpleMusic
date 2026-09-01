import Combine
import SnapKit
import UIKit

extension MusicTrack {
    var isDownloaded: Bool {
        if case .downloaded = source { return true }
        return false
    }
}

/// 资料库、分类和搜索共用的播放列表选择页。
final class PlaylistSelectionViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    let viewModel: PlaylistViewModel

    private let track: MusicTrack
    private var playlists: [Playlist]
    private var cancellable: AnyCancellable?
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let emptyLabel = UILabel()
    private let titleLabel = UILabel()

    init(track: MusicTrack, viewModel: PlaylistViewModel) {
        self.track = track
        self.viewModel = viewModel
        playlists = viewModel.playlists
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PlaylistSelectionViewController 仅支持纯代码初始化")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.text("playlist.add")
        view.backgroundColor = Theme.background
        configureTitle()
        configureTableView()
        configureEmptyState()
        configureCreateButton()
        bindViewModel()
        refreshContent()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        playlists.count
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let reuseIdentifier = "PlaylistSelectionCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: reuseIdentifier)
            ?? UITableViewCell(style: .default, reuseIdentifier: reuseIdentifier)
        cell.textLabel?.text = playlists[indexPath.row].name
        cell.accessoryType = .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard playlists.indices.contains(indexPath.row) else { return }
        select(playlistID: playlists[indexPath.row].id)
    }

    func select(playlistID: String) {
        guard playlists.contains(where: { $0.id == playlistID }) else { return }
        do {
            try viewModel.add(track, to: playlistID)
            dismiss(animated: true)
        } catch {
            presentError(error)
        }
    }

    private func configureTitle() {
        titleLabel.text = L10n.text("playlist.add")
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        view.addSubview(titleLabel)
        titleLabel.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(20)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(20)
        }
    }

    private func configureTableView() {
        tableView.backgroundColor = Theme.background
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)
        tableView.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(12)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide)
        }
    }

    private func configureEmptyState() {
        emptyLabel.text = L10n.text("playlist.selection.empty")
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.accessibilityIdentifier = "playlist.selection.empty"
        view.addSubview(emptyLabel)
        emptyLabel.snp.makeConstraints { make in
            make.center.equalTo(tableView)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(28)
        }
    }

    private func configureCreateButton() {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = L10n.text("playlist.new")
        configuration.image = UIImage(systemName: "plus")
        configuration.imagePadding = 6
        configuration.baseForegroundColor = Theme.accent
        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = "playlist.selection.new"
        button.addAction(UIAction { [weak self] _ in
            self?.presentCreatePrompt()
        }, for: .touchUpInside)
        view.addSubview(button)
        button.snp.makeConstraints { make in
            make.top.equalTo(tableView.snp.bottom).offset(12)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(20)
            make.bottom.equalTo(view.safeAreaLayoutGuide).inset(20)
            make.height.greaterThanOrEqualTo(44)
        }
    }

    private func bindViewModel() {
        cancellable = viewModel.$playlists.sink { [weak self] playlists in
            self?.playlists = playlists
            self?.refreshContent()
        }
    }

    private func refreshContent() {
        guard isViewLoaded else { return }
        tableView.reloadData()
        emptyLabel.isHidden = playlists.isEmpty == false
    }

    private func presentCreatePrompt() {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: L10n.text("playlist.new"),
            message: nil,
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.placeholder = L10n.text("playlist.name_placeholder")
            textField.clearButtonMode = .whileEditing
            textField.returnKeyType = .done
        }
        let submit = { [weak self, weak alert] in
            guard let self, let alert, let name = alert.textFields?.first?.text else { return }
            do {
                let playlist = try viewModel.createPlaylist(named: name)
                try viewModel.add(track, to: playlist.id)
                alert.dismiss(animated: false) { [weak self] in
                    self?.dismiss(animated: true)
                }
            } catch {
                alert.dismiss(animated: false) { [weak self] in
                    self?.presentError(error)
                }
            }
        }
        alert.textFields?.first?.addAction(UIAction { _ in submit() }, for: .editingDidEndOnExit)
        alert.addAction(UIAlertAction(title: L10n.text("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.text("common.done"), style: .default) { _ in
            submit()
        })
        present(alert, animated: false)
    }

    private func presentError(_ error: Error) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: L10n.text("playlist.error.title"),
            message: errorMessage(for: error),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.text("common.done"), style: .default))
        present(alert, animated: true)
    }

    private func errorMessage(for error: Error) -> String {
        switch error as? PlaylistStoreError {
        case .invalidName:
            return L10n.text("playlist.error.invalid_name")
        case .duplicateName:
            return L10n.text("playlist.error.duplicate_name")
        default:
            return L10n.text("playlist.error.save")
        }
    }
}

extension UIViewController {
    /// 系统歌曲直接选择列表；本地歌曲先保留“加入/删除”两种动作。
    func presentTrackMoreActions(
        for track: MusicTrack,
        playlistViewModel: PlaylistViewModel?,
        onDelete: @escaping () -> Void
    ) {
        guard presentedViewController == nil else { return }
        guard case .downloaded = track.source else {
            guard let playlistViewModel else { return }
            present(
                PlaylistSelectionViewController(track: track, viewModel: playlistViewModel),
                animated: true
            )
            return
        }

        guard let playlistViewModel else {
            presentLocalTrackDeletionPrompt(for: track, onConfirm: onDelete)
            return
        }

        let actions = UIAlertController(
            title: track.title,
            message: nil,
            preferredStyle: .actionSheet
        )
        actions.addAction(UIAlertAction(title: L10n.text("playlist.add"), style: .default) {
            [weak self] _ in
            self?.dismiss(animated: true) { [weak self] in
                self?.present(
                    PlaylistSelectionViewController(track: track, viewModel: playlistViewModel),
                    animated: true
                )
            }
        })
        actions.addAction(UIAlertAction(title: L10n.text("deletion.action"), style: .destructive) {
            [weak self] _ in
            self?.dismiss(animated: true) { [weak self] in
                self?.presentLocalTrackDeletionPrompt(for: track, onConfirm: onDelete)
            }
        })
        actions.addAction(UIAlertAction(title: L10n.text("common.cancel"), style: .cancel))
        actions.popoverPresentationController?.sourceView = view
        actions.popoverPresentationController?.sourceRect = CGRect(
            x: view.bounds.midX,
            y: view.bounds.midY,
            width: 1,
            height: 1
        )
        present(actions, animated: true)
    }
}
