import SwiftUI
import NodysseyNativeCore

struct LibraryCommunityMenu: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var site = NativeStore()
    @State private var attempt = 0
    var body: some View {
        List {
            LibraryStoreStatus(store: site) { attempt += 1 }
            Section(libraryL("browse")) {
                entry("Award", "award")
                webEntry("providers", path: "/providers")
                webEntry("friends", path: "/friends")
            }
            Section(libraryL("play")) {
                entry("Lucky", "lucky")
                entry("Invite", "invite")
            }
            Section(libraryL("watch")) {
                entry("Ruling", "ruling")
                entry("ReportCompare", "reports")
                entry("TrackedThreads", "tracked")
            }
            Section { entry("AboutCommunity", "aboutCommunity") }
        }.navigationTitle(libraryL("tools"))
            .task(id: "\(app.generation)-\(attempt)") { await site.load(app, "site.get") }
    }
    private func entry(_ route: String, _ key: String) -> some View {
        Button { app.open(route) } label: { directoryLabel(key) }
    }
    private func webEntry(_ key: String, path: String) -> some View {
        Button {
            if let url = LibraryRows.communityURL(site.value, path: path) { app.openLink(url) }
        } label: { directoryLabel(key) }
        .disabled(LibraryRows.communityURL(site.value, path: path) == nil)
    }
    private func directoryLabel(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(libraryL(key)).foregroundStyle(.primary)
            Text(libraryL(key + "Hint")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct LibraryCommunityPage: View {
    @EnvironmentObject private var app: NativeAppModel
    let ruling: Bool
    @StateObject private var store = NativeStore()
    @State private var page: Int64 = 1
    @State private var attempt = 0
    var body: some View {
        List {
            LibraryStoreStatus(store: store) { attempt += 1 }
            if let rows = store.value["items"]?.array {
                if rows.isEmpty { NativeEmptyView(libraryL("empty")) }
                if ruling {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in LibraryRulingRow(row: row) }
                } else {
                    ForEach(rows.compactMap(LibraryIdentifiedRow.init)) { item in LibraryPostRow(row: item.value) }
                }
            }
            LibraryPageControls(page: page, total: store.value["totalPages"]?.int, hasNext: hasNext, busy: store.isLoading) { page = $0 }
        }
        .navigationTitle(libraryL(ruling ? "ruling" : "award"))
        .task(id: "\(app.generation)-\(page)-\(attempt)") { await load() }
        .refreshable { await load() }
    }
    private var hasNext: Bool { store.value["hasNextPage"]?.bool ?? (store.value["totalPages"]?.int.map { page < $0 } ?? false) }
    private func load() async { await store.load(app, ruling ? "community.ruling" : "community.award", ["page": .integer(page)]) }
}

struct LibraryRulingRow: View {
    @EnvironmentObject private var app: NativeAppModel
    let row: JSONValue
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let uid = row["targetUid"]?.int {
                Button(row["targetName"]?.string ?? String(uid)) { app.open("UserSpace", ["uid": .integer(uid)]) }
            } else { Text(row["targetName"]?.string ?? libraryL("unknown")).font(.headline) }
            if let reason = row["reason"]?.string { Text(reason).textSelection(.enabled) }
            ForEach(Array((row["actions"]?.array ?? []).enumerated()), id: \.offset) { _, action in
                HStack(alignment: .top) {
                    Text(libraryL("ruling." + (action["type"]?.string ?? "unknown")))
                    Spacer()
                    Text(actionDetail(action)).foregroundStyle(.secondary)
                }
            }
            if let name = row["moderatorName"]?.string { Text(name).font(.caption) }
            if let date = row["createdAtMillis"]?.int { Text(Date(timeIntervalSince1970: Double(date) / 1000), style: .date).font(.caption) }
            if let id = row["postId"]?.int {
                Button(libraryL("openThread")) {
                    var args: [String: JSONValue] = ["postId": .integer(id)]
                    if let floor = row["floor"], floor != .null { args["floor"] = floor }
                    app.open("PostDetail", args)
                }
            }
        }
    }
    private func actionDetail(_ value: JSONValue) -> String {
        switch value["type"]?.string {
        case "Coin", "Stardust": return libraryScalar(value["diff"])
        case "Title": return libraryScalar(value["title"])
        case "Move": return libraryScalar(value["boardSlug"])
        case "ReadRank": return libraryScalar(value["rank"])
        case "Lock": return value["locked"]?.bool.map { libraryL($0 ? "locked" : "unlocked") } ?? libraryL("unknown")
        case "Award": return value["award"]?.bool.map { libraryL($0 ? "awarded" : "unawarded") } ?? libraryL("unknown")
        case "Hide": return "\(libraryScalar(value["hidden"])) · \(libraryL("wholeUser")): \(libraryScalar(value["wholeUser"]))"
        case "Pin": return value["pinned"]?.bool.map { libraryL($0 ? "pinned" : "unpinned") } ?? libraryL("unknown")
        case "Suspend": return value["days"] == .null ? libraryL("unsuspend") : "\(libraryScalar(value["days"])) \(libraryL("days"))"
        default: return libraryL("unknown")
        }
    }
}

