import SwiftUI
import NodysseyNativeCore

func CT(_ key: String) -> String { NSLocalizedString("content." + key, tableName: "Content", bundle: .main, comment: "") }

struct ContentThreadPageRail: View {
    let page: Int64
    let total: Int64
    let expanded: Bool
    let enabled: Bool
    let previous: () -> Void
    let next: () -> Void
    let jump: () -> Void
    let reply: () -> Void
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            VStack(spacing: 0) {
                Button(action: jump) {
                    VStack(spacing: 0) {
                        Text("\(page)").font(.subheadline.weight(.semibold))
                        Text("/ \(total)").font(.caption2).foregroundStyle(.secondary)
                    }.monospacedDigit().frame(minWidth: 48, minHeight: 48)
                }.accessibilityLabel(CT("page"))
                if expanded {
                    Button(action: previous) { Image(systemName: "chevron.up").frame(minWidth: 48, minHeight: 44) }
                        .disabled(page <= 1).accessibilityLabel(CT("previous"))
                    Button(action: next) { Image(systemName: "chevron.down").frame(minWidth: 48, minHeight: 44) }
                        .disabled(page >= total).accessibilityLabel(CT("next"))
                }
            }.background(.background, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.secondary.opacity(0.18)))
            Button(action: reply) {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left")
                    if expanded { Text(CT("reply")) }
                }.font(.subheadline.weight(.semibold)).padding(.horizontal, 16).frame(minWidth: 56, minHeight: 56)
            }.background(.background, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.secondary.opacity(0.18)))
        }.buttonStyle(.plain).foregroundStyle(.tint).disabled(!enabled)
    }
}

struct ContentThreadJumpSheet: View {
    let page: Int64
    let total: Int64
    let loadedCount: Int
    let resume: ContentReadingTarget?
    let go: (ContentReadingTarget, Bool) -> Void
    @State private var entry = ContentJumpEntry()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    if let resume, resume.page != page {
                        Button { go(resume, false) } label: {
                            Label { VStack(alignment: .leading) { Text(CT("resume")); Text("\(resume.page)" + (resume.floor.map { " · " + $0 } ?? "")).font(.caption) } } icon: { Image(systemName: "bookmark") }
                                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        }
                    }
                    Button { go(.init(floor: nil, page: total), true) } label: {
                        Label { VStack(alignment: .leading) { Text(CT("latest")); Text("\(total)").font(.caption) } } icon: { Image(systemName: "arrow.down.to.line") }
                            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    }
                }.buttonStyle(.bordered)
                if total > 1 {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 8) {
                                ForEach(1...max(1, total), id: \.self) { number in
                                    Button { go(.init(floor: nil, page: number), false) } label: {
                                        Text("\(number)").monospacedDigit().frame(minWidth: 48, minHeight: 48)
                                            .background(number == page ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                                    }.id(number)
                                }
                            }
                        }.onAppear { proxy.scrollTo(page, anchor: .center) }
                    }
                }
                HStack {
                    TextField(entry.floor ? "#" : "\(page)", text: Binding(get: { entry.text }, set: { entry.update($0) }))
                        .textFieldStyle(.roundedBorder).onSubmit(submit)
                        #if os(iOS)
                        .keyboardType(.numberPad).submitLabel(.go)
                        #endif
                        .accessibilityLabel(CT(entry.floor ? "floor" : "page"))
                    Text("/ \(total)").font(.caption).foregroundStyle(.secondary)
                    Button { entry.toggleUnit() } label: {
                        Label(CT(entry.floor ? "floor" : "page"), systemImage: "arrow.up.arrow.down").frame(minHeight: 44)
                    }
                    Button(action: submit) { Image(systemName: "arrow.right").frame(minWidth: 44, minHeight: 44) }
                        .disabled(entry.target(total: total) == nil).accessibilityLabel(CT("go"))
                }
                Text(String(format: CT("loadedFloors"), loadedCount)).font(.caption).foregroundStyle(.secondary)
            }.padding(16)
        }.accessibilityLabel(CT("page"))
            .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private func submit() { if let target = entry.target(total: total) { go(target, false) } }
}

struct ContentThreadFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}
struct ContentThreadRailHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
struct ContentThreadFrame: ViewModifier {
    let id: String
    func body(content: Content) -> some View {
        content.background(GeometryReader { geometry in
            Color.clear.preference(key: ContentThreadFrames.self, value: [id: geometry.frame(in: .named("thread.viewport"))])
        })
    }
}
