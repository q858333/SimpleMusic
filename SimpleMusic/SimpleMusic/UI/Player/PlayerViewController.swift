import AVKit
import Combine
import MediaPlayer
import SnapKit
import UIKit

/// iPhone 全屏页和 iPad 侧栏共用的播放内容，只消费统一播放快照和控制动作。
final class PlayerViewController: UIViewController {
    var onDismiss: (() -> Void)?

    private let onTogglePlay: () -> Void
    private let onPrevious: () -> Void
    private let onNext: () -> Void
    private let onSeek: (TimeInterval) -> Void
    private var snapshotCancellable: AnyCancellable?
    private var isSeeking = false

    private let controlsSurface: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        view.accessibilityIdentifier = "player.controls.surface"
        view.isUserInteractionEnabled = false
        view.layer.cornerRadius = 22
        view.clipsToBounds = true
        return view
    }()

    private let artworkView: UIImageView = {
        let view = UIImageView()
        view.accessibilityIdentifier = "player.artwork"
        view.backgroundColor = Theme.accent
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.layer.cornerRadius = 20
        view.tintColor = .white
        return view
    }()

    private let placeholderArtworkView: UIImageView = {
        let view = UIImageView(image: UIImage(named: "music-note-white"))
        view.accessibilityIdentifier = "player.artwork.placeholder"
        view.contentMode = .scaleAspectFit
        view.isAccessibilityElement = false
        return view
    }()

    private let titleLabel = PlayerViewController.label(
        identifier: "player.title",
        style: .title2,
        weight: .black,
        color: .label
    )
    private let artistLabel = PlayerViewController.label(
        identifier: "player.artist",
        style: .body,
        weight: .light,
        color: .secondaryLabel
    )
    private let albumLabel = PlayerViewController.label(
        identifier: "player.album",
        style: .subheadline,
        color: .secondaryLabel
    )
    private let elapsedLabel = PlayerViewController.label(
        identifier: "player.elapsed",
        style: .caption1,
        color: .secondaryLabel
    )
    private let remainingLabel = PlayerViewController.label(
        identifier: "player.remaining",
        style: .caption1,
        color: .secondaryLabel
    )
    private let queuePositionLabel = PlayerViewController.label(
        identifier: "player.queue",
        style: .subheadline,
        color: .label
    )

    private lazy var closeButton: UIButton = {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "player.close"
        button.accessibilityLabel = L10n.text("player.close_now_playing")
        button.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        button.tintColor = .label
        button.addAction(UIAction { [weak self] _ in
            self?.onDismiss?()
        }, for: .touchUpInside)
        return button
    }()

    var initialAccessibilityFocusView: UIView {
        loadViewIfNeeded()
        return closeButton
    }

    private lazy var progressSlider: UISlider = {
        let slider = UISlider()
        slider.accessibilityIdentifier = "player.progress"
        slider.accessibilityLabel = L10n.text("player.progress")
        slider.minimumTrackTintColor = Theme.accent
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.addTarget(self, action: #selector(beginSeeking), for: .touchDown)
        slider.addTarget(self, action: #selector(progressValueChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(endSeeking), for: [
            .touchUpInside,
            .touchUpOutside,
            .touchCancel
        ])
        return slider
    }()

    private lazy var previousButton = controlButton(
        identifier: "player.previous",
        label: L10n.text("player.previous"),
        symbol: "backward.fill",
        action: onPrevious
    )
    private lazy var toggleButton = controlButton(
        identifier: "player.toggle",
        label: L10n.text("common.play"),
        symbol: "play.fill",
        prominent: true,
        action: onTogglePlay
    )
    private lazy var nextButton = controlButton(
        identifier: "player.next",
        label: L10n.text("player.next"),
        symbol: "forward.fill",
        action: onNext
    )

    private let volumeView: MPVolumeView = {
        let view = MPVolumeView()
        view.accessibilityIdentifier = "player.volume"
        // 保留独立的红色 AirPlay 入口，避免旧版 iPadOS 同时显示系统自带的白色按钮。
        view.showsRouteButton = false
        return view
    }()

    private let routePickerView: AVRoutePickerView = {
        let view = AVRoutePickerView()
        view.accessibilityIdentifier = "player.airplay"
        view.accessibilityLabel = "AirPlay"
        view.tintColor = Theme.accent
        view.activeTintColor = Theme.accent
        return view
    }()

    init(
        snapshotPublisher: AnyPublisher<PlaybackSnapshot, Never>,
        onTogglePlay: @escaping () -> Void,
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onSeek: @escaping (TimeInterval) -> Void
    ) {
        self.onTogglePlay = onTogglePlay
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onSeek = onSeek
        super.init(nibName: nil, bundle: nil)
        snapshotCancellable = snapshotPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.render(snapshot)
            }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PlayerViewController 仅支持纯代码初始化")
    }

    deinit {
        snapshotCancellable?.cancel()
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    override var shouldAutorotate: Bool { false }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        buildView()
        updateTraitVisuals()
        if #available(iOS 17.0, *) {
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
                (controller: PlayerViewController, _) in
                controller.updateTraitVisuals()
            }
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else {
            return
        }
        updateTraitVisuals()
    }

    private func buildView() {
        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        let contentView = UIView()
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)

        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        contentView.snp.makeConstraints { make in
            make.edges.equalTo(scrollView.contentLayoutGuide)
            make.width.equalTo(scrollView.frameLayoutGuide)
        }

        let headerLabel = Self.label(
            identifier: "player.nowPlaying",
            style: .caption1,
            weight: .semibold,
            color: .secondaryLabel
        )
        headerLabel.text = L10n.text("player.now_playing")
        headerLabel.textAlignment = .center

        let queueTitle = Self.label(
            identifier: "player.upNext",
            style: .headline,
            weight: .semibold,
            color: .secondaryLabel
        )
        queueTitle.text = L10n.text("player.up_next")

        let controls = UIStackView(arrangedSubviews: [previousButton, toggleButton, nextButton])
        controls.axis = .horizontal
        controls.alignment = .center
        controls.distribution = .equalCentering

        let utilities = UIStackView(arrangedSubviews: [volumeView, routePickerView])
        utilities.axis = .horizontal
        utilities.alignment = .center
        utilities.spacing = 12

        [
            controlsSurface,
            closeButton,
            headerLabel,
            artworkView,
            titleLabel,
            artistLabel,
            albumLabel,
            progressSlider,
            elapsedLabel,
            remainingLabel,
            controls,
            utilities,
            queueTitle,
            queuePositionLabel
        ].forEach(contentView.addSubview)

        artworkView.addSubview(placeholderArtworkView)
        placeholderArtworkView.snp.makeConstraints { make in
            // 播放器的大封面区域使用 88pt 音符，避免默认图在 iPad 侧栏中过小。
            make.center.equalToSuperview()
            make.size.equalTo(88)
        }

        closeButton.snp.makeConstraints { make in
            make.top.equalTo(contentView.safeAreaLayoutGuide).offset(4)
            make.leading.equalToSuperview().offset(12)
            make.size.greaterThanOrEqualTo(44)
        }
        headerLabel.snp.makeConstraints { make in
            make.centerY.equalTo(closeButton)
            make.centerX.equalToSuperview()
            make.leading.greaterThanOrEqualTo(closeButton.snp.trailing).offset(8)
        }
        artworkView.snp.makeConstraints { make in
            make.top.equalTo(closeButton.snp.bottom).offset(14)
            make.centerX.equalToSuperview()
            make.width.equalToSuperview().inset(20).priority(.high)
            make.width.lessThanOrEqualTo(342)
            make.height.equalTo(artworkView.snp.width)
        }
        titleLabel.snp.makeConstraints { make in
            make.top.equalTo(artworkView.snp.bottom).offset(22)
            make.leading.trailing.equalToSuperview().inset(20)
        }
        artistLabel.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(4)
            make.leading.trailing.equalTo(titleLabel)
        }
        albumLabel.snp.makeConstraints { make in
            make.top.equalTo(artistLabel.snp.bottom).offset(3)
            make.leading.trailing.equalTo(titleLabel)
        }
        progressSlider.snp.makeConstraints { make in
            make.top.equalTo(albumLabel.snp.bottom).offset(14)
            make.leading.trailing.equalToSuperview().inset(20)
            make.height.greaterThanOrEqualTo(44)
        }
        elapsedLabel.snp.makeConstraints { make in
            make.top.equalTo(progressSlider.snp.bottom).offset(-4)
            make.leading.equalTo(progressSlider)
        }
        remainingLabel.snp.makeConstraints { make in
            make.centerY.equalTo(elapsedLabel)
            make.trailing.equalTo(progressSlider)
        }
        controls.snp.makeConstraints { make in
            make.top.equalTo(elapsedLabel.snp.bottom).offset(12)
            make.leading.trailing.equalToSuperview().inset(46)
        }
        utilities.snp.makeConstraints { make in
            make.top.equalTo(controls.snp.bottom).offset(16)
            make.leading.trailing.equalToSuperview().inset(20)
        }
        volumeView.snp.makeConstraints { make in
            make.height.greaterThanOrEqualTo(44)
        }
        routePickerView.snp.makeConstraints { make in
            make.size.greaterThanOrEqualTo(44)
        }
        controlsSurface.snp.makeConstraints { make in
            // 只在既有控件后方增加材质，不参与任何控件的位置计算。
            make.top.equalTo(progressSlider).offset(-6)
            make.leading.trailing.equalToSuperview().inset(12)
            make.bottom.equalTo(utilities).offset(10)
        }
        queueTitle.snp.makeConstraints { make in
            make.top.equalTo(utilities.snp.bottom).offset(18)
            make.leading.trailing.equalToSuperview().inset(20)
        }
        queuePositionLabel.snp.makeConstraints { make in
            make.top.equalTo(queueTitle.snp.bottom).offset(8)
            make.leading.trailing.equalTo(queueTitle)
            make.bottom.equalToSuperview().inset(24)
        }
    }

    private func render(_ snapshot: PlaybackSnapshot) {
        guard let track = snapshot.track else {
            renderEmptyState()
            return
        }

        titleLabel.text = track.title
        artistLabel.text = track.artist
        albumLabel.text = track.album
        if let artwork = track.artworkData.flatMap(UIImage.init(data:)) {
            artworkView.image = artwork
            artworkView.contentMode = .scaleAspectFill
            placeholderArtworkView.isHidden = true
        } else {
            artworkView.image = nil
            artworkView.contentMode = .scaleAspectFill
            placeholderArtworkView.isHidden = false
        }

        let isPlaying = snapshot.status == .playing
        toggleButton.accessibilityLabel = isPlaying
            ? L10n.text("common.pause")
            : L10n.text("common.play")
        toggleButton.setImage(
            UIImage(systemName: isPlaying ? "pause.fill" : "play.fill"),
            for: .normal
        )
        updateControlAvailability(for: snapshot)
        // 进入不可 seek 状态即结束本地拖动，避免迟到的终止事件提交失效进度。
        if !progressSlider.isEnabled {
            isSeeking = false
        }
        elapsedLabel.text = Self.timeText(snapshot.elapsed)
        remainingLabel.text = "-\(Self.timeText(max(0, snapshot.duration - snapshot.elapsed)))"
        queuePositionLabel.text = Self.queueText(snapshot)

        // 手指按住时保留用户选择，避免周期快照把滑块抢回旧进度。
        if !isSeeking {
            progressSlider.maximumValue = Float(max(1, snapshot.duration))
            progressSlider.value = Float(min(max(0, snapshot.elapsed), snapshot.duration))
        }
    }

    private func renderEmptyState() {
        // 空快照结束上一首的本地拖动，迟到 touchUp 不得作用于下一首。
        isSeeking = false
        titleLabel.text = L10n.text("player.empty_title")
        artistLabel.text = L10n.text("player.empty_subtitle")
        albumLabel.text = nil
        artworkView.image = nil
        artworkView.contentMode = .scaleAspectFill
        placeholderArtworkView.isHidden = false
        elapsedLabel.text = "0:00"
        remainingLabel.text = "-0:00"
        queuePositionLabel.text = L10n.text("player.queue_empty")
        progressSlider.maximumValue = 1
        progressSlider.value = 0
        toggleButton.accessibilityLabel = L10n.text("common.play")
        toggleButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        setPlaybackControlsEnabled(false)
    }

    private func setPlaybackControlsEnabled(_ enabled: Bool) {
        [previousButton, toggleButton, nextButton].forEach { $0.isEnabled = enabled }
        progressSlider.isEnabled = enabled
        setSystemUtilitiesEnabled(enabled)
    }

    private func updateControlAvailability(for snapshot: PlaybackSnapshot) {
        guard let index = snapshot.queueIndex,
              (0..<snapshot.queueCount).contains(index) else {
            setPlaybackControlsEnabled(false)
            return
        }

        let isReady: Bool
        switch snapshot.status {
        case .playing, .paused:
            isReady = true
        case .idle, .loading, .failed:
            isReady = false
        }

        // 切歌只在真实相邻项存在时开放；播放切换和进度只在后端已就绪时开放。
        previousButton.isEnabled = index > 0
        nextButton.isEnabled = index + 1 < snapshot.queueCount
        toggleButton.isEnabled = isReady
        progressSlider.isEnabled = isReady
        setSystemUtilitiesEnabled(true)
    }

    private func setSystemUtilitiesEnabled(_ enabled: Bool) {
        volumeView.isUserInteractionEnabled = enabled
        routePickerView.isUserInteractionEnabled = enabled
        volumeView.alpha = enabled ? 1 : 0.45
        routePickerView.alpha = enabled ? 1 : 0.45
    }

    @objc private func beginSeeking() {
        isSeeking = true
    }

    @objc private func endSeeking() {
        guard isSeeking else { return }
        isSeeking = false
        guard progressSlider.isEnabled else { return }
        onSeek(TimeInterval(progressSlider.value))
    }

    @objc private func progressValueChanged() {
        guard progressSlider.isEnabled, !isSeeking, !progressSlider.isTracking else { return }
        onSeek(TimeInterval(progressSlider.value))
    }

    private func controlButton(
        identifier: String,
        label: String,
        symbol: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = label
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.tintColor = prominent ? .white : .label
        if prominent {
            button.backgroundColor = Theme.accent
            button.layer.cornerRadius = 22
            button.layer.shadowOpacity = 0.22
            button.layer.shadowRadius = 8
            button.layer.shadowOffset = CGSize(width: 0, height: 4)
            button.snp.makeConstraints { make in make.size.equalTo(62) }
        } else {
            button.snp.makeConstraints { make in make.size.greaterThanOrEqualTo(44) }
        }
        Theme.installPressFeedback(on: button)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func updateTraitVisuals() {
        let accent = Theme.accent.resolvedColor(with: traitCollection)
        progressSlider.minimumTrackTintColor = accent
        progressSlider.setThumbImage(Self.progressThumb(color: accent), for: .normal)
        progressSlider.setThumbImage(Self.progressThumb(color: accent), for: .highlighted)
        toggleButton.backgroundColor = accent
        toggleButton.layer.shadowColor = accent.cgColor
        routePickerView.tintColor = accent
        routePickerView.activeTintColor = accent
    }

    private static func progressThumb(color: UIColor) -> UIImage {
        let size = CGSize(width: 24, height: 24)
        return UIGraphicsImageRenderer(size: size).image { context in
            context.cgContext.setShadow(
                offset: .zero,
                blur: 5,
                color: color.withAlphaComponent(0.32).cgColor
            )
            color.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 5, y: 5, width: 14, height: 14))
        }
    }

    private static func label(
        identifier: String? = nil,
        style: UIFont.TextStyle,
        weight: UIFont.Weight = .regular,
        color: UIColor
    ) -> UILabel {
        let label = UILabel()
        label.accessibilityIdentifier = identifier
        label.font = .preferredFont(forTextStyle: style).withWeight(weight)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 1
        return label
    }

    private static func timeText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    private static func queueText(_ snapshot: PlaybackSnapshot) -> String {
        guard snapshot.queueCount > 0 else { return L10n.text("player.queue_empty") }
        guard let index = snapshot.queueIndex else { return L10n.text("player.queue_ended") }
        return L10n.format("player.queue.position", index + 1, snapshot.queueCount)
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
