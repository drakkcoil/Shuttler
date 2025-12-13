import SwiftUI

struct TransferHUD: View {
    @ObservedObject var manager: TransferManager = .shared

    var body: some View {
        Group {
            if manager.transfers.isEmpty { EmptyView() }
            else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Transfers", systemImage: "arrow.up.arrow.down")
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
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(radius: 6)
            }
        }
        .frame(maxWidth: 360)
        .padding()
        .background(
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding()
        )
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
            }
            ProgressView(value: t.progress)
                .progressViewStyle(.linear)
        }
    }
}

#Preview {
    TransferHUD()
}
