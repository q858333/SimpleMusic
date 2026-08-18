import SnapKit
import UIKit

@MainActor
final class AboutViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "关于听见"
        view.backgroundColor = Theme.background
        buildInterface()
    }

    private func buildInterface() {
        let icon = UIImageView(image: UIImage(systemName: "music.note"))
        icon.tintColor = Theme.accent
        icon.contentMode = .scaleAspectFit
        icon.isAccessibilityElement = false
        icon.snp.makeConstraints { make in make.size.equalTo(72) }

        let name = makeLabel("听见", style: .title1, color: .label)
        name.textAlignment = .center
        let subtitle = makeLabel("为设备音乐与本地下载而设计", style: .body, color: .secondaryLabel)
        subtitle.textAlignment = .center

        let hero = UIStackView(arrangedSubviews: [icon, name, subtitle])
        hero.axis = .vertical
        hero.alignment = .center
        hero.spacing = 8

        let format = card(
            title: "MP3、M4A、WAV",
            detail: "仅支持直接指向音频文件的下载链接。"
        )
        let privacy = card(
            title: "隐私原则",
            detail: "音乐仅保存在本机，不上传、不进行云同步；不解析音乐平台或普通网页链接。"
        )
        let content = UIStackView(arrangedSubviews: [hero, format, privacy])
        content.axis = .vertical
        content.spacing = 24
        view.addSubview(content)
        content.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(28)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(20)
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
