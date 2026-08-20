import SnapKit
import UIKit

@MainActor
final class AboutViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.text("about.page_title")
        view.backgroundColor = Theme.background
        buildInterface()
    }

    private func buildInterface() {
        let icon = UIImageView(image: UIImage(systemName: "music.note"))
        icon.tintColor = Theme.accent
        icon.contentMode = .scaleAspectFit
        icon.isAccessibilityElement = false
        icon.snp.makeConstraints { make in make.size.equalTo(72) }

        let name = makeLabel(L10n.text("app.name"), style: .title1, color: .label)
        name.textAlignment = .center
        let subtitle = makeLabel(L10n.text("about.subtitle"), style: .body, color: .secondaryLabel)
        subtitle.textAlignment = .center

        let hero = UIStackView(arrangedSubviews: [icon, name, subtitle])
        hero.axis = .vertical
        hero.alignment = .center
        hero.spacing = 8

        let format = card(
            title: L10n.text("about.formats_title"),
            detail: L10n.text("about.formats_detail")
        )
        let privacy = card(
            title: L10n.text("about.privacy_title"),
            detail: L10n.text("about.privacy_detail")
        )
        let content = UIStackView(arrangedSubviews: [hero, format, privacy])
        content.axis = .vertical
        content.spacing = 24
        content.accessibilityIdentifier = "about.content"

        let scrollView = UIScrollView()
        scrollView.accessibilityIdentifier = "about.scroll"
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)
        scrollView.addSubview(content)
        scrollView.snp.makeConstraints { make in
            make.edges.equalTo(view.safeAreaLayoutGuide)
        }
        content.snp.makeConstraints { make in
            make.edges.equalTo(scrollView.contentLayoutGuide).inset(
                UIEdgeInsets(top: 28, left: 20, bottom: 28, right: 20)
            )
            make.width.equalTo(scrollView.frameLayoutGuide).offset(-40)
        }
    }

    private func card(title: String, detail: String) -> UIView {
        let titleLabel = makeLabel(title, style: .headline, color: .label)
        let detailLabel = makeLabel(detail, style: .body, color: .secondaryLabel)
        let stack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        stack.axis = .vertical
        stack.spacing = 5
        stack.backgroundColor = Theme.surface
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 15, left: 16, bottom: 15, right: 16)
        stack.layer.cornerRadius = Theme.cardRadius
        return stack
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
}
