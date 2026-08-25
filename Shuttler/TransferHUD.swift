import SwiftUI
#if os(macOS)
import AppKit
#endif

struct TransferHUD: View {
    @ObservedObject var manager: TransferManager = .shared
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        Group {
            if manager.transfers.isEmpty { EmptyView() }
            else {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    HStack {
                        Label("Transfers", systemImage: "arrow.up.arrow.down.circle")
                            .font(.headline)
                        Spacer()
                        Button { withAnimation { manager.isExpanded.toggle() } } label: {
                            Image(systemName: manager.isExpanded ? "chevron.down" : "chevron.up")
                        }
                        .buttonStyle(.plain)
                    }
                    if manager.isExpanded {
                        ForEach(manager.transfers) { t in
                            transferRow(t)
                        }
                    } else if let t = manager.transfers.last {
                        transferRow(t)
                    }
                }
                .padding(AppTheme.Spacing.m)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(radius: 6)
                .frame(maxWidth: 360)
                .offset(x: dragOffset.width, y: dragOffset.height)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            dragOffset = value.translation
                        }
                        .onEnded { value in
                            // Keep the offset so the HUD stays in the new position
                            dragOffset = value.translation
                        }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding()
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func transferRow(_ t: ActiveTransfer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: t.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                Text(t.name)
                    .lineLimit(1)
                Spacer()
                Text("\(Int(t.progress * 100))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    manager.cancel(id: t.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel transfer")
            }
            ProgressView(value: t.progress)
                .progressViewStyle(.linear)
        }
    }
}

#Preview {
    TransferHUD()
}
