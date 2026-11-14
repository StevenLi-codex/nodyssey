import SwiftUI
import NodysseyNativeCore

struct LibraryAssetsScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var growth = NativeStore()
    @StateObject private var attendance = NativeStore()
    @StateObject private var board = NativeStore()
    @StateObject private var action = LibraryAction()
    @State private var mode = "FIXED_FIVE"
    @State private var confirm = false
    @State private var boardPage: Int64 = 1
    var body: some View {
        List {
            LibraryStoreStatus(store: growth) { action.run { await growth.load(app, "assets.growth") } }
            LibraryActionStatus(action: action)
            LibraryGrowth(value: growth.value)
            Section {
                Button(libraryL("credit")) { app.open("Credit") }
                Button(libraryL("stardust")) { app.open("Stardust") }
                Button(libraryL("invite")) { app.open("Invite") }
            }
            Section(libraryL("attendance")) {
                LibraryStoreStatus(store: attendance)
                LibraryField(label: "date", value: attendance.value["date"])
                LibraryField(label: "signed", value: attendance.value["hasSignedIn"])
                LibraryField(label: "gain", value: attendance.value["gain"])
                Picker(libraryL("attendanceMode"), selection: $mode) {
                    Text(libraryL("fixedFive")).tag("FIXED_FIVE")
                    Text(libraryL("random")).tag("RANDOM")
                }
                Button(libraryL("sign")) {
                    if app.isSignedIn { confirm = true } else { app.showSignIn() }
                }.disabled(action.busy || attendance.value == .null || attendance.value["hasSignedIn"]?.bool == true)
            }
            Section(libraryL("attendanceBoard")) {
                LibraryStoreStatus(store: board) { action.run { await loadBoard() } }
                ForEach(Array((board.value.array ?? []).enumerated()), id: \.offset) { _, row in
                    HStack {
                        if let uid = row["uid"]?.int {
                            Button(row["name"]?.string ?? String(uid)) { app.open("UserSpace", ["uid": .integer(uid)]) }
                        } else { Text(row["name"]?.string ?? libraryL("unknown")) }
                        Spacer()
                        Text(libraryScalar(row["gain"]))
                        if let time = row["timeText"]?.string { Text(time).font(.caption) }
                    }
                }
                LibraryPageControls(page: boardPage, total: nil, hasNext: !(board.value.array ?? []).isEmpty, busy: board.isLoading) { boardPage = $0 }
            }
        }
        .navigationTitle(libraryL("assets"))
        .task(id: app.generation) { await growth.load(app, "assets.growth") }
        .task(id: app.generation) { await attendance.observe(app, "attendance.status") }
        .task(id: "\(app.generation)-\(boardPage)") { await loadBoard() }
        .refreshable { await growth.load(app, "assets.growth"); await libraryRead(attendance, app, "attendance.status"); await loadBoard() }
        .confirmationDialog(libraryL("signConfirm"), isPresented: $confirm, titleVisibility: .visible) {
            Button(libraryL("sign")) {
                let selectedMode = mode
                action.run {
                    do {
                        let result = try await app.request("attendance.sign", ["mode": .string(selectedMode), "confirmed": .bool(true)])
                        action.notice = result["message"]?.string ?? libraryL("acknowledged")
                    } catch {
                        await libraryRead(attendance, app, "attendance.status")
                        await growth.load(app, "assets.growth")
                        throw error
                    }
                    await libraryRead(attendance, app, "attendance.status")
                    await growth.load(app, "assets.growth")
                    await loadBoard()
                }
            }
        }
        .onDisappear { action.cancel() }
    }
    private func loadBoard() async { await board.load(app, "attendance.board", ["page": .integer(boardPage)]) }
}

struct LibraryGrowth: View {
    let value: JSONValue
    var body: some View {
        if value != .null {
            Section(libraryL("growth")) {
                ForEach(["level", "chickenCount", "starCount"], id: \.self) { key in LibraryField(label: key, value: value[key]) }
                if let floor = value["levelSpan"]?["floor"]?.int, let next = value["levelSpan"]?["next"]?.int,
                   let current = value["chickenCount"]?.int, next > floor {
                    ProgressView(value: min(1, max(0, Double(current - floor) / Double(next - floor))))
                    Text("\(floor) – \(next)").font(.caption)
                }
                ForEach(["postQuota", "commentQuota", "attendanceQuota", "feedingQuota"], id: \.self) { key in
                    HStack { Text(libraryL(key)); Spacer(); Text("\(libraryScalar(value[key]?["used"])) / \(libraryScalar(value[key]?["total"]))").foregroundStyle(.secondary) }
                }
            }
        }
    }
}

