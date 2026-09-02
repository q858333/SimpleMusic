import SnapKit
import UIKit
import UserNotifications
import YYText

/// App 启动后短暂展示的品牌页；系统冷启动画面仍由 LaunchScreen.storyboard 提供。
final class LaunchViewController: UIViewController {
    typealias LaunchAction = @MainActor () async -> Void
    typealias ConfigurationRefreshAction = @MainActor () async -> Bool
    typealias RouteScheduler = @MainActor (@escaping @MainActor () -> Void) -> Void

    static let agreementAcceptedDefaultsKey = "launch.agreement.accepted"

    private let registerDevice: LaunchAction
    private let requestAPNsAuthorization: LaunchAction
    private let refreshRemoteConfiguration: ConfigurationRefreshAction
    private let agreementDefaults: UserDefaults
    private let scheduleRoute: RouteScheduler
    var onAgreementAccepted: @MainActor () -> Void
    var onConfigurationRefreshed: @MainActor () -> Void = {}
    private var hasAcceptedAgreement = false
    private var hasRequestedAPNsAuthorization = false
    private var hasStartedPostAgreementActions = false
    private var hasStartedConfigurationRefresh = false

    private let iconView: UIImageView = {
        let imageView = UIImageView(image: UIImage(named: "music-note-white"))
        imageView.contentMode = .scaleAspectFit
        imageView.accessibilityIdentifier = "launch.icon"
        return imageView
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = "DiskTone"
        label.font = .boldSystemFont(ofSize: 22)
        label.textColor = .white
        label.adjustsFontForContentSizeCategory = true
        label.accessibilityIdentifier = "launch.title"
        return label
    }()

