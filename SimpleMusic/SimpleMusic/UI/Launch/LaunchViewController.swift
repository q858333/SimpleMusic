import SnapKit
import UIKit

/// App 启动后短暂展示的品牌页；系统冷启动画面仍由 LaunchScreen.storyboard 提供。
final class LaunchViewController: UIViewController {
    private let iconView: UIImageView = {
        let imageView = UIImageView(image: UIImage(named: "music-note-red"))
        imageView.contentMode = .scaleAspectFit
        imageView.accessibilityIdentifier = "launch.icon"
        return imageView
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = "DiskTone"
        label.font = .boldSystemFont(ofSize: 22)
        label.adjustsFontForContentSizeCategory = true
        label.accessibilityIdentifier = "launch.title"
        return label
    }()

    private let subtitleLabel: UILabel = {
        let label = UILabel()
        label.text = L10n.text("launch.subtitle")
        label.font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: .systemFont(ofSize: 15))
        label.textColor = UIColor(white: 0.42, alpha: 1)
        label.textAlignment = .center
        label.numberOfLines = 1
        label.adjustsFontForContentSizeCategory = true
        label.accessibilityIdentifier = "launch.subtitle"
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .white

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
}
