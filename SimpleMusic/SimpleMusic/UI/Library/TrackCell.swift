import SnapKit
import UIKit

/// 资料库和搜索共用的歌曲行，内容完全来自统一 MusicTrack。
final class TrackCell: UICollectionViewCell {
    static let reuseIdentifier = "TrackCell"

    var onMore: (() -> Void)?

    private let artworkView: UIImageView = {
        let view = UIImageView()
        view.accessibilityIdentifier = "track.artwork"
        view.backgroundColor = UIColor.tertiarySystemFill
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.layer.cornerRadius = 10
        return view
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.accessibilityIdentifier = "track.title"
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        return label
    }()

    private let subtitleLabel: UILabel = {
        let label = UILabel()
        label.accessibilityIdentifier = "track.subtitle"
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        return label
    }()

    private let downloadedLabel: UILabel = {
        let label = UILabel()
        label.accessibilityIdentifier = "track.downloaded"
        label.text = "已下载"
        label.font = .preferredFont(forTextStyle: .caption2)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.backgroundColor = UIColor.tertiarySystemFill
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        label.textAlignment = .center
        return label
    }()

    private lazy var moreButton: UIButton = {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "track.more"
        button.accessibilityLabel = "更多操作"
        button.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        button.tintColor = .secondaryLabel
        button.addAction(UIAction { [weak self] _ in
            self?.onMore?()
        }, for: .touchUpInside)
        return button
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TrackCell 仅支持纯代码初始化")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkView.image = nil
        onMore = nil
    }

    func configure(with track: MusicTrack) {
        titleLabel.text = track.title
        subtitleLabel.text = "\(track.artist) · \(track.album)"
        artworkView.image = track.artworkData.flatMap(UIImage.init(data:))
            ?? UIImage(systemName: "music.note")
        if case .downloaded = track.source {
            downloadedLabel.isHidden = false
        } else {
            downloadedLabel.isHidden = true
        }
        accessibilityLabel = [track.title, track.artist, track.album].joined(separator: "，")
    }

    private func buildView() {
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 12
        clipsToBounds = true

        contentView.addSubview(artworkView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(subtitleLabel)
        contentView.addSubview(downloadedLabel)
        contentView.addSubview(moreButton)

        artworkView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(10)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(46)
        }
        moreButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(4)
            make.centerY.equalToSuperview()
            make.width.height.greaterThanOrEqualTo(44)
        }
        downloadedLabel.snp.makeConstraints { make in
            make.trailing.equalTo(moreButton.snp.leading).offset(-4)
            make.centerY.equalToSuperview()
            make.width.greaterThanOrEqualTo(50)
            make.height.equalTo(22)
        }
        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(artworkView.snp.trailing).offset(10)
            make.trailing.lessThanOrEqualTo(downloadedLabel.snp.leading).offset(-8)
            make.top.equalToSuperview().offset(11)
        }
        subtitleLabel.snp.makeConstraints { make in
            make.leading.equalTo(titleLabel)
            make.trailing.lessThanOrEqualTo(downloadedLabel.snp.leading).offset(-8)
            make.top.equalTo(titleLabel.snp.bottom).offset(3)
            make.bottom.lessThanOrEqualToSuperview().inset(9)
        }
    }
}
