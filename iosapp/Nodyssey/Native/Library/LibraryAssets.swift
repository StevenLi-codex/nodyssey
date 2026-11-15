import SwiftUI
import NodysseyNativeCore

struct LibraryAssetsScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var growth = NativeStore()
    @StateObject private var attendance = NativeStore()
    @StateObject private var board = NativeStore()
    @StateObject private var action = LibraryAction()
    @State private var confirm = false
    @State private var boardPage: Int64 = 1
    @State private var showBoard = false
    var body: some View {
        List {
            LibraryStoreStatus(store: growth) { action.run { await growth.load(app, "assets.growth") } }
            LibraryActionStatus(action: action)
            LibraryGrowth(value: growth.value, balances: false)
            Section {
                Button { app.open("Credit") } label: { LibraryField(label: "chickenCount", value: growth.value["chickenCount"]) }
                Button { app.open("Stardust") } label: { LibraryField(label: "starCount", value: growth.value["starCount"]) }
            }
            Section(libraryL("attendance")) {
                LibraryStoreStatus(store: attendance)
                LibraryField(label: "date", value: attendance.value["date"])
                LibraryField(label: "signed", value: attendance.value["hasSignedIn"])
                LibraryField(label: "gain", value: attendance.value["gain"])
                Button(libraryL("sign")) {
                    if app.isSignedIn { confirm = true } else { app.showSignIn() }
                }.disabled(action.busy || attendance.value == .null || attendance.value["hasSignedIn"]?.bool == true)
            }
            Button(libraryL("attendanceBoard")) { showBoard = true }
        }
        .sheet(isPresented: $showBoard) {
            NavigationStack { List {
            Section(libraryL("attendanceBoard")) {
                LibraryStoreStatus(store: board) { action.run { await loadBoard() } }
                ForEach(Array((board.value.array ?? []).enumerated()), id: \.offset) { _, row in
                    HStack {
                        if let uid = row["uid"]?.int, uid > 0 {
                            Button(row["name"]?.string ?? String(uid)) { showBoard = false; app.open("UserSpace", ["uid": .integer(uid)]) }
                        } else { Text(row["name"]?.string ?? libraryL("unknown")) }
                        Spacer()
                        Text(libraryScalar(row["gain"]))
                        if let time = row["timeText"]?.string { Text(time).font(.caption) }
                    }
                }
                LibraryPageControls(page: boardPage, total: nil, hasNext: !(board.value.array ?? []).isEmpty, busy: board.isLoading) { boardPage = $0 }
            }
            }.navigationTitle(libraryL("attendanceBoard"))
                .toolbar { Button(libraryL("done")) { showBoard = false } }
                .task(id: "\(app.generation)-\(boardPage)") { await loadBoard() }
            }
        }
        .navigationTitle(libraryL("assets"))
        .task(id: app.generation) {
            await growth.load(app, "assets.growth")
            await libraryRead(attendance, app, "attendance.status")
        }
        .task(id: app.generation) { await attendance.observe(app, "attendance.status") }
        .refreshable { await growth.load(app, "assets.growth"); await libraryRead(attendance, app, "attendance.status"); if showBoard { await loadBoard() } }
        .confirmationDialog(libraryL("signConfirm"), isPresented: $confirm, titleVisibility: .visible) {
            ForEach(["FIXED_FIVE", "RANDOM"], id: \.self) { selectedMode in
            Button(libraryL(selectedMode == "FIXED_FIVE" ? "fixedFive" : "random")) {
                action.run {
                    let result = try await LibraryOperations.signAttendance(mode: selectedMode, request: app.request)
                    if result.acknowledged { action.notice = result.result["message"]?.string ?? libraryL("acknowledged") }
                    action.failure = result.writeFailure ?? result.refreshFailure
                    if result.status != .null { attendance.value = result.status }
                    if result.growth != .null { growth.value = result.growth }
                    if showBoard { await loadBoard() }
                }
            }
            }
        }
        .onDisappear { action.cancel() }
    }
    private func loadBoard() async { await board.load(app, "attendance.board", ["page": .integer(boardPage)]) }
}

