import SwiftUI
import NodysseyNativeCore

struct ContentBoardManager: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.dismiss) private var dismiss
    let categories: JSONValue
    @StateObject private var command = ContentCommand()
    @State private var order: [String] = []
    @State private var disabled = Set<String>()
    var body: some View {
        List {
            ContentCommandStatus(command: command)
            ForEach(order, id: \.self) { slug in
                Toggle(isOn: Binding(get: { !disabled.contains(slug) }, set: { enabled in
                    if enabled { disabled.remove(slug) } else { disabled.insert(slug) }
                })) {
                    Text((categories.array ?? []).first { $0.nativeString("slug") == slug }?.nativeString("title") ?? slug)
                }
            }.onMove { indices, offset in order.move(fromOffsets: indices, toOffset: offset) }
        }
        .navigationTitle(Text(String(localized: "content.manageBoards", table: "Content")))
        .toolbar {
            #if os(iOS)
            EditButton()
            #endif
            Button(String(localized: "content.save", table: "Content")) {
                command.run(app) {
                    _ = try await app.request("settings.homeBoards", ["order": .array(order.map(JSONValue.string)), "disabled": .array(disabled.sorted().map(JSONValue.string))])
                    _ = try await app.request("settings.get")
                    try Task.checkCancellation(); dismiss()
                }
            }.disabled(command.busy)
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
}