    private let subtitleLabel: UILabel = {
        let label = UILabel()
        label.text = L10n.text("launch.subtitle")
        label.font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: .systemFont(ofSize: 15))
        label.textColor = UIColor(white: 1, alpha: 0.85)
        label.textAlignment = .center
        label.numberOfLines = 1
        label.adjustsFontForContentSizeCategory = true
        label.accessibilityIdentifier = "launch.subtitle"
        return label
    }()

    init(
        registerDevice: @escaping LaunchAction = LaunchViewController.registerDevice,
        requestAPNsAuthorization: @escaping LaunchAction = LaunchViewController.requestAPNsAuthorization,
        refreshRemoteConfiguration: @escaping ConfigurationRefreshAction = LaunchViewController.refreshRemoteConfiguration,
        agreementDefaults: UserDefaults = .standard,
        onAgreementAccepted: @escaping @MainActor () -> Void = {},
        scheduleRoute: @escaping RouteScheduler = LaunchViewController.scheduleRoute
    ) {
        self.registerDevice = registerDevice
        self.requestAPNsAuthorization = requestAPNsAuthorization
        self.refreshRemoteConfiguration = refreshRemoteConfiguration
        self.agreementDefaults = agreementDefaults
        self.onAgreementAccepted = onAgreementAccepted
        self.scheduleRoute = scheduleRoute
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = UIColor(
            red: 250 / 255,
            green: 45 / 255,
            blue: 72 / 255,
            alpha: 1
        )

        let textStackView = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStackView.axis = .vertical
        textStackView.alignment = .center
        textStackView.spacing = 8

        let stackView = UIStackView(arrangedSubviews: [iconView, textStackView])
        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.spacing = 16
        view.addSubview(stackView)

        iconView.snp.makeConstraints { make in
            make.size.equalTo(80)
        }
        stackView.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }

        guard !agreementDefaults.bool(forKey: Self.agreementAcceptedDefaultsKey) else { return }
        let agreementView = LaunchAgreementView(
            onAccept: { [weak self] in self?.acceptAgreement() },
            onDecline: { [weak self] in self?.confirmDecline() },
            onOpenGuidelines: { [weak self] in self?.openGuidelines() },
            onOpenPrivacy: { [weak self] in self?.openPrivacyPolicy() }
        )
        view.addSubview(agreementView)
        agreementView.snp.makeConstraints { make in make.edges.equalToSuperview() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        startConfigurationRefreshIfNeeded()
        if agreementDefaults.bool(forKey: Self.agreementAcceptedDefaultsKey) {
            startPostAgreementActionsIfNeeded()
        }
    }

    private func startConfigurationRefreshIfNeeded() {
        guard !hasStartedConfigurationRefresh else { return }
        hasStartedConfigurationRefresh = true

        let refreshRemoteConfiguration = refreshRemoteConfiguration
        Task { [weak self] in
            guard await refreshRemoteConfiguration(), !Task.isCancelled else { return }
            self?.onConfigurationRefreshed()
        }
    }

    private func acceptAgreement() {
        guard !hasAcceptedAgreement else { return }
        hasAcceptedAgreement = true
        agreementDefaults.set(true, forKey: Self.agreementAcceptedDefaultsKey)

        startPostAgreementActionsIfNeeded()
    }

    private func requestAPNsAuthorizationIfNeeded() {
        guard !hasRequestedAPNsAuthorization else { return }
        hasRequestedAPNsAuthorization = true

        let requestAPNsAuthorization = requestAPNsAuthorization
        Task { await requestAPNsAuthorization() }
    }

    private func startPostAgreementActionsIfNeeded() {
        guard !hasStartedPostAgreementActions else { return }
        hasStartedPostAgreementActions = true

        requestAPNsAuthorizationIfNeeded()

        let registerDevice = registerDevice
        Task { await registerDevice() }

        scheduleRoute { [weak self] in
            self?.onAgreementAccepted()
        }
    }

    private func confirmDecline() {
        let alert = UIAlertController(
            title: L10n.text("launch.agreement.decline_title"),
            message: L10n.text("launch.agreement.decline_message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: L10n.text("launch.agreement.cancel"),
            style: .cancel
        ))
        alert.addAction(UIAlertAction(
            title: L10n.text("launch.agreement.confirm"),
            style: .default
        ))
        present(alert, animated: true)
    }

    private func openGuidelines() {
        openDocument(
            title: L10n.text("about.guidelines_title"),
            url: URL(string: "https://disktoneweb.dengcheez.workers.dev/terms")!
        )
    }

    private func openPrivacyPolicy() {
        openDocument(
            title: L10n.text("about.privacy_title"),
            url: URL(string: "https://disktoneweb.dengcheez.workers.dev/privacy")!
        )
    }

    private func openDocument(title: String, url: URL) {
        guard presentedViewController == nil else { return }
        let document = WebViewController(title: title, url: url)
        document.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            }
        )
        present(UINavigationController(rootViewController: document), animated: true)
    }

    private static func registerDevice() async {
        do {
            try await DeviceRegistrationService.shared.registerWithRetry(
                apnsToken: APNsTokenStore.shared.currentToken
            )
        } catch {
            // 设备登记不阻塞启动；最终失败只记录，Token 更新时仍会再次上报。
            NSLog("设备注册上报失败：%@", String(describing: error))
        }
    }

    private static func requestAPNsAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .badge, .sound]
            )
            guard granted else { return }
            UIApplication.shared.registerForRemoteNotifications()
        } catch {
            NSLog("APNs 权限请求失败：%@", String(describing: error))
        }
    }

    private static func refreshRemoteConfiguration() async -> Bool {
        await AppEnvironment.shared.refreshRemoteConfiguration()
    }

    nonisolated private static func scheduleRoute(_ route: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            route()
        }
    }
}

@MainActor
private final class LaunchAgreementView: UIView {
    private let onAccept: () -> Void
    private let onDecline: () -> Void
    private let onOpenGuidelines: () -> Void
    private let onOpenPrivacy: () -> Void

