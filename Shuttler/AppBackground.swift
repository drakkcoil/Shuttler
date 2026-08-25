import SwiftUI
#if os(macOS)
import AppKit
#endif

struct AppBackground: View {
    var body: some View {
        ZStack {
            #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
            #else
            Color(.systemBackground)
                .ignoresSafeArea()
            #endif
            
            LinearGradient(
                colors: [AppTheme.gradientTop, AppTheme.gradientBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            RoundedRectangle(cornerRadius: 0)
                .fill(.regularMaterial.opacity(0.18))
                .ignoresSafeArea()
        }
    }
}

#Preview {
    AppBackground()
}
