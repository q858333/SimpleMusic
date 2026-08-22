import UIKit

/// 全局视觉 token；具体页面只消费这些已批准的基础值。
enum Theme {
    /// 暖白与炭黑分别建立页面底色，避免深色模式只是简单颜色反转。
    static let background = adaptive(
        light: UIColor(red: 247 / 255, green: 244 / 255, blue: 241 / 255, alpha: 1),
        dark: UIColor(red: 16 / 255, green: 17 / 255, blue: 20 / 255, alpha: 1)
    )
    static let surface = adaptive(
        light: UIColor(red: 1, green: 253 / 255, blue: 252 / 255, alpha: 1),
        dark: UIColor(red: 26 / 255, green: 28 / 255, blue: 32 / 255, alpha: 1)
    )
    static let elevatedSurface = adaptive(
        light: .white,
        dark: UIColor(red: 35 / 255, green: 38 / 255, blue: 43 / 255, alpha: 1)
    )
    static let accent = adaptive(
        light: UIColor(red: 250 / 255, green: 45 / 255, blue: 72 / 255, alpha: 1),
        dark: UIColor(red: 1, green: 77 / 255, blue: 103 / 255, alpha: 1)
    )
    static let hairline = adaptive(
        light: UIColor(red: 233 / 255, green: 226 / 255, blue: 222 / 255, alpha: 1),
        dark: UIColor(red: 51 / 255, green: 54 / 255, blue: 60 / 255, alpha: 1)
    )

    static let cardRadius: CGFloat = 16
    static let rowRadius: CGFloat = 12
    static let buttonRadius: CGFloat = 14

    /// 分类卡仍保持同一尺寸，只用低饱和色帮助快速识别入口。
    static func categoryBackground(for symbol: String) -> UIColor {
        switch symbol {
        case "square.stack":
            return adaptive(
                light: UIColor(red: 1, green: 243 / 255, blue: 224 / 255, alpha: 1),
                dark: UIColor(red: 55 / 255, green: 42 / 255, blue: 29 / 255, alpha: 1)
            )
        case "person.2":
            return adaptive(
                light: UIColor(red: 241 / 255, green: 235 / 255, blue: 1, alpha: 1),
                dark: UIColor(red: 42 / 255, green: 35 / 255, blue: 58 / 255, alpha: 1)
            )
        case "arrow.down.circle":
            return adaptive(
                light: UIColor(red: 230 / 255, green: 247 / 255, blue: 239 / 255, alpha: 1),
                dark: UIColor(red: 28 / 255, green: 52 / 255, blue: 43 / 255, alpha: 1)
            )
        default:
            return adaptive(
                light: UIColor(red: 1, green: 234 / 255, blue: 238 / 255, alpha: 1),
                dark: UIColor(red: 57 / 255, green: 31 / 255, blue: 39 / 255, alpha: 1)
            )
        }
    }

    static func categoryForeground(for symbol: String) -> UIColor {
        switch symbol {
        case "square.stack": return .systemOrange
        case "person.2": return .systemPurple
        case "arrow.down.circle": return .systemGreen
        default: return accent
        }
    }

    /// 为主要操作补充轻量按压反馈；减少动态效果开启时保持静止。
    static func installPressFeedback(on button: UIButton) {
        button.addAction(UIAction { action in
            guard let button = action.sender as? UIButton else { return }
            animate(button: button, pressed: true)
        }, for: [.touchDown, .touchDragEnter])
        button.addAction(UIAction { action in
            guard let button = action.sender as? UIButton else { return }
            animate(button: button, pressed: false)
        }, for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    }

    private static func animate(button: UIButton, pressed: Bool) {
        let target = pressed && !UIAccessibility.isReduceMotionEnabled
            ? CGAffineTransform(scaleX: 0.97, y: 0.97)
            : .identity
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.14,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
        ) {
            button.transform = target
        }
    }

    private static func adaptive(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        }
    }
}
