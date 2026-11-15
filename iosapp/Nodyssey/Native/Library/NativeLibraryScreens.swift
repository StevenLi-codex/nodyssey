import SwiftUI
import NodysseyNativeCore

/// Native counterparts of the original Nodyssey library/community routes.
/// Existing Kotlin repositories and original authorship remain authoritative.
@MainActor enum NativeLibraryScreens {
    static func make(destination: NativeDestination) -> AnyView? {
        switch destination.route {
        case "Bookmarks": return AnyView(LibraryBookmarksScreen())
        case "ReadHistory": return AnyView(LibraryHistoryScreen())
        case "Assets": return AnyView(LibraryAssetsScreen())
        case "Credit": return AnyView(LibraryLedgerScreen(stardust: false))
        case "Stardust": return AnyView(LibraryStardustScreen(arguments: destination.arguments))
        case "CommunityTools": return AnyView(LibraryCommunityMenu())
        case "Award": return AnyView(LibraryCommunityPage(ruling: false))
        case "Ruling": return AnyView(LibraryCommunityPage(ruling: true))
        case "Lucky": return AnyView(LibraryLuckyScreen())
        case "Invite": return AnyView(LibraryInviteScreen())
        case "ReportCompare": return AnyView(LibraryReportsScreen(arguments: destination.arguments))
        case "TrackedThreads": return AnyView(LibraryTrackedScreen())
        case "AboutCommunity": return AnyView(LibraryAboutScreen())
        default: return nil
        }
    }
}

func libraryL(_ key: String) -> String {
    String(localized: String.LocalizationValue("library." + key), table: "Library", comment: "Native library")
}

@MainActor final class LibraryAction: ObservableObject {
    @Published var busy = false
    @Published var failure: NativeFailure?
    @Published var notice: String?
    private var task: Task<Void, Never>?
    func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; failure = nil; notice = nil
        task = Task {
            defer { busy = false }
            do { try await operation() }
            catch is CancellationError { }
            catch let error as NativeFailure { failure = error }
            catch { failure = NativeFailure(code: "INTERNAL", message: "") }
        }
    }
    func cancel() { task?.cancel(); task = nil }
}

@MainActor func libraryRead(_ store: NativeStore, _ app: NativeAppModel, _ operation: String, _ arguments: [String: JSONValue] = [:]) async {
    // A read-back must NOT call NativeStore.load on an observing store: load cancels its subscription.
    let generation = app.generation
    do {
        let value = try await app.request(operation, arguments)
        try Task.checkCancellation()
        guard generation == app.generation else { return }
        store.value = value; store.failure = nil
    }
    catch is CancellationError { }
    catch let failure as NativeFailure { store.failure = failure }
    catch { store.failure = NativeFailure(code: "INTERNAL", message: "") }
}

struct LibraryActionStatus: View {
    @ObservedObject var action: LibraryAction
    var body: some View {
        if action.busy { ProgressView() }
        if let failure = action.failure { NativeFailureView(failure: failure) }
        if let notice = action.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
    }
}

struct LibraryStoreStatus: View {
    @ObservedObject var store: NativeStore
    var retry: (() -> Void)? = nil
    var body: some View {
        if store.isLoading { ProgressView() }
        if let failure = store.failure { NativeFailureView(failure: failure, retry: retry) }
    }
}

struct LibraryField: View {
    let label: String
    let value: JSONValue?
    var body: some View {
        HStack(alignment: .top) {
            Text(libraryL(label))
            Spacer()
            Text(libraryScalar(value)).foregroundStyle(.secondary).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}

func libraryScalar(_ value: JSONValue?) -> String {
    switch value {
    case .string(let text): return text
    case .integer(let number): return String(number)
    case .number(let number): return String(number)
    case .bool(let value): return libraryL(value ? "yes" : "no")
    default: return libraryL("unknown")
    }
}

struct LibraryPostRow: View {
    @EnvironmentObject private var app: NativeAppModel
    let row: JSONValue
    var countKey = "commentCount"
    var showsReadTime = false
    var select: (() -> Void)? = nil
    var body: some View {
        if let id = row["postId"]?.int, id > 0 {
            Button {
                if let select { select(); return }
                guard let arguments = LibraryRows.threadArguments(row) else { return }
                app.open("PostDetail", arguments)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row["title"]?.string ?? "#\(id)").foregroundStyle(.primary)
                    HStack {
                        if let author = row["authorName"]?.string { Text(author) }
                        if let category = row["categoryTitle"]?.string { Text(category) }
                        if !showsReadTime, let count = row[countKey]?.int, count >= 0 { Label(String(count), systemImage: "bubble.right") }
                    }.font(.caption).foregroundStyle(.secondary)
                    if showsReadTime, let millis = row["lastReadAtMillis"]?.int {
                        Text(Date(timeIntervalSince1970: Double(millis) / 1000).formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.buttonStyle(.plain)
        }
    }
}

struct LibraryPageControls: View {
    let page: Int64
    let total: Int64?
    let hasNext: Bool
    var busy: Bool
    var change: (Int64) -> Void
    @State private var jump = ""
    var body: some View {
        HStack {
            Button { change(max(1, page - 1)) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel(libraryL("previous")).disabled(page <= 1 || busy)
            Text(total.map { "\(page) / \($0)" } ?? String(page)).monospacedDigit()
            Button { if page < Int64(Int32.max) { change(page + 1) } } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel(libraryL("next")).disabled(!hasNext || busy)
            TextField(libraryL("page"), text: $jump).frame(maxWidth: 90)
            Button(libraryL("go")) {
                if let n = Int32(jump), n > 0, total == nil || Int64(n) <= total! { change(Int64(n)) }
            }.disabled(busy || Int64(jump).map { $0 <= 0 || (total != nil && $0 > total!) } != false)
        }
    }
}