struct LibraryLedgerScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    let stardust: Bool
    @StateObject private var store = NativeStore()
    @StateObject private var growth = NativeStore()
    @State private var page: Int64 = 1
    @State private var before: Int64?
    @State private var cursors: [Int64?] = []
    @State private var type = "all"
    var body: some View {
        List {
            LibraryStoreStatus(store: store)
            LibraryStoreStatus(store: growth)
            LibraryGrowth(value: growth.value)
            if stardust {
                Picker(libraryL("type"), selection: $type) {
                    Text(libraryL("all")).tag("all")
                    ForEach(types, id: \.self) { Text(libraryL("ledger." + $0)).tag($0) }
                }
            }
            if rows.isEmpty && !store.isLoading { NativeEmptyView(libraryL("empty")) }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in LibraryLedgerRow(row: row, stardust: stardust) }
            if stardust {
                HStack {
                    Button(libraryL("previous")) { if !cursors.isEmpty { before = cursors.removeLast() } }.disabled(cursors.isEmpty || store.isLoading)
                    Spacer()
                    Button(libraryL("next")) {
                        if let cursor = store.value["cursor"]?.int { cursors.append(before); before = cursor }
                    }.disabled(store.value["hasMore"]?.bool != true || store.value["cursor"]?.int == nil || store.isLoading)
                }
            } else {
                LibraryPageControls(page: page, total: store.value["totalPages"]?.int, hasNext: store.value["hasNextPage"]?.bool == true, busy: store.isLoading) { page = $0 }
            }
        }
        .navigationTitle(libraryL(stardust ? "stardust" : "credit"))
        .task(id: "\(app.generation)-\(page)-\(before.map(String.init) ?? "first")") { await load() }
        .task(id: app.generation) { await growth.load(app, "assets.growth") }
        .refreshable { await load(); await growth.load(app, "assets.growth") }
    }
    private var rows: [JSONValue] { (store.value["items"]?.array ?? []).filter { type == "all" || $0["type"]?.string == type } }
    private var types: [String] { ["UPVOTE", "TRANSFER", "BUY_CODE", "SYSTEM", "ADMIN", "UNKNOWN"] }
    private func load() async {
        var args: [String: JSONValue] = stardust ? [:] : ["page": .integer(page)]
        if let before { args["beforeId"] = .integer(before) }
        await store.load(app, stardust ? "assets.stardust" : "assets.credit", args)
    }
}

struct LibraryLedgerRow: View {
    @EnvironmentObject private var app: NativeAppModel
    let row: JSONValue
    let stardust: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(stardust ? libraryL("ledger." + (row["type"]?.string ?? "OTHER")) : (row["reason"]?.string ?? libraryL("unknown")))
                Spacer()
                Text(libraryScalar(row[stardust ? "diff" : "change"])).monospacedDigit()
            }
            LibraryField(label: "balanceAfter", value: row["balanceAfter"])
            if let peer = row["peerUid"]?.int { Button("\(libraryL("member")) #\(peer)") { app.open("UserSpace", ["uid": .integer(peer)]) } }
            if let date = row["createdAtMillis"]?.int { Text(Date(timeIntervalSince1970: Double(date) / 1000), style: .date).font(.caption) }
            if let raw = row["rawType"]?.string { Text(raw).font(.caption) }
        }
    }
}

