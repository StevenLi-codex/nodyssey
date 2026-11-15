import SwiftUI
import NodysseyNativeCore

/// The Android profile is a directory, not a long settings menu. Keep its
/// content/community grouping, with native symbols and no per-entry card chrome.
struct AccountProfileDirectory: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entries: [Entry]

    struct Entry: Identifiable {
        let title: String
        let symbol: String
        let route: String
        let arguments: [String: JSONValue]
        var id: String { title }
        init(_ title: String, _ symbol: String, _ route: String, _ arguments: [String: JSONValue] = [:]) {
            self.title = title; self.symbol = symbol; self.route = route; self.arguments = arguments
        }
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 240 : 88), spacing: 8)], spacing: 8) {
            ForEach(entries) { entry in
                Button { app.open(entry.route, entry.arguments) } label: {
                    VStack(spacing: 7) {
                        Image(systemName: entry.symbol).font(.body).foregroundStyle(.tint).accessibilityHidden(true)
                        Text(LocalizedStringKey(entry.title)).font(.subheadline).foregroundStyle(.primary)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 8).frame(maxWidth: .infinity, minHeight: 56)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.padding(.vertical, 4)
    }
}

struct AccountProfileBalances: View {
    @EnvironmentObject private var app: NativeAppModel
    let profile: JSONValue
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) { balances }
            VStack(alignment: .leading, spacing: 4) { balances }
        }
    }
    private var balances: some View {
        Group {
            balance("profile_chicken", key: "chickenCount", route: "Credit")
            balance("profile_stars", key: "starCount", route: "Stardust")
        }
    }
    private func balance(_ title: LocalizedStringKey, key: String, route: String) -> some View {
        Button { app.open(route) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.nativeInt(key).map(String.init) ?? "—").font(.headline).monospacedDigit().foregroundStyle(.primary)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityElement(children: .combine)
    }
}
