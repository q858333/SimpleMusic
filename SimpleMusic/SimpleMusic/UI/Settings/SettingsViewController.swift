import MediaPlayer
import SnapKit
import UIKit

/// 设置页直接映射系统媒体权限与持久化下载偏好。
@MainActor
final class SettingsViewController: UIViewController {
    typealias AuthorizationStatus = () -> MPMediaLibraryAuthorizationStatus
    typealias AuthorizationRequest = () async -> MPMediaLibraryAuthorizationStatus

    private let settingsStore: SettingsStore
    private let authorizationStatus: AuthorizationStatus
    private let requestAuthorization: AuthorizationRequest
    private let openSettings: () -> Void
    private let onAuthorizationChange: @MainActor () async -> Void
    private var permissionTask: Task<Void, Never>?

    private let permissionStatusLabel = UILabel()
    private let cellularSwitch = UISwitch()
    private let autoPlaySwitch = UISwitch()

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

        cellularSwitch.accessibilityIdentifier = "settings.cellular"
        cellularSwitch.accessibilityLabel = L10n.text("settings.cellular_title")
        cellularSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            settingsStore.allowsCellularDownloads = cellularSwitch.isOn
        }, for: .valueChanged)
        let cellularRow = makeSwitchRow(
            title: L10n.text("settings.cellular_title"),
            detail: L10n.text("settings.cellular_detail"),
            toggle: cellularSwitch
        )

        autoPlaySwitch.accessibilityIdentifier = "settings.autoplay"
        autoPlaySwitch.accessibilityLabel = L10n.text("settings.autoplay_title")
        autoPlaySwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            settingsStore.autoPlayAfterDownload = autoPlaySwitch.isOn
        }, for: .valueChanged)
        let autoPlayRow = makeSwitchRow(
            title: L10n.text("settings.autoplay_title"),
            detail: L10n.text("settings.autoplay_detail"),
            toggle: autoPlaySwitch
        )

        let aboutButton = makeRowButton(identifier: "settings.about")
        var configuration = UIButton.Configuration.plain()
        configuration.title = L10n.text("settings.about_title")
        configuration.image = UIImage(systemName: "chevron.right")
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 12
        configuration.baseForegroundColor = .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
        aboutButton.configuration = configuration
        aboutButton.contentHorizontalAlignment = .fill
        aboutButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        aboutButton.titleLabel?.adjustsFontForContentSizeCategory = true
        aboutButton.addAction(UIAction { [weak self] _ in
            self?.showAbout()
        }, for: .touchUpInside)

        content.addArrangedSubview(section(title: L10n.text("settings.section.library"), rows: [permissionButton]))
        content.addArrangedSubview(section(title: L10n.text("settings.section.download"), rows: [cellularRow, autoPlayRow]))
        content.addArrangedSubview(section(title: L10n.text("settings.section.about"), rows: [aboutButton]))

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

    private func makeSwitchRow(title: String, detail: String, toggle: UISwitch) -> UIView {
        let titleLabel = makeLabel(title, style: .body)
        let detailLabel = makeLabel(detail, style: .caption1, color: .secondaryLabel)
        let copy = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        copy.axis = .vertical
        copy.spacing = 3
        let row = UIStackView(arrangedSubviews: [copy, toggle])
        row.alignment = .center
        row.spacing = 12
        row.backgroundColor = Theme.surface
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        row.snp.makeConstraints { make in make.height.greaterThanOrEqualTo(64) }
        return row
    }

    private func makeRowButton(identifier: String) -> UIButton {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = identifier
        button.backgroundColor = Theme.surface
        button.snp.makeConstraints { make in make.height.greaterThanOrEqualTo(64) }
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
        cellularSwitch.isOn = settingsStore.allowsCellularDownloads
        autoPlaySwitch.isOn = settingsStore.autoPlayAfterDownload
        permissionStatusLabel.text = Self.permissionText(authorizationStatus())
    }

    private func showAbout() {
        guard let navigationController,
              navigationController.transitionCoordinator == nil,
              !(navigationController.topViewController is AboutViewController) else { return }
        navigationController.pushViewController(AboutViewController(), animated: true)
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