struct LibraryStardustScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    let arguments: [String: JSONValue]
    @StateObject private var action = LibraryAction()
    @StateObject private var growth = NativeStore()
    @State private var recipient = ""
    @State private var amount = ""
    @State private var refId = "0"
    @State private var onetime = false
    @State private var description = ""
    @State private var reviewed: LibraryPayment?
    @State private var receiverName: String?
    @State private var ownUID: Int64?
    @State private var receipts: [JSONValue] = []
    @State private var confirm = false
    @State private var needsReadback = false
    @State private var marker: String?
    @State private var ledger: JSONValue = .null
    var body: some View {
        Form {
            LibraryActionStatus(action: action)
            LibraryStoreStatus(store: growth)
            LibraryGrowth(value: growth.value)
            Section {
                NavigationLink(libraryL("ledger")) { LibraryLedgerScreen(stardust: true) }
            }
            Section(libraryL("transfer")) {
                Group {
                    TextField(libraryL("recipient"), text: $recipient)
                    TextField(libraryL("amount"), text: $amount)
                    TextField(libraryL("reference"), text: $refId)
                    Toggle(libraryL("onetime"), isOn: $onetime)
                }.disabled(arguments["memberId"] != nil || action.busy)
                if !description.isEmpty { Text(description).font(.footnote) }
                Button(libraryL("reviewPayment")) { review() }.disabled(action.busy)
                if let review = reviewed {
                    LibraryField(label: "receiver", value: receiverName.map(JSONValue.string))
                    Text("#\(review.recipient) · \(review.amount) \(libraryL("stardust"))")
                    if ownUID == review.recipient { Text(libraryL("selfPayment")) }
                    if review.onetime && !receipts.isEmpty { Text(libraryL("alreadyPaid")) }
                    Button(libraryL("pay")) { confirm = true }
                        .disabled(action.busy || ownUID == nil || ownUID == review.recipient || (review.onetime && !receipts.isEmpty) || needsReadback)
                }
                if needsReadback { Text(libraryL("readbackRequired")).font(.footnote) }
            }
            if !receipts.isEmpty {
                Section(libraryL("receipts")) {
                    ForEach(Array(receipts.enumerated()), id: \.offset) { _, row in LibraryLedgerRow(row: row, stardust: true) }
                }
            }
            if let rows = ledger["items"]?.array {
                Section(libraryL("ledger")) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in LibraryLedgerRow(row: row, stardust: true) }
                }
            }
            if arguments["memberId"] == nil {
            Section(libraryL("receiveCode")) {
                TextField(libraryL("description"), text: $description)
                Text(libraryL("receiveCodeHint")).font(.footnote)
                Button(libraryL("generate")) {
                    action.run {
                        guard let number = Int64(amount), number > 0, let ref = Int64(refId), ref >= 0 else { throw NativeFailure(code: "INVALID_ARGUMENT", message: "") }
                        let result = try await app.request("assets.receiveCode", ["amount": .integer(number), "refId": .integer(ref), "description": .string(description), "onetime": .bool(onetime)])
                        marker = result["marker"]?.string
                    }
                }.disabled(action.busy)
                if let marker { Text(marker).textSelection(.enabled); ShareLink(item: marker) }
            }
            }
        }
        .navigationTitle(libraryL("stardust"))
        .task(id: app.generation) {
            reviewed = nil; receipts = []; ledger = .null; marker = nil; ownUID = nil; needsReadback = false
            recipient = (arguments["memberId"]?.int ?? arguments["recipientUid"]?.int).map(String.init) ?? ""
            amount = arguments["amount"]?.int.map(String.init) ?? ""
            refId = arguments["refId"]?.int.map(String.init) ?? "0"
            onetime = arguments["onetime"]?.bool ?? false
            description = arguments["description"]?.string ?? ""
            await growth.load(app, "assets.growth")
        }
        .onChange(of: recipient) { _ in invalidateReview() }
        .onChange(of: amount) { _ in invalidateReview() }
        .onChange(of: refId) { _ in invalidateReview() }
        .onChange(of: onetime) { _ in invalidateReview() }
        .confirmationDialog(libraryL("payConfirm"), isPresented: $confirm, titleVisibility: .visible) {
            if let payment = reviewed {
                Button("\(libraryL("pay")) \(payment.amount) → \(receiverName ?? String(payment.recipient))") {
                    action.run {
                        needsReadback = true
                        let result = try await LibraryOperations.pay(payment, confirmed: true, request: app.request)
                        reviewed = nil
                        ledger = result.ledger
                        if result.growth != .null { growth.value = result.growth }
                        needsReadback = result.refreshFailure != nil
                        action.notice = libraryL(result.acknowledged ? "acknowledged" : "uncertainPayment")
                        action.failure = result.writeFailure ?? result.refreshFailure
                        if let ownUID {
                            let value = try await app.request("assets.receipts", ["memberId": .integer(payment.recipient), "refId": .integer(payment.refId), "peerId": .integer(ownUID)])
                            receipts = value.array ?? []
                        }
                    }
                }
            }
        } message: { Text("\(receiverName ?? recipient) · \(amount) \(libraryL("stardust"))\n\(libraryL("irreversible"))") }
        .onDisappear { action.cancel() }
    }
    private func draftPayment() throws -> LibraryPayment {
        if arguments["memberId"] != nil { return try LibraryPayment(route: arguments) }
        return try LibraryPayment(recipient: recipient, amount: amount, refId: refId, onetime: onetime)
    }
    private func invalidateReview() { reviewed = nil; receipts = []; receiverName = nil }
    private func review() {
        guard app.isSignedIn else { app.showSignIn(); return }
        action.run {
            let payment = try draftPayment()
            let selfProfile = try await app.request("profile.self", ["refresh": .bool(false)])
            guard let uid = selfProfile["uid"]?.int else { throw NativeFailure(code: "INVALID_DATA", message: "") }
            let receiver = try await app.request("assets.recipient", ["recipientUid": .integer(payment.recipient)])
            var receiptArguments: [String: JSONValue] = ["memberId": .integer(payment.recipient), "refId": .integer(payment.refId)]
            if uid != payment.recipient { receiptArguments["peerId"] = .integer(uid) }
            let received = try await app.request("assets.receipts", receiptArguments)
            if needsReadback {
                ledger = try await app.request("assets.stardust")
                growth.value = try await app.request("assets.growth")
                needsReadback = false
            }
            // Do not confirm an old draft if the user edits while lookups are in flight.
            let current = try draftPayment()
            guard current == payment else { return }
            ownUID = uid; receiverName = receiver["name"]?.string
            guard receiverName != nil else { throw NativeFailure(code: "INVALID_DATA", message: "") }
            receipts = received.array ?? []; reviewed = payment
        }
    }
}