    init(
        onAccept: @escaping () -> Void,
        onDecline: @escaping () -> Void,
        onOpenGuidelines: @escaping () -> Void,
        onOpenPrivacy: @escaping () -> Void
    ) {
        self.onAccept = onAccept
        self.onDecline = onDecline
        self.onOpenGuidelines = onOpenGuidelines
        self.onOpenPrivacy = onOpenPrivacy
        super.init(frame: .zero)
        buildInterface()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LaunchAgreementView 仅支持纯代码初始化")
    }

    private func buildInterface() {
        accessibilityIdentifier = "launch.agreement"
        backgroundColor = UIColor.black.withAlphaComponent(0.24)

        let title = makeLabel(
            L10n.text("launch.agreement.title"),
            style: .headline,
            color: .label
        )
        title.textAlignment = .center

        let body = makeAgreementCopy()

        let decline = makeActionButton(
            title: L10n.text("launch.agreement.decline"),
            identifier: "launch.agreement.decline",
            filled: false,
            action: onDecline
        )
        let accept = makeActionButton(
            title: L10n.text("launch.agreement.accept"),
            identifier: "launch.agreement.accept",
            filled: true,
            action: onAccept
        )
        let actions = UIStackView(arrangedSubviews: [decline, accept])
        actions.axis = .horizontal
        actions.distribution = .fillEqually
        actions.spacing = 12

        let content = UIStackView(arrangedSubviews: [title, body, actions])
        content.axis = .vertical
        content.spacing = 18
        content.isLayoutMarginsRelativeArrangement = true
        content.layoutMargins = UIEdgeInsets(top: 28, left: 24, bottom: 24, right: 24)
        content.backgroundColor = .systemBackground
        content.layer.cornerRadius = 16
        content.clipsToBounds = true
        addSubview(content)
        content.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.greaterThanOrEqualToSuperview().offset(28)
            make.trailing.lessThanOrEqualToSuperview().offset(-28)
            make.width.lessThanOrEqualTo(420)
        }
        decline.snp.makeConstraints { make in make.height.equalTo(44) }
        accept.snp.makeConstraints { make in make.height.equalTo(44) }
    }

    private func makeAgreementCopy() -> YYLabel {
        let message = L10n.text("launch.agreement.message")
        let text = NSMutableAttributedString(
            string: message,
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineSpacing = 4
        text.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: text.length))

        addHighlight(
            L10n.text("about.guidelines_title"),
            to: text,
            action: onOpenGuidelines
        )
        addHighlight(
            L10n.text("about.privacy_title"),
            to: text,
            action: onOpenPrivacy
        )

        let label = YYLabel()
        label.accessibilityIdentifier = "launch.agreement.copy"
        label.attributedText = text
        label.numberOfLines = 0
        label.textAlignment = .center
        label.preferredMaxLayoutWidth = 360
        return label
    }

    private func addHighlight(
        _ title: String,
        to text: NSMutableAttributedString,
        action: @escaping () -> Void
    ) {
        let range = (text.string as NSString).range(of: title)
        guard range.location != NSNotFound else { return }

        text.addAttribute(.foregroundColor, value: Theme.accent, range: range)
        let highlight = YYTextHighlight()
        highlight.setColor(Theme.accent)
        highlight.tapAction = { _, _, _, _ in action() }
        text.yy_setTextHighlight(highlight, range: range)
    }

    private func makeLabel(_ text: String, style: UIFont.TextStyle, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    private func makeActionButton(
        title: String,
        identifier: String,
        filled: Bool,
        action: @escaping () -> Void
    ) -> UIButton {
        var configuration = filled ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
        configuration.title = title
        configuration.baseBackgroundColor = Theme.accent
        configuration.baseForegroundColor = filled ? .white : Theme.accent
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.accessibilityIdentifier = identifier
        button.titleLabel?.font = .preferredFont(forTextStyle: .body)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        return button
    }
}
