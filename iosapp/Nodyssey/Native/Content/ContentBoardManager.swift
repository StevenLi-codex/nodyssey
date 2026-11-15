import SwiftUI
import NodysseyNativeCore

struct ContentBoardManager: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.dismiss) private var dismiss
    let categories: JSONValue
    @Binding var selection: String
    @State private var arranging = false
    @StateObject private var command = ContentCommand()
    @State private var order: [String] = []
    @State private var disabled = Set<String>()
    var body: some View {
        List {
            ContentCommandStatus(command: command)
            if !arranging {
                Button { selection = ""; dismiss() } label: { boardLabel("", title: String(localized: "content.all", table: "Content")) }
                ForEach(order, id: \.self) { slug in
                    Button { selection = slug; dismiss() } label: { boardLabel(slug, title: title(slug)) }
                }
            } else {
                ForEach(order, id: \.self) { slug in
                    Toggle(isOn: Binding(get: { !disabled.contains(slug) && !hidden.contains(slug) }, set: { enabled in
                        if enabled { disabled.remove(slug) } else { disabled.insert(slug) }
                    })) {
                        VStack(alignment: .leading) {
                            Text(title(slug))
                            if hidden.contains(slug) { Text("board_parked").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    // Legacy hidden preferences are not writable through settings.homeBoards.
                    // Keep these boards selectable in browse mode, never offer a no-op restore.
                    .disabled(command.busy || hidden.contains(slug))
                }.onMove { indices, offset in order.move(fromOffsets: indices, toOffset: offset) }
            }
        }
        .navigationTitle(Text(String(localized: "content.manageBoards", table: "Content")))
        .toolbar {
            Button(arranging ? String(localized: "content.board", table: "Content") : String(localized: "content.manageBoards", table: "Content")) { arranging.toggle() }
            #if os(iOS)
            if arranging { EditButton() }
            #endif
            if arranging { Button(String(localized: "content.save", table: "Content")) {
                command.run(app) {
                    _ = try await app.request("settings.homeBoards", ["order": .array(order.map(JSONValue.string)), "disabled": .array(disabled.sorted().map(JSONValue.string))])
                    _ = try await app.request("settings.get")
                    try Task.checkCancellation(); dismiss()
                }
            }.disabled(command.busy) }
            Button(String(localized: "content.cancel", table: "Content")) { dismiss() }
        }
        .task {
            let available = (categories.array ?? []).compactMap { $0.nativeString("slug") }.filter { !$0.isEmpty }
            let preferred = app.settings.nativeArray("homeBoardOrder").compactMap(\.string)
            order = preferred.filter { available.contains($0) } + available.filter { !preferred.contains($0) }
            disabled = Set(app.settings.nativeArray("disabledHomeBoards").compactMap(\.string))
        }
        .onDisappear { command.cancel() }
    }
    private var hidden: Set<String> { Set(app.settings.nativeArray("hiddenHomeBoards").compactMap(\.string)) }
    private func title(_ slug: String) -> String {
        (categories.array ?? []).first { $0.nativeString("slug") == slug }?.nativeString("title") ?? slug
    }
    private func boardLabel(_ slug: String, title: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let description = (categories.array ?? []).first(where: { $0.nativeString("slug") == slug })?.nativeString("description"), !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if disabled.contains(slug) || app.settings.nativeArray("hiddenHomeBoards").contains(.string(slug)) {
                Image(systemName: "eye.slash").accessibilityLabel(Text("board_parked"))
            }
            if selection == slug { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }.frame(minHeight: 44).contentShape(Rectangle())
    }
}
