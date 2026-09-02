import MediaPlayer
import SnapKit
import UIKit

/// 设置页直接映射系统媒体权限与持久化下载偏好。
@MainActor
final class SettingsViewController: UIViewController {
    private static let feedbackEmail = "dengcheez@gmail.com"

    typealias AuthorizationStatus = () -> MPMediaLibraryAuthorizationStatus
    typealias AuthorizationRequest = () async -> MPMediaLibraryAuthorizationStatus

    private let settingsStore: SettingsStore
    private let authorizationStatus: AuthorizationStatus
    private let requestAuthorization: AuthorizationRequest
    private let openSettings: () -> Void
    private let onAuthorizationChange: @MainActor () async -> Void
    private var permissionTask: Task<Void, Never>?

    private let permissionStatusLabel = UILabel()

    init(
        settingsStore: SettingsStore,
        authorizationStatus: @escaping AuthorizationStatus,
        requestAuthorization: @escaping AuthorizationRequest,
        openSettings: @escaping () -> Void,
        onAuthorizationChange: @escaping @MainActor () async -> Void = {}
    ) {
        self.settingsStore = settingsStore
        self.authorizationStatus = authorizationStatus
        self.requestAuthorization = requestAuthorization
        self.openSettings = openSettings
        self.onAuthorizationChange = onAuthorizationChange
        super.init(nibName: nil, bundle: nil)
    }

    convenience init(
        settingsStore: SettingsStore,
        libraryService: MusicLibraryService,
        onAuthorizationChange: @escaping @MainActor () async -> Void = {}
    ) {
        self.init(
            settingsStore: settingsStore,
            authorizationStatus: { libraryService.authorizationStatus },
            requestAuthorization: { await libraryService.requestAuthorization() },
            openSettings: {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            },
            onAuthorizationChange: onAuthorizationChange
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsViewController 仅支持纯代码初始化")
    }

    deinit {
        permissionTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.text("settings.title")
        view.backgroundColor = Theme.background
        buildInterface()
        syncValues()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        syncValues()
    }

    private func buildInterface() {
        let content = UIStackView()
        content.axis = .vertical
        content.spacing = 24

        let permissionButton = makeRowButton(identifier: "settings.permission")
        let permissionTitle = makeLabel(L10n.text("settings.permission_title"), style: .body)
        permissionStatusLabel.font = .preferredFont(forTextStyle: .subheadline)
        permissionStatusLabel.adjustsFontForContentSizeCategory = true
        permissionStatusLabel.textColor = .secondaryLabel
        permissionStatusLabel.textAlignment = .right
        let permissionRow = UIStackView(arrangedSubviews: [permissionTitle, permissionStatusLabel])
        permissionRow.alignment = .center
        permissionRow.spacing = 12
        permissionButton.addSubview(permissionRow)
        permissionRow.snp.makeConstraints { make in make.edges.equalToSuperview().inset(14) }
        permissionButton.addAction(UIAction { [weak self] _ in self?.handlePermission() }, for: .touchUpInside)

        let aboutButton = makeDisclosureButton(
            title: L10n.text("settings.about_title"),
            identifier: "settings.about"
        ) { [weak self] in
            self?.showAbout()
        }
        let feedbackButton = makeDisclosureButton(
            title: L10n.text("settings.feedback_title"),
            identifier: "settings.feedback"
        ) { [weak self] in
            self?.showFeedback()
        }
        content.addArrangedSubview(section(title: L10n.text("settings.section.library"), rows: [permissionButton]))
        content.addArrangedSubview(section(title: L10n.text("settings.section.about"), rows: [aboutButton]))
        content.addArrangedSubview(
            section(
                title: L10n.text("settings.section.support"),
                rows: [feedbackButton]
            )
        )

        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)
        scrollView.addSubview(content)
        scrollView.snp.makeConstraints { make in make.edges.equalTo(view.safeAreaLayoutGuide) }
        content.snp.makeConstraints { make in
            make.edges.equalTo(scrollView.contentLayoutGuide).inset(16)
            make.width.equalTo(scrollView.frameLayoutGuide).offset(-32)
        }
    }

    private func section(title: String, rows: [UIView]) -> UIView {
        let heading = makeLabel(title, style: .footnote, color: .secondaryLabel)
        let rowsStack = UIStackView(arrangedSubviews: rows)
        rowsStack.axis = .vertical
        rowsStack.spacing = 1
        rowsStack.backgroundColor = Theme.surface
        rowsStack.layer.cornerRadius = Theme.cardRadius
        rowsStack.clipsToBounds = true
        let stack = UIStackView(arrangedSubviews: [heading, rowsStack])
        stack.axis = .vertical
        stack.spacing = 8
        return stack
    }

    private func makeRowButton(identifier: String) -> UIButton {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = identifier
        button.backgroundColor = Theme.surface
        button.snp.makeConstraints { make in make.height.greaterThanOrEqualTo(64) }
        return button
    }

    private func makeDisclosureButton(
        title: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> UIButton {
        let button = makeRowButton(identifier: identifier)
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = UIImage(systemName: "chevron.right")
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 12
        configuration.baseForegroundColor = .label
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 14,
            leading: 14,
            bottom: 14,
            trailing: 14
        )
        button.configuration = configuration
        button.contentHorizontalAlignment = .fill
        button.titleLabel?.font = .preferredFont(forTextStyle: .body)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
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

    private func syncValues() {
        guard isViewLoaded else { return }
        permissionStatusLabel.text = Self.permissionText(authorizationStatus())
    }

    private func showAbout() {
        guard let navigationController,
              navigationController.transitionCoordinator == nil,
              !(navigationController.topViewController is AboutViewController) else { return }
        navigationController.pushViewController(AboutViewController(), animated: true)
    }

    private func showFeedback() {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: L10n.text("settings.feedback_title"),
            message: L10n.format("settings.feedback_message", Self.feedbackEmail),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: L10n.text("settings.feedback_copy"),
            style: .default
        ) { _ in
            UIPasteboard.general.string = Self.feedbackEmail
        })
        alert.addAction(UIAlertAction(
            title: L10n.text("settings.feedback_cancel"),
            style: .cancel
        ))
        present(alert, animated: true)
    }

    func handlePermission() {
        switch authorizationStatus() {
        case .notDetermined:
            guard permissionTask == nil else { return }
            let request = requestAuthorization
            permissionTask = Task { [weak self] in
                _ = await request()
                // 请求可能长期停在系统弹窗；await 前不持有页面，返回后再核对生命周期。
                guard !Task.isCancelled, let self else { return }
                permissionTask = nil
                syncValues()
                await onAuthorizationChange()
            }
        case .denied, .restricted:
            openSettings()
        case .authorized:
            break
        @unknown default:
            openSettings()
        }
    }

    private static func permissionText(_ status: MPMediaLibraryAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return L10n.text("settings.permission_status.not_requested")
        case .denied: return L10n.text("settings.permission_status.denied")
        case .restricted: return L10n.text("settings.permission_status.restricted")
        case .authorized: return L10n.text("settings.permission_status.authorized")
        @unknown default: return L10n.text("settings.permission_status.open_settings")
        }
    }
}