struct LibraryGrowth: View {
    let value: JSONValue
    var balances = true
    var body: some View {
        if value != .null {
            Section(libraryL("growth")) {
                ForEach(balances ? ["level", "chickenCount", "starCount"] : ["level"], id: \.self) { key in LibraryField(label: key, value: value[key]) }
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
    @State private var attempt = 0
    var body: some View {
        List {
            LibraryStoreStatus(store: store) { attempt += 1 }
            LibraryStoreStatus(store: growth) { attempt += 1 }
            LibraryField(label: stardust ? "starCount" : "chickenCount", value: growth.value[stardust ? "starCount" : "chickenCount"])
            if !stardust { LibraryField(label: "level", value: growth.value["level"]) }
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
        .task(id: "\(app.generation)-\(page)-\(before.map(String.init) ?? "first")-\(attempt)") { await load() }
        .task(id: "\(app.generation)-\(attempt)") { await growth.load(app, "assets.growth") }
        .refreshable { await load(); await growth.load(app, "assets.growth") }
    }
    // The endpoint has no type filter; page-local filtering would hide unloaded matches.
    private var rows: [JSONValue] { store.value["items"]?.array ?? [] }
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
    private var signedChange: String {
        guard let amount = row[stardust ? "diff" : "change"]?.int else { return libraryL("unknown") }
        return amount > 0 ? "+\(amount)" : String(amount)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(stardust ? libraryL("ledger." + (row["type"]?.string ?? "OTHER")) : (row["reason"]?.string ?? libraryL("unknown")))
                Spacer()
                Text(signedChange).monospacedDigit()
            }
            LibraryField(label: "balanceAfter", value: row["balanceAfter"])
            if let peer = row["peerUid"]?.int, peer > 0 { Button("\(libraryL("member")) #\(peer)") { app.open("UserSpace", ["uid": .integer(peer)]) } }
            if let date = row["createdAtMillis"]?.int { Text(Date(timeIntervalSince1970: Double(date) / 1000), style: .date).font(.caption) }
            if let raw = row["rawType"]?.string { Text(raw).font(.caption) }
        }
    }
}

struct LibraryStardustScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.nativeDestinationID) private var destinationID
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
    @State private var balance: Int64?
    @State private var receiptSummary: LibraryReceiptSummary?
    private var receipts: [JSONValue] { receiptSummary?.mine ?? [] }
    @State private var confirm = false
    // Owned by the destination, never by the presented form.
    @StateObject private var recovery = LibraryPaymentRecovery()
    private var needsReadback: Bool { recovery.needsReadback }
    @State private var initializedGeneration: Int?
    @State private var departureToken: UUID?
    @State private var marker: String?
    @State private var ledger: JSONValue = .null
    @State private var transferOpen = false
    @State private var ledgerRevision = 0
    var body: some View {
        LibraryLedgerScreen(stardust: true)
            .id(ledgerRevision)
            .safeAreaInset(edge: .bottom) {
                if needsReadback {
                    VStack {
                        Text(libraryL("readbackRequired")).font(.footnote)
                        Button(libraryL("reviewPayment")) { transferOpen = true }
                    }.padding().background(.regularMaterial)
                }
            }
            .toolbar { Button(libraryL("transfer")) { transferOpen = true } }
            .sheet(isPresented: $transferOpen, onDismiss: { ledgerRevision += 1 }) {
                NavigationStack {
                    paymentForm
                        .toolbar { Button(libraryL("done")) {
                            guard recovery.canDismiss(isBusy: action.busy) else { return }
                            transferOpen = false
                        }.disabled(!recovery.canDismiss(isBusy: action.busy)) }
                }
                .interactiveDismissDisabled(!recovery.canDismiss(isBusy: action.busy))
            }
            .task(id: app.generation) {
                if departureToken == nil, let destinationID {
                    departureToken = app.registerDismissal(destinationID: destinationID, close: {
                        recovery.canLeaveRoute(isBusy: action.busy)
                    }, revoke: { action.cancel(); recovery.reset() }, validate: {
                        recovery.canLeaveRoute(isBusy: action.busy)
                    })
                }
                // A sheet close or temporary push must not erase an uncertain write.
                guard initializedGeneration != app.generation else { return }
                initializedGeneration = app.generation
                reviewed = nil; receiptSummary = nil; ledger = .null; marker = nil; ownUID = nil; balance = nil; recovery.reset(); confirm = false
                recipient = (arguments["memberId"]?.int ?? arguments["recipientUid"]?.int).map(String.init) ?? ""
                amount = arguments["amount"]?.int.map(String.init) ?? ""
                refId = arguments["refId"]?.int.map(String.init) ?? "0"
                onetime = arguments["onetime"]?.bool ?? false
                description = arguments["description"]?.string ?? ""
                transferOpen = !arguments.isEmpty
                await growth.load(app, "assets.growth")
            }
            .onDisappear { action.cancel() }
    }
    private var paymentForm: some View {
        Form {
            LibraryActionStatus(action: action)
            LibraryStoreStatus(store: growth)
            LibraryField(label: "starCount", value: growth.value["starCount"])
            Section(libraryL("transfer")) {
                Group {
                    TextField(libraryL("recipient"), text: $recipient)
                    TextField(libraryL("amount"), text: $amount)
                    TextField(libraryL("reference"), text: $refId)
                    Toggle(libraryL("onetime"), isOn: $onetime)
                }.disabled(arguments["memberId"] != nil || action.busy || needsReadback)
                if !description.isEmpty { Text(description).font(.footnote) }
                Button(libraryL("reviewPayment")) { review() }.disabled(action.busy)
                if let review = reviewed {
                    LibraryField(label: "receiver", value: receiverName.map(JSONValue.string))
                    Text("#\(review.recipient) · \(review.amount) \(libraryL("stardust"))")
                    if ownUID == review.recipient { Text(libraryL("selfPayment")) }
                    if review.onetime && !receipts.isEmpty { Text(libraryL("alreadyPaid")) }
                    LibraryField(label: "starCount", value: balance.map(JSONValue.integer))
                    if let shortfall = review.shortfall(balance: balance) {
                        LibraryField(label: "shortfall", value: .integer(shortfall))
                    }
                    Button(libraryL("pay")) {
                        guard review.shortfall(balance: balance) == nil, recovery.canPay(review) else { return }
                        confirm = true
                    }
                        .disabled(action.busy || ownUID == nil || ownUID == review.recipient || (review.onetime && !receipts.isEmpty) || !recovery.canPay(review) || review.shortfall(balance: balance) != nil)
                }
                if needsReadback { Text(libraryL("readbackRequired")).font(.footnote) }
            }
            if let summary = receiptSummary {
                Section(libraryL("receiveTally")) {
                    LibraryField(label: "payerCount", value: .integer(Int64(summary.payerCount)))
                    LibraryField(label: "receivedTotal", value: .integer(summary.received))
                    LibraryField(label: "paidByMe", value: .bool(summary.paidByMe))
                }
            }
            if let rows = receiptSummary?.all, !rows.isEmpty {
                Section(libraryL("receipts")) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in LibraryLedgerRow(row: row, stardust: true) }
                }
            }
            if let rows = ledger["items"]?.array {
                Section(libraryL("ledger")) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in LibraryLedgerRow(row: row, stardust: true) }
                }
            }
            if arguments["memberId"] == nil {
            DisclosureGroup(libraryL("receiveCode")) {
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
        .onChange(of: recipient) { _ in invalidateReview() }
        .onChange(of: amount) { _ in invalidateReview() }
        .onChange(of: refId) { _ in invalidateReview() }
        .onChange(of: onetime) { _ in invalidateReview() }
        .confirmationDialog(libraryL("payConfirm"), isPresented: $confirm, titleVisibility: .visible) {
            if let payment = reviewed {
                Button("\(libraryL("pay")) \(payment.amount) → \(receiverName ?? String(payment.recipient))") {
                    guard payment.shortfall(balance: balance) == nil, recovery.canPay(payment) else { return }
                    action.run {
                        let result = try await recovery.pay(payment, request: app.request)
                        if let failure = result.preflightFailure { throw failure }
                        reviewed = nil
                        ledger = result.ledger
                        if result.growth != .null { growth.value = result.growth; balance = result.growth["starCount"]?.int }

                        action.notice = libraryL(result.acknowledged ? "acknowledged" : "uncertainPayment")
                        action.failure = result.writeFailure ?? result.refreshFailure
                        if let ownUID {
                            receiptSummary = nil
                            receiptSummary = try await LibraryOperations.receipts(for: payment, ownUID: ownUID, request: app.request)
                            if result.refreshFailure == nil {
                                recovery.reconcile(payment, authoritativePaid: recovery.acknowledged)
                            }
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
    private func invalidateReview() { reviewed = nil; receiptSummary = nil; receiverName = nil; balance = nil; confirm = false }
    private func review() {
        guard app.isSignedIn else { app.showSignIn(); return }
        action.run {
            let payment: LibraryPayment
            if needsReadback, let frozen = recovery.frozenPayment { payment = frozen }
            else { payment = try draftPayment() }
            invalidateReview()
            let selfProfile = try await app.request("profile.self", ["refresh": .bool(true)])
            guard let uid = selfProfile["uid"]?.int else { throw NativeFailure(code: "INVALID_DATA", message: "") }
            let receiver = try await app.request("assets.recipient", ["recipientUid": .integer(payment.recipient)])
            let received = try await LibraryOperations.receipts(for: payment, ownUID: uid, request: app.request)
            var refreshedBalance = selfProfile["starCount"]?.int
            if needsReadback {
                ledger = try await app.request("assets.stardust")
                growth.value = try await LibraryOperations.refreshedGrowth(request: app.request)
                refreshedBalance = growth.value["starCount"]?.int
                // Read success/empty receipts do not prove a timed-out transfer failed.
                recovery.reconcile(payment, authoritativePaid: recovery.acknowledged || (payment.onetime && received.paidByMe))
            }
            // Do not confirm an old draft if the user edits while lookups are in flight.
            let current = try draftPayment()
            guard current == payment else { return }
            ownUID = uid; receiverName = receiver["name"]?.string
            guard receiverName != nil else { throw NativeFailure(code: "INVALID_DATA", message: "") }
            balance = refreshedBalance
            receiptSummary = received; reviewed = payment
        }
    }
}
