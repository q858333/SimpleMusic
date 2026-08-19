import SnapKit
import UIKit

enum DownloadViewState: Equatable {
    case input
    case downloading(progress: Double)
    case success(MusicTrack)
    case failure(message: String)
}

/// 从音频直链下载到现有本地资料库，并隔离取消后迟到的进度与结果。
@MainActor
final class DownloadSheetViewController: UIViewController, UITextFieldDelegate, UIAdaptivePresentationControllerDelegate {
    typealias DownloadOperation = @MainActor (
        URL,
        @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> MusicTrack

    var state: DownloadViewState = .input {
        didSet { renderState() }
    }

    private let download: DownloadOperation
    private let settingsStore: SettingsStore
    private let onReload: @MainActor () -> Void
    private let onPlay: @MainActor (MusicTrack) -> Void
    private var downloadTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?
    private var didConsumeSuccess = false

    private let inputStateView = UIStackView()
    private let downloadingStateView = UIStackView()
    private let successStateView = UIStackView()
    private let failureStateView = UIStackView()
    private let urlField = UITextField()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let progressLabel = UILabel()
    private let successLabel = UILabel()
    private let failureLabel = UILabel()

    init(
        download: @escaping DownloadOperation,
        settingsStore: SettingsStore,
        onReload: @escaping @MainActor () -> Void,
        onPlay: @escaping @MainActor (MusicTrack) -> Void
    ) {
        self.download = download
        self.settingsStore = settingsStore
        self.onReload = onReload
        self.onPlay = onPlay
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }

    convenience init(
        downloadManager: DownloadManager,
        settingsStore: SettingsStore,
        libraryViewModel: LibraryViewModel,
        onPlay: @escaping @MainActor (MusicTrack) -> Void
    ) {
        self.init(
            download: { url, progress in
                try await downloadManager.download(from: url, progress: progress)
            },
            settingsStore: settingsStore,
            onReload: {
                Task { [weak libraryViewModel] in
                    await libraryViewModel?.requestReload()
                }
            },
            onPlay: onPlay
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DownloadSheetViewController 仅支持纯代码初始化")
    }

    deinit {
        downloadTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "从链接下载音频"
        view.backgroundColor = Theme.background
        buildInterface()
        renderState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentationController?.delegate = self
        if case .input = state {
            urlField.becomeFirstResponder()
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        cancelActiveDownload(resetToInput: true)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        startDownload()
        return true
    }

    private func buildInterface() {
        let closeButton = makeButton(title: "取消", identifier: "download.close")
        closeButton.addAction(UIAction { [weak self] _ in
            self?.cancelAndDismiss()
        }, for: .touchUpInside)
        navigationItem.leftBarButtonItem = UIBarButtonItem(customView: closeButton)

        configureStack(inputStateView, identifier: "download.state.input")
        configureStack(downloadingStateView, identifier: "download.state.downloading")
        configureStack(successStateView, identifier: "download.state.success")
        configureStack(failureStateView, identifier: "download.state.failure")

        urlField.accessibilityIdentifier = "download.url"
        urlField.accessibilityLabel = "音频文件直链"
        urlField.placeholder = "粘贴 .mp3、.m4a 或 .wav 直链"
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

        let help = makeLabel(
            "仅支持直接指向音频文件的链接，不解析音乐平台或普通网页链接。",
            style: .footnote,
            color: .secondaryLabel
        )
        let submit = makeButton(title: "下载到资料库", identifier: "download.submit", primary: true)
        submit.addAction(UIAction { [weak self] _ in self?.startDownload() }, for: .touchUpInside)
        inputStateView.addArrangedSubview(urlField)
        inputStateView.addArrangedSubview(help)
        inputStateView.addArrangedSubview(submit)

        let downloadingTitle = makeLabel("正在下载", style: .title3)
        progressView.progressTintColor = Theme.accent
        progressLabel.font = .preferredFont(forTextStyle: .footnote)
        progressLabel.adjustsFontForContentSizeCategory = true
        progressLabel.textColor = .secondaryLabel
        let cancelDownload = makeButton(title: "取消下载", identifier: "download.cancel")
        cancelDownload.addAction(UIAction { [weak self] _ in self?.cancelAndDismiss() }, for: .touchUpInside)
        downloadingStateView.addArrangedSubview(downloadingTitle)
        downloadingStateView.addArrangedSubview(progressView)
        downloadingStateView.addArrangedSubview(progressLabel)
        downloadingStateView.addArrangedSubview(cancelDownload)

        let successTitle = makeLabel("已添加到资料库", style: .title2)
        successTitle.textAlignment = .center
        successLabel.font = .preferredFont(forTextStyle: .body)
        successLabel.adjustsFontForContentSizeCategory = true
        successLabel.textAlignment = .center
        successLabel.textColor = .secondaryLabel
        successLabel.numberOfLines = 0
        let play = makeButton(title: "立即播放", identifier: "download.play", primary: true)
        play.addAction(UIAction { [weak self] _ in self?.playDownloadedTrack() }, for: .touchUpInside)
        let done = makeButton(title: "完成", identifier: "download.done")
        done.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        successStateView.addArrangedSubview(successTitle)
        successStateView.addArrangedSubview(successLabel)
        successStateView.addArrangedSubview(play)
        successStateView.addArrangedSubview(done)

        let failureTitle = makeLabel("下载失败", style: .title2)
        failureTitle.textAlignment = .center
        failureLabel.font = .preferredFont(forTextStyle: .body)
        failureLabel.adjustsFontForContentSizeCategory = true
        failureLabel.textAlignment = .center
        failureLabel.textColor = .secondaryLabel
        failureLabel.numberOfLines = 0
        let retry = makeButton(title: "重新输入", identifier: "download.retry", primary: true)
        retry.addAction(UIAction { [weak self] _ in self?.state = .input }, for: .touchUpInside)
        failureStateView.addArrangedSubview(failureTitle)
        failureStateView.addArrangedSubview(failureLabel)
        failureStateView.addArrangedSubview(retry)

        let container = UIStackView(arrangedSubviews: [
            inputStateView,
            downloadingStateView,
            successStateView,
            failureStateView
        ])
        container.axis = .vertical
        view.addSubview(container)
        container.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(24)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(20)
            make.bottom.lessThanOrEqualTo(view.keyboardLayoutGuide.snp.top).offset(-20)
        }
    }

    private func configureStack(_ stack: UIStackView, identifier: String) {
        stack.axis = .vertical
        stack.spacing = 14
        stack.accessibilityIdentifier = identifier
    }

    private func makeLabel(
        _ text: String,
        style: UIFont.TextStyle,
        color: UIColor = .label
    ) -> UILabel {
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

    private func renderState() {
        guard isViewLoaded else { return }
        let visible: UIStackView
        switch state {
        case .input:
            visible = inputStateView
        case let .downloading(progress):
            visible = downloadingStateView
            let clamped = min(max(progress, 0), 1)
            progressView.progress = Float(clamped)
            progressLabel.text = "\(Int((clamped * 100).rounded()))% · 正在保存到本地资料库"
        case let .success(track):
            visible = successStateView
            successLabel.text = "\(track.title) 已下载完成，可离线播放。"
        case let .failure(message):
            visible = failureStateView
            failureLabel.text = message
        }
        inputStateView.isHidden = inputStateView !== visible
        downloadingStateView.isHidden = downloadingStateView !== visible
        successStateView.isHidden = successStateView !== visible
        failureStateView.isHidden = failureStateView !== visible
    }

    private func startDownload() {
        guard downloadTask == nil else { return }
        let text = urlField.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        urlField.resignFirstResponder()
        guard let text,
              let url = URL(string: text),
              url.scheme != nil else {
            state = .failure(message: "请输入有效的音频文件直链。")
            return
        }

        generation &+= 1
        let currentGeneration = generation
        activeGeneration = currentGeneration
        state = .downloading(progress: 0)
        let operation = download
        downloadTask = Task { [weak self] in
            do {
                let track = try await operation(url) { [weak self] progress in
                    guard let self, activeGeneration == currentGeneration else { return }
                    state = .downloading(progress: progress)
                }
                guard let self, activeGeneration == currentGeneration else { return }
                // 先封口当前代次，传输层已经排队的进度不能覆盖成功终态。
                activeGeneration = nil
                downloadTask = nil
                didConsumeSuccess = false
                state = .success(track)
                onReload()
                if settingsStore.autoPlayAfterDownload {
                    didConsumeSuccess = true
                    onPlay(track)
                    dismiss(animated: true)
                }
            } catch is CancellationError {
                guard let self, activeGeneration == currentGeneration else { return }
                activeGeneration = nil
                downloadTask = nil
                state = .input
            } catch {
                guard let self, activeGeneration == currentGeneration else { return }
                // 失败同样是终态；忽略同一传输随后到达的进度回调。
                activeGeneration = nil
                downloadTask = nil
                state = .failure(message: Self.message(for: error))
            }
        }
    }

    private func cancelAndDismiss() {
        cancelActiveDownload(resetToInput: true)
        dismiss(animated: true)
    }

    private func cancelActiveDownload(resetToInput: Bool) {
        // generation 先推进，保证不响应取消的传输层迟到后也不能污染下一次下载。
        generation &+= 1
        activeGeneration = nil
        downloadTask?.cancel()
        downloadTask = nil
        if resetToInput {
            state = .input
        }
    }

    private func playDownloadedTrack() {
        guard case let .success(track) = state, !didConsumeSuccess else { return }
        // dismiss 动画完成前先同步消费成功态，避免快速连点重复触发播放。
        didConsumeSuccess = true
        onPlay(track)
        dismiss(animated: true)
    }

    private static func message(for error: Error) -> String {
        if let downloadError = error as? DownloadError {
            switch downloadError {
            case .unsupportedURL:
                return "仅支持直接指向 MP3、M4A 或 WAV 文件的链接。"
            case .unsupportedResponse:
                return "链接未返回可下载的音频文件。"
            }
        }
        return "下载未完成，请检查链接和网络后重试。"
    }
}
