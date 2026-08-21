import Combine
import SnapKit
import UIKit

/// 展示应用级下载队列；页面生命周期不会控制下载任务生命周期。
@MainActor
final class DownloadSheetViewController: UIViewController, UITextFieldDelegate, UIAdaptivePresentationControllerDelegate {
    let downloadQueue: DownloadQueue

    private var jobs = [DownloadJob]()
    private var cancellables = Set<AnyCancellable>()
    private let urlField = UITextField()
    private let inputErrorLabel = UILabel()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()

    init(downloadQueue: DownloadQueue) {
        self.downloadQueue = downloadQueue
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DownloadSheetViewController 仅支持纯代码初始化")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.text("download.title")
        view.backgroundColor = Theme.background
        buildInterface()
        bindQueue()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentationController?.delegate = self
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        // 页面消失只停止 UI 观察，下载继续由应用级队列持有。
        cancellables.removeAll()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        enqueueInput()
        return true
    }

    private func buildInterface() {
        let closeButton = makeButton(title: L10n.text("common.cancel"), identifier: "download.close")
        closeButton.addAction(UIAction { [weak self] _ in
            self?.cancellables.removeAll()
            self?.dismiss(animated: true)
        }, for: .touchUpInside)
        navigationItem.leftBarButtonItem = UIBarButtonItem(customView: closeButton)

        urlField.accessibilityIdentifier = "download.url"
        urlField.accessibilityLabel = L10n.text("download.url_accessibility")
        urlField.placeholder = L10n.text("download.url_placeholder")
        urlField.keyboardType = .URL
        urlField.returnKeyType = .go
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.clearButtonMode = .whileEditing
        urlField.borderStyle = .roundedRect
        urlField.font = .preferredFont(forTextStyle: .body)
        urlField.adjustsFontForContentSizeCategory = true
        urlField.delegate = self
        urlField.snp.makeConstraints { make in make.height.greaterThanOrEqualTo(48) }

        let helpLabel = makeLabel(
            text: L10n.text("download.direct_only"),
            style: .footnote,
            color: .secondaryLabel
        )
        inputErrorLabel.accessibilityIdentifier = "download.input.error"
        inputErrorLabel.font = .preferredFont(forTextStyle: .footnote)
        inputErrorLabel.adjustsFontForContentSizeCategory = true
        inputErrorLabel.textColor = .systemRed
        inputErrorLabel.numberOfLines = 0
        inputErrorLabel.isHidden = true

        let addButton = makeButton(
            title: L10n.text("download.queue.add"),
            identifier: "download.submit",
            primary: true
        )
        addButton.addAction(UIAction { [weak self] _ in self?.enqueueInput() }, for: .touchUpInside)

        let inputStack = UIStackView(arrangedSubviews: [urlField, helpLabel, inputErrorLabel, addButton])
        inputStack.axis = .vertical
        inputStack.spacing = 10

        emptyLabel.text = L10n.text("download.queue.empty")
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0

        tableView.accessibilityIdentifier = "download.jobs"
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.keyboardDismissMode = .interactive
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 150
        tableView.register(DownloadJobCell.self, forCellReuseIdentifier: DownloadJobCell.reuseIdentifier)
        tableView.dataSource = self
        tableView.backgroundView = emptyLabel

        view.addSubview(inputStack)
        view.addSubview(tableView)
        inputStack.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(16)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(20)
        }
        tableView.snp.makeConstraints { make in
            make.top.equalTo(inputStack.snp.bottom).offset(12)
            make.leading.trailing.bottom.equalTo(view.safeAreaLayoutGuide)
        }
    }

    private func bindQueue() {
        downloadQueue.jobsPublisher
            .sink { [weak self] jobs in
                guard let self else { return }
                self.jobs = jobs
                self.emptyLabel.isHidden = !jobs.isEmpty
                self.tableView.reloadData()
            }
            .store(in: &cancellables)
    }

    private func enqueueInput() {
        let input = urlField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        urlField.resignFirstResponder()
        guard let url = URL(string: input), url.scheme != nil else {
            showInputError(L10n.text("download.error.invalid_url"))
            return
        }

        do {
            _ = try downloadQueue.enqueue(url)
            urlField.text = nil
            inputErrorLabel.text = nil
            inputErrorLabel.isHidden = true
        } catch DownloadError.unsupportedURL {
            showInputError(L10n.text("download.error.unsupported_url"))
        } catch {
            showInputError(L10n.text("download.error.generic"))
        }
    }

    private func showInputError(_ message: String) {
        inputErrorLabel.text = message
        inputErrorLabel.isHidden = false
    }

    private func makeLabel(text: String, style: UIFont.TextStyle, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    private func makeButton(title: String, identifier: String, primary: Bool = false) -> UIButton {
        var configuration = primary ? UIButton.Configuration.filled() : .gray()
        configuration.title = title
        configuration.baseBackgroundColor = primary ? Theme.accent : nil
        configuration.cornerStyle = .medium
        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = identifier
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.snp.makeConstraints { make in make.height.greaterThanOrEqualTo(44) }
        return button
    }
}

extension DownloadSheetViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        jobs.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: DownloadJobCell.reuseIdentifier,
            for: indexPath
        ) as? DownloadJobCell else {
            return UITableViewCell()
        }
        let job = jobs[indexPath.row]
        cell.render(job: job)
        // 回调始终携带任务 ID，列表排序或删除不会把操作投递给别的行。
        cell.onCancel = { [weak downloadQueue] id in downloadQueue?.cancel(id: id) }
        cell.onRetry = { [weak downloadQueue] id in downloadQueue?.retry(id: id) }
        cell.onRemove = { [weak downloadQueue] id in downloadQueue?.remove(id: id) }
        cell.onPlay = { [weak downloadQueue] id in downloadQueue?.play(id: id) }
        return cell
    }
}
