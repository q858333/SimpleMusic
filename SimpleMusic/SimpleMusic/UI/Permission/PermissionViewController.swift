import SnapKit
import UIKit

/// 首次启动授权说明页；只上报用户选择，不直接创建主界面。
final class PermissionViewController: UIViewController {
    private let onAllow: () async -> Void
    private let onDefer: () -> Void
    private var hasChosenAction = false

    private lazy var iconView: UIView = {
        let configuration = UIImage.SymbolConfiguration(pointSize: 34, weight: .regular)
        let symbolView = UIImageView(image: UIImage(systemName: "music.note", withConfiguration: configuration))
        symbolView.tintColor = Theme.accent
        symbolView.contentMode = .center

        let view = UIView()
        view.accessibilityIdentifier = "permission.icon"
        view.backgroundColor = UIColor(red: 1, green: 232 / 255, blue: 236 / 255, alpha: 1)
        view.layer.cornerRadius = 22
        view.addSubview(symbolView)
        symbolView.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
        return view
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .largeTitle)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.text = "访问你的音乐资料库"
        return label
    }()

    private let bodyLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textColor = .secondaryLabel
        label.text = "允许「听见」读取设备上的歌曲、专辑和艺人信息。你的音乐仅在本机浏览和播放。"
        return label
    }()

    private lazy var allowButton: UIButton = makeButton(
        title: "允许访问",
        backgroundColor: Theme.accent,
        titleColor: .white,
        identifier: "permission.allow",
        action: #selector(didTapAllow)
    )

    private lazy var deferButton: UIButton = makeButton(
        title: "暂不",
        backgroundColor: .systemGray5,
        titleColor: .label,
        identifier: "permission.defer",
        action: #selector(didTapDefer)
    )

    private let noteLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textColor = .secondaryLabel
        label.text = "也可以在资料库中粘贴 .mp3、.m4a 或 .wav 音频直链，下载后与系统歌曲一起播放。"
        return label
    }()

    init(onAllow: @escaping () async -> Void, onDefer: @escaping () -> Void) {
        self.onAllow = onAllow
        self.onDefer = onDefer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PermissionViewController 仅支持纯代码初始化")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        buildLayout()
    }

    private func buildLayout() {
        let actions = UIStackView(arrangedSubviews: [allowButton, deferButton])
        actions.axis = .vertical
        actions.spacing = 12

        let iconRow = UIStackView(arrangedSubviews: [iconView, UIView()])
        iconRow.axis = .horizontal
        iconRow.alignment = .center

        let content = UIStackView(arrangedSubviews: [iconRow, titleLabel, bodyLabel, actions, noteLabel])
        content.axis = .vertical
        content.alignment = .fill
        content.spacing = 14
        content.setCustomSpacing(25, after: iconRow)
        content.setCustomSpacing(30, after: bodyLabel)
        content.setCustomSpacing(22, after: actions)

        // Dynamic Type 放大后允许纵向滚动，避免压缩 72pt 图标与按钮触控区。
        let scrollView = UIScrollView()
        let scrollContent = UIView()
        scrollView.addSubview(scrollContent)
        scrollContent.addSubview(content)
        view.addSubview(scrollView)

        iconView.snp.makeConstraints { make in
            make.width.height.equalTo(72)
        }
        allowButton.snp.makeConstraints { make in
            make.height.greaterThanOrEqualTo(48)
        }
        deferButton.snp.makeConstraints { make in
            make.height.greaterThanOrEqualTo(48)
        }
        scrollView.snp.makeConstraints { make in
            make.edges.equalTo(view.safeAreaLayoutGuide)
        }
        scrollContent.snp.makeConstraints { make in
            make.edges.equalTo(scrollView.contentLayoutGuide)
            make.width.equalTo(scrollView.frameLayoutGuide)
            make.height.greaterThanOrEqualTo(scrollView.frameLayoutGuide)
        }
        content.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(24)
            make.centerY.equalToSuperview()
            make.top.greaterThanOrEqualToSuperview().offset(24)
            make.bottom.lessThanOrEqualToSuperview().offset(-24)
        }
    }

    private func makeButton(
        title: String,
        backgroundColor: UIColor,
        titleColor: UIColor,
        identifier: String,
        action: Selector
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = identifier
        button.setTitle(title, for: .normal)
        button.setTitleColor(titleColor, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.backgroundColor = backgroundColor
        button.layer.cornerRadius = 14
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func didTapAllow() {
        guard beginAction() else { return }
        Task { [onAllow] in
            await onAllow()
        }
    }

    @objc private func didTapDefer() {
        guard beginAction() else { return }
        onDefer()
    }

    private func beginAction() -> Bool {
        guard !hasChosenAction else { return false }
        hasChosenAction = true
        allowButton.isEnabled = false
        deferButton.isEnabled = false
        return true
    }
}
