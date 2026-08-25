import SwiftUI

struct PreferencesView: View {
    @AppStorage(AppSettingsKeys.listDensity) private var listDensityRaw: String = ListDensity.comfortable.rawValue
    @AppStorage(AppSettingsKeys.sortKey) private var sortKeyRaw: String = SortKey.name.rawValue
    @AppStorage(AppSettingsKeys.sortAscending) private var sortAscending: Bool = true
    @AppStorage(AppSettingsKeys.foldersFirst) private var foldersFirst: Bool = true

    var body: some View {
        NavigationStack {
            TabView {
                generalView
                    .tabItem {
                        Label("General", systemImage: "gearshape")
                    }
                appearanceView
                    .tabItem {
                        Label("Appearance", systemImage: "paintbrush")
                    }
            }
            .padding(AppTheme.Spacing.m)
            .frame(minWidth: 420, minHeight: 200)
            .navigationTitle("Preferences")
        }
    }

    private var generalView: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            Toggle("Folders first", isOn: $foldersFirst)
            Toggle("Sort ascending", isOn: $sortAscending)
            Picker("Sort by", selection: $sortKeyRaw) {
                Text("Name").tag(SortKey.name.rawValue)
                Text("Size").tag(SortKey.size.rawValue)
                Text("Kind").tag(SortKey.kind.rawValue)
            }
            .pickerStyle(.segmented)
            Spacer()
        }
        .padding(AppTheme.Spacing.m)
    }

    private var appearanceView: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            Picker("List Density", selection: $listDensityRaw) {
                Text("Comfortable").tag(ListDensity.comfortable.rawValue)
                Text("Compact").tag(ListDensity.compact.rawValue)
            }
            .pickerStyle(.segmented)
            Spacer()
        }
        .padding(AppTheme.Spacing.m)
    }
}

#Preview {
    PreferencesView()
}
