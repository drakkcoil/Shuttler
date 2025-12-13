import SwiftUI

struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color("GradientTop"),
                    Color("GradientBottom")
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Color.primary.opacity(0.05)
                .blendMode(.overlay)
                .ignoresSafeArea()

            RoundedRectangle(cornerRadius: 0)
                .fill(.ultraThinMaterial.opacity(0.35))
                .ignoresSafeArea()
        }
    }
}

#Preview {
    AppBackground()
}
