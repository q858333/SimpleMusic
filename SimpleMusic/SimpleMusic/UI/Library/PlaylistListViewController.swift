import Combine
import SnapKit
import UIKit

/// 播放列表目录：所有增删改均通过应用级共享 PlaylistViewModel 完成。
final class PlaylistListViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    let viewModel: PlaylistViewModel

    private let onPlay: (([MusicTrack], Int) -> Void)?
    private let downloadFeatureEnabled: Bool
    private var playlists: [Playlist]
    private var cancellable: AnyCancellable?
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    init(
        viewModel: PlaylistViewModel,
        onPlay: (([MusicTrack], Int) -> Void)?,
        downloadFeatureEnabled: Bool = true
    ) {
        self.viewModel = viewModel
        self.onPlay = onPlay
        self.downloadFeatureEnabled = downloadFeatureEnabled
        playlists = viewModel.playlists
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PlaylistListViewController 仅支持纯代码初始化")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.text("playlist.title")
        view.backgroundColor = Theme.background
        configureCreateButton()
        configureTableView()
        bindViewModel()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        playlists.count
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let reuseIdentifier = "PlaylistCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: reuseIdentifier)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: reuseIdentifier)
        let playlist = playlists[indexPath.row]
        let trackCount = viewModel.tracks(for: playlist.id).count
        cell.textLabel?.text = playlist.name
        cell.detailTextLabel?.text = L10n.plural("tracks.count", count: trackCount)
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityLabel = L10n.format(
            "track_group.accessibility",
            playlist.name,
            L10n.plural("tracks.count", count: trackCount)
        )
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard playlists.indices.contains(indexPath.row) else { return }
        let list = PlaylistTracksViewController(
            playlistID: playlists[indexPath.row].id,
            viewModel: viewModel,
            onPlay: onPlay,
            downloadFeatureEnabled: downloadFeatureEnabled
        )
        navigationController?.pushViewController(list, animated: true)
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard playlists.indices.contains(indexPath.row) else { return nil }
        let rename = UIContextualAction(style: .normal, title: L10n.text("playlist.rename")) {
            [weak self] _, _, completion in
            self?.presentRenamePrompt(at: indexPath.row)
            completion(true)
        }
        rename.backgroundColor = Theme.accent
        let delete = UIContextualAction(style: .destructive, title: L10n.text("common.delete")) {
            [weak self] _, _, completion in
            self?.deletePlaylist(at: indexPath.row)
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [delete, rename])
    }

    func presentRenamePrompt(at index: Int) {
        guard playlists.indices.contains(index) else { return }
        let playlist = playlists[index]
        presentNamePrompt(
            title: L10n.text("playlist.rename"),
            initialName: playlist.name
        ) { [weak viewModel] name in
            try viewModel?.renamePlaylist(id: playlist.id, name: name)
        }
    }

    func deletePlaylist(at index: Int) {
        guard playlists.indices.contains(index) else { return }
        do {
            try viewModel.deletePlaylist(id: playlists[index].id)
        } catch {
            presentError(error)
        }
    }

    private func configureCreateButton() {
        var configuration = UIButton.Configuration.plain()
        configuration.title = L10n.text("playlist.new")
        configuration.image = UIImage(systemName: "plus")
        configuration.imagePadding = 6
        configuration.baseForegroundColor = .label
        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = "playlist.new"
        button.addAction(UIAction { [weak self] _ in
            self?.presentCreatePrompt()
        }, for: .touchUpInside)
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: button)
    }

    private func configureTableView() {
        tableView.backgroundColor = Theme.background
        tableView.dataSource = self
        tableView.delegate = self
        tableView.contentInset.bottom = 78
        view.addSubview(tableView)
        tableView.snp.makeConstraints { make in
            make.edges.equalTo(view.safeAreaLayoutGuide)
        }
    }

    private func bindViewModel() {
        cancellable = viewModel.$playlists
            .combineLatest(viewModel.$resolutionRevision)
            .sink { [weak self] playlists, _ in
                self?.playlists = playlists
                self?.tableView.reloadData()
            }
    }

    private func presentCreatePrompt() {
        presentNamePrompt(
            title: L10n.text("playlist.new"),
            initialName: nil
        ) { [weak viewModel] name in
            _ = try viewModel?.createPlaylist(named: name)
        }
    }

    private func presentNamePrompt(
        title: String,
        initialName: String?,
        commit: @escaping (String) throws -> Void
    ) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.text = initialName
            textField.placeholder = L10n.text("playlist.name_placeholder")
            textField.clearButtonMode = .whileEditing
            textField.returnKeyType = .done
        }

        let submit = { [weak self, weak alert] in
            guard let self, let alert, let name = alert.textFields?.first?.text else { return }
            do {
                try commit(name)
                alert.dismiss(animated: false)
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
            message: message(for: error),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.text("common.done"), style: .default))
        present(alert, animated: true)
    }

    private func message(for error: Error) -> String {
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
