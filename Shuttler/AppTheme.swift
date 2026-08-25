import SwiftUI

enum AppTheme {
    // Brand colors
    static let tint = Color.accentColor
    static let gradientTop = Color.primary.opacity(0.04)
    static let gradientBottom = Color.secondary.opacity(0.08)

    // Spacing scale
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    // Typography helpers
    enum Typography {
        static func title(_ text: String) -> some View {
            Text(text).font(.largeTitle.bold())
        }
        static func subtitle(_ text: String) -> some View {
            Text(text).font(.title3.weight(.semibold)).foregroundStyle(.secondary)
        }
    }
}
