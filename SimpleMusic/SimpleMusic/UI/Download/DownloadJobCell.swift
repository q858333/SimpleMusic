import SnapKit
import UIKit

/// 单个下载任务的状态与可用操作；复用时以任务 ID 重新绑定所有内容。
@MainActor
final class DownloadJobCell: UITableViewCell {
    static let reuseIdentifier = "DownloadJobCell"

    var onCancel: ((UUID) -> Void)?
    var onRetry: ((UUID) -> Void)?
    var onRemove: ((UUID) -> Void)?
    var onPlay: ((UUID) -> Void)?

    private var jobID: UUID?
    private let cardView = UIView()
    private let nameLabel = UILabel()
    private let statusLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let actionsStack = UIStackView()
    private lazy var cancelButton = makeButton(action: #selector(cancelTapped))
    private lazy var retryButton = makeButton(action: #selector(retryTapped))
    private lazy var removeButton = makeButton(action: #selector(removeTapped))
    private lazy var playButton = makeButton(action: #selector(playTapped), primary: true)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        buildInterface()
        if #available(iOS 17.0, *) {
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
                (cell: DownloadJobCell, _) in
                cell.updateBorderColor()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DownloadJobCell 仅支持纯代码初始化")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        resetBindings()
    }

    func render(job: DownloadJob) {
        // UITableView 会复用 cell，先清掉上一任务的闭包和标识再渲染。
        resetBindings()
        jobID = job.id
        accessibilityIdentifier = "download.job.\(job.id).row"
        nameLabel.accessibilityIdentifier = "download.job.\(job.id).title"
        statusLabel.accessibilityIdentifier = "download.job.\(job.id).status"
        progressView.accessibilityIdentifier = "download.job.\(job.id).progress"
        configure(button: cancelButton, title: L10n.text("download.cancel"), suffix: "cancel", id: job.id)
        configure(button: retryButton, title: L10n.text("download.queue.retry"), suffix: "retry", id: job.id)
        configure(button: removeButton, title: L10n.text("download.queue.remove"), suffix: "remove", id: job.id)
        configure(button: playButton, title: L10n.text("download.play_now"), suffix: "play", id: job.id)

        nameLabel.text = job.displayName
        [cancelButton, retryButton, removeButton, playButton].forEach { $0.isHidden = true }
        progressView.isHidden = true

        switch job.state {
        case .queued:
            statusLabel.text = L10n.text("download.queue.waiting")
            cancelButton.isHidden = false
        case .downloading:
            let percent = Self.percent(job.progress)
            statusLabel.text = L10n.format("download.queue.progress", percent)
            progressView.progress = Float(min(max(job.progress, 0), 1))
            progressView.accessibilityValue = L10n.format("download.queue.accessibility.progress", percent)
            progressView.isHidden = false
            cancelButton.isHidden = false
        case .success:
            statusLabel.text = L10n.text("download.success_title")
            playButton.isHidden = false
            removeButton.isHidden = false
        case .failure:
            statusLabel.text = Self.failureText(job.failureReason)
            retryButton.isHidden = false
            removeButton.isHidden = false
        case .cancelled:
            statusLabel.text = L10n.text("download.queue.cancelled")
            retryButton.isHidden = false
            removeButton.isHidden = false
        case .interrupted:
            statusLabel.text = job.failureReason == .recovery
                ? L10n.text("download.queue.error.recovery")
                : L10n.text("download.queue.interrupted")
            retryButton.isHidden = false
            removeButton.isHidden = false
        }
    }

    private func buildInterface() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        cardView.backgroundColor = Theme.elevatedSurface
        cardView.layer.cornerRadius = Theme.buttonRadius
        cardView.layer.cornerCurve = .continuous
        cardView.layer.borderWidth = 0.5
        cardView.layer.borderColor = Theme.hairline.resolvedColor(with: traitCollection).cgColor

        nameLabel.font = .preferredFont(forTextStyle: .headline)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.numberOfLines = 2
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        progressView.progressTintColor = Theme.accent

        actionsStack.axis = .horizontal
        actionsStack.spacing = 8
        actionsStack.alignment = .fill
        [cancelButton, retryButton, removeButton, playButton].forEach(actionsStack.addArrangedSubview)

        let stack = UIStackView(arrangedSubviews: [nameLabel, statusLabel, progressView, actionsStack])
        stack.axis = .vertical
        stack.spacing = 8
        contentView.addSubview(cardView)
        cardView.addSubview(stack)
        cardView.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview().inset(6)
            make.leading.trailing.equalToSuperview().inset(20)
        }
        stack.snp.makeConstraints { make in make.edges.equalToSuperview().inset(14) }
    }

    private func makeButton(action: Selector, primary: Bool = false) -> UIButton {
        var configuration = primary ? UIButton.Configuration.filled() : .gray()
        configuration.cornerStyle = .medium
        configuration.baseBackgroundColor = primary ? Theme.accent : nil
        let button = UIButton(configuration: configuration)
        button.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        Theme.installPressFeedback(on: button)
        button.addTarget(self, action: action, for: .touchUpInside)
        button.snp.makeConstraints { make in make.height.greaterThanOrEqualTo(44) }
        return button
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
        updateBorderColor()
    }

    private func updateBorderColor() {
        cardView.layer.borderColor = Theme.hairline.resolvedColor(with: traitCollection).cgColor
    }

    private func configure(button: UIButton, title: String, suffix: String, id: UUID) {
        button.configuration?.title = title
        button.accessibilityIdentifier = "download.job.\(id).\(suffix)"
    }

    private func resetBindings() {
        jobID = nil
        onCancel = nil
        onRetry = nil
        onRemove = nil
        onPlay = nil
    }

    @objc private func cancelTapped() {
        guard let jobID else { return }
        onCancel?(jobID)
    }

    @objc private func retryTapped() {
        guard let jobID else { return }
        onRetry?(jobID)
    }

    @objc private func removeTapped() {
        guard let jobID else { return }
        onRemove?(jobID)
    }

    @objc private func playTapped() {
        guard let jobID else { return }
        onPlay?(jobID)
    }

    private static func percent(_ progress: Double) -> Int {
        Int((min(max(progress, 0), 1) * 100).rounded())
    }

    private static func failureText(_ reason: DownloadJob.FailureReason?) -> String {
        switch reason {
        case .unsupportedURL:
            return L10n.text("download.error.unsupported_url")
        case .invalidPayload:
            return L10n.text("download.error.invalid_payload")
        case .cellularDisabled:
            return L10n.text("download.cellular.blocked")
        case .recovery:
            return L10n.text("download.queue.error.recovery")
        case .generic, nil:
            return L10n.text("download.error.generic")
        }
    }
}
