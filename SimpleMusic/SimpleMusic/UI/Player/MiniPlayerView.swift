import Combine
import SnapKit
import UIKit

/// 播放快照的轻量入口；完整播放器页面由后续任务承接。
final class MiniPlayerView: UIView {
    private let onTogglePlay: () -> Void
    private let onOpenPlayer: () -> Void
    private var snapshotCancellable: AnyCancellable?

    private let artworkView: UIImageView = {
        let view = UIImageView()
        view.accessibilityIdentifier = "mini.artwork"
        view.backgroundColor = UIColor.tertiarySystemFill
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.layer.cornerRadius = 10
        return view
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.accessibilityIdentifier = "mini.title"
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        return label
    }()

    private let artistLabel: UILabel = {
        let label = UILabel()
        label.accessibilityIdentifier = "mini.artist"
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        return label
    }()

    private lazy var toggleButton: UIButton = {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "mini.toggle"
        button.tintColor = .label
        button.addAction(UIAction { [weak self] _ in
            self?.onTogglePlay()
        }, for: .touchUpInside)
        return button
    }()

    private lazy var openButton: UIButton = {
        let button = UIButton(type: .custom)
        button.accessibilityIdentifier = "mini.open"
        button.accessibilityLabel = "打开正在播放"
        button.addAction(UIAction { [weak self] _ in
            self?.onOpenPlayer()
        }, for: .touchUpInside)
        return button
    }()

    init(
        snapshotPublisher: AnyPublisher<PlaybackSnapshot, Never>,
        onTogglePlay: @escaping () -> Void,
        onOpenPlayer: @escaping () -> Void
    ) {
        self.onTogglePlay = onTogglePlay
        self.onOpenPlayer = onOpenPlayer
        super.init(frame: .zero)
        isHidden = true
        buildView()
        snapshotCancellable = snapshotPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.render(snapshot)
            }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MiniPlayerView 仅支持纯代码初始化")
    }

    deinit {
        snapshotCancellable?.cancel()
    }

    func stop() {
        snapshotCancellable?.cancel()
        snapshotCancellable = nil
    }

    private func buildView() {
        backgroundColor = Theme.surface
        layer.cornerRadius = 14
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.separator.cgColor
        clipsToBounds = true

        addSubview(openButton)
        addSubview(artworkView)
        addSubview(titleLabel)
        addSubview(artistLabel)
        addSubview(toggleButton)

        openButton.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        artworkView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(9)
            make.centerY.equalToSuperview()
            make.size.equalTo(46)
        }
        toggleButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(8)
            make.centerY.equalToSuperview()
            make.size.greaterThanOrEqualTo(44)
        }
        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(artworkView.snp.trailing).offset(10)
            make.trailing.lessThanOrEqualTo(toggleButton.snp.leading).offset(-8)
            make.top.equalToSuperview().offset(11)
        }
        artistLabel.snp.makeConstraints { make in
            make.leading.trailing.equalTo(titleLabel)
            make.top.equalTo(titleLabel.snp.bottom).offset(2)
        }
        snp.makeConstraints { make in
            make.height.greaterThanOrEqualTo(64)
        }
    }

    private func render(_ snapshot: PlaybackSnapshot) {
        guard let track = snapshot.track else {
            isHidden = true
            titleLabel.text = nil
            artistLabel.text = nil
            artworkView.image = nil
            return
        }

        isHidden = false
        titleLabel.text = track.title
        artistLabel.text = track.artist
        artworkView.image = track.artworkData.flatMap(UIImage.init(data:))
            ?? UIImage(systemName: "music.note")

        let isPlaying = snapshot.status == .playing
        toggleButton.accessibilityLabel = isPlaying ? "暂停" : "播放"
        toggleButton.setImage(
            UIImage(systemName: isPlaying ? "pause.fill" : "play.fill"),
            for: .normal
        )
    }
}
