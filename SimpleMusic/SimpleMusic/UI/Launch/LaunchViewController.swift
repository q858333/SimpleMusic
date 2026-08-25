import SnapKit
import UIKit
import UserNotifications

/// App 启动后短暂展示的品牌页；系统冷启动画面仍由 LaunchScreen.storyboard 提供。
final class LaunchViewController: UIViewController {
    typealias LaunchAction = @MainActor () async -> Void

    private let registerDevice: LaunchAction
    private let requestAPNsAuthorization: LaunchAction
    private var hasStartedLaunchActions = false

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
        requestAPNsAuthorization: @escaping LaunchAction = LaunchViewController.requestAPNsAuthorization
    ) {
        self.registerDevice = registerDevice
        self.requestAPNsAuthorization = requestAPNsAuthorization
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
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasStartedLaunchActions else { return }
        hasStartedLaunchActions = true

        let registerDevice = registerDevice
        Task { await registerDevice() }

        let requestAPNsAuthorization = requestAPNsAuthorization
        Task { await requestAPNsAuthorization() }
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
}