struct LibraryLuckyScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var action = LibraryAction()
    @State private var post = ""
    @State private var prizes = "1"
    @State private var floor = "1"
    @State private var date = Date()
    @State private var dedupe = true
    @State private var generated: String?
    var body: some View {
        Form {
            LibraryActionStatus(action: action)
            Text(libraryL("luckyHint")).font(.footnote)
            TextField(libraryL("postID"), text: $post)
            DatePicker(libraryL("drawAt"), selection: $date)
            TextField(libraryL("prizes"), text: $prizes)
            TextField(libraryL("startFloor"), text: $floor)
            Toggle(libraryL("dedupe"), isOn: $dedupe)
            Button(libraryL("generate")) {
                action.run {
                    guard let id = Int64(post), id > 0, let count = Int64(prizes), count > 0, let start = Int64(floor), start >= 0 else { throw NativeFailure(code: "INVALID_ARGUMENT", message: "") }
                    let result = try await app.request("community.lucky", ["postId": .integer(id), "drawAtMillis": .integer(Int64(date.timeIntervalSince1970 * 1000)), "prizeCount": .integer(count), "startFloor": .integer(start), "dedupeFloors": .bool(dedupe)])
                    guard let url = result["url"]?.string else { throw NativeFailure(code: "INVALID_DATA", message: "") }
                    generated = url
                }
            }.disabled(action.busy)
            if let generated {
                Text(generated).textSelection(.enabled)
                ShareLink(item: generated)
                Button(libraryL("open")) { app.openLink(generated) }
            }
        }.navigationTitle(libraryL("lucky"))
        .onChange(of: post) { _ in generated = nil }
        .onChange(of: prizes) { _ in generated = nil }
        .onChange(of: floor) { _ in generated = nil }
        .onChange(of: date) { _ in generated = nil }
        .onChange(of: dedupe) { _ in generated = nil }
        .onDisappear { action.cancel() }
    }
}

struct LibraryInviteScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var store = NativeStore()
    @State private var confirm = false
    @State private var attempt = 0
    var body: some View {
        Form {
            LibraryStoreStatus(store: store) { attempt += 1 }
            LibraryField(label: "chickenCount", value: store.value["chickenCount"])
            Text(libraryL("inviteHint"))
            if store.value["purchaseRequiresWeb"]?.bool == true, store.value["url"]?.string != nil {
                Button(libraryL("purchaseInvite")) { if app.isSignedIn { confirm = true } else { app.showSignIn() } }
            }
        }
        .navigationTitle(libraryL("invite"))
        .task(id: "\(app.generation)-\(attempt)") { await store.load(app, "community.invite") }
        .refreshable { await store.load(app, "community.invite") }
        .confirmationDialog(libraryL("inviteConfirm"), isPresented: $confirm, titleVisibility: .visible) {
            Button(libraryL("continue")) {
                if let url = store.value["url"]?.string { app.open("Web", ["url": .string(url), "goal": .string("MANAGE"), "title": .string(libraryL("invite"))]) }
            }
        }
    }
}

struct LibraryAboutScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.openURL) private var openURL
    @StateObject private var site = NativeStore()
    @StateObject private var stats = NativeStore()
    @State private var attempt = 0
    // Original community catalogue: AboutCommunityScreen.kt / CommunityLinks (5151561/nodyssey).
    private let links = [
        ("telegramChannel", "https://t.me/nodeseekc"), ("telegramGroup", "https://t.me/nodeseekg"),
        ("email", "mailto:Lloyd@nodeseek.com"), ("DeepFlood", "https://www.deepflood.com"),
        ("LowEndTalk", "https://lowendtalk.com"), ("LowEndSpirit", "https://lowendspirit.com"),
        ("HostLoc", "https://hostloc.com"), ("ServerHunter", "https://www.serverhunter.com")
    ]
    var body: some View {
        List {
            Section(currentSite?["displayName"]?.string ?? libraryL("aboutCommunity")) {
                LibraryStoreStatus(store: site)
                Text(libraryL("communityIntro"))
                if let url = LibraryRows.communityURL(site.value, path: "/about") {
                    Button(libraryL("aboutCommunity")) { app.openLink(url) }
                }
                LibraryStoreStatus(store: stats) { attempt += 1 }
                LibraryField(label: "memberCount", value: stats.value["memberCount"])
                Button(libraryL("refresh")) { attempt += 1 }
            }
            Section("NodeSeek") {
                Button(libraryL("privacy")) { app.open("Privacy") }
                if let url = LibraryRows.communityURL(site.value, path: "/rss.xml") {
                    Text(url).textSelection(.enabled)
                    ShareLink(item: url) { Text(libraryL("rss")) }
                }
                ForEach(links, id: \.1) { label, url in
                    Button(libraryL(label)) {
                        if url.hasPrefix("mailto:"), let address = URL(string: url) { openURL(address) }
                        else { app.openLink(url) }
                    }
                }
            }
            Section(libraryL("attribution")) {
                Text("Nodyssey · 5151561 · GPL-3.0")
                Button(libraryL("originalProject")) { app.openLink("https://github.com/5151561/nodyssey") }
            }
        }
        .navigationTitle(libraryL("aboutCommunity"))
        .task(id: app.generation) { await site.load(app, "site.get") }
        .task(id: "\(app.generation)-\(attempt)") { await stats.load(app, "community.memberCount") }
        .refreshable { await stats.load(app, "community.memberCount") }
    }
    private var currentSite: JSONValue? {
        site.value["sites"]?.array?.first { $0["id"] == site.value["current"] }
    }
}
