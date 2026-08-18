import UIKit

/// 全局视觉 token；具体页面只消费这些已批准的基础值。
enum Theme {
    static let background = UIColor.systemGroupedBackground
    static let surface = UIColor.secondarySystemGroupedBackground
    static let accent = UIColor(red: 250 / 255, green: 45 / 255, blue: 72 / 255, alpha: 1)
    static let cardRadius: CGFloat = 16
}
