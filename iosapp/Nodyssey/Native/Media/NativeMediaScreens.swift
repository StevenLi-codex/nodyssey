import SwiftUI
import NodysseyNativeCore

@MainActor enum NativeMediaScreens {
    static func make(destination: NativeDestination) -> AnyView? {
        let args = destination.arguments
        switch destination.route {
        case "ImageHost": return AnyView(NativeImageHostScreen())
        case "StickerManage": return AnyView(NativeStickerManageScreen())
        case "StickerGroup":
            guard let key = args["key"]?.string else { return invalid() }
            return AnyView(NativeStickerGroupScreen(key: key))
        case "StickerSources": return AnyView(NativeStickerSourcesScreen())
        case "StickerAdd": return AnyView(NativeStickerAddScreen(tab: args["tab"]?.string ?? "LINK", source: args["source"]?.string))
        case "ImageViewer":
            guard let values = args["urls"]?.array, !values.isEmpty, values.allSatisfy({ $0.string != nil }) else { return invalid() }
            let urls = values.compactMap(\.string)
            let index = args["index"]?.int ?? 0
            guard index >= 0, index < Int64(urls.count) else { return invalid() }
            return AnyView(NativeImageGallery(urls: urls, initialIndex: Int(index), destinationID: destination.id))
        case "Web":
            guard let url = args["url"]?.string else { return invalid() }
            let goal: NativeBrowserGoal
            switch args["goal"]?.string ?? "SIGN_IN" {
            case "SIGN_IN": goal = .login
            case "ONE_TAP_SIGN_IN": goal = .oneTapLogin
            case "CHALLENGE": goal = .challenge
            case "MANAGE": goal = .manage
            case "TELEGRAM_BIND": goal = .telegramBind
            default: return invalid()
            }
            return AnyView(NativeBrowser(url: url, title: args["title"]?.string ?? MediaL.text("browser"), goal: goal))
        default: return nil
        }
    }
    private static func invalid() -> AnyView {
        AnyView(NativeFailureView(failure: NativeFailure(code: "INVALID_ARGUMENT", message: "Invalid media destination.")))
    }
}

struct NativeImageHostScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var capabilities = NativeStore()
    @StateObject private var current = NativeStore()
    @State private var provider: String?
    @State private var retry = 0
    private var providers: [MediaRows] { MediaRows.from(capabilities.value["imageHosts"]?.array ?? [], key: "provider") }
    var body: some View {
        VStack(spacing: 0) {
            if let failure = capabilities.failure { NativeFailureView(failure: failure, retry: { retry += 1 }) }
            if let failure = current.failure { NativeFailureView(failure: failure, retry: { retry += 1 }) }
            if providers.isEmpty && capabilities.failure == nil { ProgressView() }
            else {
                let active = current.value["provider"]?.string
                HStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.title3).foregroundStyle(.tint)
                        .frame(width: 38, height: 38)
                        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(active.map { MediaL.text($0) } ?? MediaL.text("hosts"))
                            .font(.headline)
                        Text(active == nil ? MediaL.text("notConfigured") : MediaL.text("selected"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 6)

                Picker(MediaL.text("provider"), selection: Binding(get: { provider ?? active ?? "" }, set: { provider = $0 })) {
                    ForEach(providers) { row in Text(MediaL.text(row.id)).tag(row.id) }
                }.pickerStyle(.menu).padding(.horizontal)
                if let selected = provider ?? active,
                   let capability = providers.first(where: { $0.id == selected }) {
                    MediaHostConfiguration(provider: selected, capability: capability.value,
                                           selected: active == selected).id(selected)
                }
            }
        }
        .navigationTitle(MediaL.text("hosts"))
        .task(id: "\(app.generation)-\(retry)") { await capabilities.load(app, "settings.capabilities") }
        .task(id: "\(app.generation)-\(retry)") { await current.observe(app, "imageHost.observe") }
    }
}

private struct MediaHostConfiguration: View {
    let provider: String
    let capability: JSONValue
    let selected: Bool
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var store = NativeStore()
    @StateObject private var action = MediaAction()
    @State private var draft: MediaHostDraft?
    @State private var showDisconnect = false
    @State private var clearConfirmation = false
    @State private var showGallery = false
    @State private var retry = 0

    var body: some View {
        Form {
            if let failure = store.failure { NativeFailureView(failure: failure, retry: { retry += 1 }) }
            if store.isLoading { ProgressView() }
            if draft != nil {
                Section(MediaL.text("configuration")) {
                    if capability["needsSiteUrl"]?.bool == true {
                        TextField(MediaL.text("endpoint"), text: field(\.siteURL)).textContentType(.URL)
                    }
                    MediaSecretField(title: "token", saved: store.value["hasToken"]?.bool == true, edit: secret(\.token))
                    if provider == "CUSTOM" {
                        TextField(MediaL.text("fileField"), text: field(\.fileField))
                        TextField(MediaL.text("headerName"), text: field(\.headerName))
                        MediaSecretField(title: "headerValue", saved: store.value["custom"]?["hasHeaderValue"]?.bool == true, edit: secret(\.headerValue))
                        MediaSecretField(title: "formFields", saved: store.value["custom"]?["hasFormFields"]?.bool == true, edit: secret(\.formFields))
                        Text(MediaL.text("formFieldsHelp")).font(.caption).foregroundStyle(.secondary)
                        TextField(MediaL.text("urlPath"), text: field(\.urlPath))
                        TextField(MediaL.text("urlPrefix"), text: field(\.urlPrefix))
                    }
                    Button {
                        if draft?.token == .clear || draft?.headerValue == .clear || draft?.formFields == .clear { clearConfirmation = true }
                        else { save() }
                    } label: {
                        HStack(spacing: 6) {
                            if action.busy { ProgressView().controlSize(.small) }
                            Text(MediaL.text("save")).frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }.disabled(action.busy)
                Section {
                    Label(MediaL.text(store.value["isConfigured"]?.bool == true ? "configured" : "notConfigured"), systemImage: store.value["isConfigured"]?.bool == true ? "checkmark.shield" : "exclamationmark.shield")
                    if let problem = store.value["problem"]?.string { Text(MediaL.text("problem") + ": " + problem).font(.caption) }
                    Text(MediaL.text("saveNotTest")).font(.caption).foregroundStyle(.secondary)
                    if selected { Label(MediaL.text("selected"), systemImage: "checkmark") }
                    else { Button(MediaL.text("selectHost")) { action.request(app, "imageHost.select", ["provider": .string(provider)], refresh: "imageHost.get") } }
                    if capability["browsable"]?.bool == true {
                        Button(MediaL.text("testBrowse")) { showGallery = true }.disabled(!selected || store.value["isConfigured"]?.bool != true)
                    } else { Text(MediaL.text("uploadOnly")).font(.callout).foregroundStyle(.secondary) }
                    Button(MediaL.text("disconnect"), role: .destructive) { showDisconnect = true }
                }.disabled(action.busy)
            }
            MediaFeedback(action: action)
        }
        .autocorrectionDisabled()
        .task(id: "\(app.generation)-\(retry)") {
            draft = nil
            await store.load(app, "imageHost.get", ["provider": .string(provider)])
            if store.value != .null { draft = MediaHostDraft(provider: provider, snapshot: store.value) }
        }
        .onDisappear { action.cancel(); draft = nil }
        .confirmationDialog(MediaL.text("clearSecrets"), isPresented: $clearConfirmation, titleVisibility: .visible) {
            Button(MediaL.text("save"), role: .destructive) { save() }
        }
        .confirmationDialog(MediaL.text("disconnectConfirm"), isPresented: $showDisconnect, titleVisibility: .visible) {
            Button(MediaL.text("disconnect"), role: .destructive) {
                action.run(app) {
                    _ = try await app.request("imageHost.disconnect", ["provider": .string(provider)])
                    await reload()
                }
            }
        }
        .sheet(isPresented: $showGallery) { NavigationStack { MediaHostGallery(provider: provider) } }
    }

    private func field(_ key: WritableKeyPath<MediaHostDraft, String>) -> Binding<String> {
        Binding(get: { draft?[keyPath: key] ?? "" }, set: { draft?[keyPath: key] = $0 })
    }
    private func secret(_ key: WritableKeyPath<MediaHostDraft, MediaSecretEdit>) -> Binding<MediaSecretEdit> {
        Binding(get: { draft?[keyPath: key] ?? .preserve }, set: { draft?[keyPath: key] = $0 })
    }
    private func save() {
        guard let draft else { return }
        action.run(app) {
            _ = try await app.request("imageHost.save", try draft.arguments())
            await reload()
            if store.failure == nil { action.notice = MediaL.text("saved") }
        }
    }
    private func reload() async {
        await store.load(app, "imageHost.get", ["provider": .string(provider)])
        if store.value != .null { draft = MediaHostDraft(provider: provider, snapshot: store.value) }
    }
}

private struct MediaFormSecretRow: Identifiable, Equatable {
    let id = UUID()
    var name = ""
    var value = ""
}

private struct MediaSecretField: View {
    let title: String
    let saved: Bool
    @Binding var edit: MediaSecretEdit
    @State private var fields: [MediaFormSecretRow] = [.init()]
    private var mode: Binding<String> {
        Binding(get: { switch edit { case .preserve: return "preserve"; case .clear: return "clear"; case .replace: return "replace" } },
                set: { switch $0 { case "clear": edit = .clear; case "replace": edit = .replace(""); default: edit = .preserve } })
    }
    var body: some View {
        Picker(MediaL.text(title), selection: mode) {
            Text(MediaL.text(saved ? "preserveSaved" : "unchanged")).tag("preserve")
            Text(MediaL.text("replace")).tag("replace")
            Text(MediaL.text("clear")).tag("clear")
        }
        .onChange(of: edit) { value in
            if value == .preserve || value == .clear { fields = [.init()] }
        }
        if case .replace(let value) = edit {
            if title == "formFields" {
                ForEach($fields) { $field in
                    HStack {
                        TextField(MediaL.text("fieldName"), text: $field.name)
                        SecureField(MediaL.text("fieldValue"), text: $field.value).privacySensitive()
                        Button(role: .destructive) { fields.removeAll { $0.id == field.id } } label: { Image(systemName: "minus.circle") }
                            .accessibilityLabel(MediaL.text("remove"))
                    }.autocorrectionDisabled()
                }
                Button(MediaL.text("addField")) { fields.append(.init()) }
                    .onChange(of: fields) { rows in
                        edit = .replace(rows.filter { !$0.name.isEmpty }.map { "\($0.name)=\($0.value)" }.joined(separator: "\n"))
                    }
            } else {
                SecureField(MediaL.text(title), text: Binding(get: { value }, set: { edit = .replace($0) }))
                    .privacySensitive().autocorrectionDisabled()
            }
        }
    }
}

struct MediaHostGallery: View {
    let provider: String
    var onChoose: (([MediaHostedImage]) -> Void)?
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var action = MediaAction()
    @State private var service: MediaHostService?
    @State private var images: [MediaHostedImage] = []
    @State private var selection: Set<String> = []
    @State private var gifOnly = false
    @State private var confirmation: MediaHostService.Confirmation?
    @State private var confirmDelete = false
    @State private var viewer: MediaImagePresentation?
    @Environment(\.dynamicTypeSize) private var typeSize
    private var visibleImages: [MediaHostedImage] { images.filter { !gifOnly || $0.isGIF } }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                MediaFeedback(action: action)
                Toggle(MediaL.text("gifOnly"), isOn: $gifOnly)
                if onChoose != nil { Text(MediaL.text("selectionCount") + ": \(selection.count)").font(.headline) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 160 : 100), spacing: 12)], spacing: 16) {
                    ForEach(visibleImages) { image in
                        VStack(spacing: 6) {
                            Button { open(image) } label: {
                                Color.secondary.opacity(0.08).aspectRatio(1, contentMode: .fit)
                                    .overlay { NativeRemoteImage(url: image.url, aspectFit: true).padding(4).allowsHitTesting(false) }
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain).accessibilityLabel(MediaL.text("view") + ": " + image.name)
                            Text(image.name).font(.caption).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                            if onChoose != nil {
                                Button { if !selection.insert(image.id).inserted { selection.remove(image.id) } } label: {
                                    Label(MediaL.text("select"), systemImage: selection.contains(image.id) ? "checkmark.circle.fill" : "circle")
                                        .frame(minHeight: 44)
                                }.accessibilityLabel(MediaL.text("select") + ": " + image.name)
                                    .accessibilityAddTraits(selection.contains(image.id) ? .isSelected : [])
                            } else {
                                Menu {
                                    Button(MediaL.text("view")) { open(image) }
                                    ShareLink(item: image.url) { Text(MediaL.text("copyShare")) }
                                    Button(MediaL.text("delete"), role: .destructive) {
                                        do { confirmation = try service?.confirmation(for: image.id); confirmDelete = confirmation != nil }
                                        catch { action.failure = error as? NativeFailure }
                                    }
                                } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                                .accessibilityLabel(image.name)
                            }
                        }
                    }
                }.disabled(action.busy)
                if visibleImages.isEmpty && !action.busy && action.failure == nil { Text(MediaL.text(images.isEmpty ? "noImages" : "noMatchingImages")) }
            }.padding()
        }
        .navigationTitle(MediaL.text("uploaded"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(MediaL.text("close")) { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                if let onChoose { Button(MediaL.text("addSelected")) { onChoose(images.filter { selection.contains($0.id) }); dismiss() }.disabled(selection.isEmpty || action.busy) }
                else { Button(MediaL.text("refresh")) { load() }.disabled(action.busy) }
            }
        }
        .task(id: app.generation) { images = []; selection = []; service = MediaHostService(transport: app.transport); load() }
        .onDisappear { action.cancel() }
        #if os(iOS)
        .fullScreenCover(item: $viewer) { value in NativeImageGallery(urls: value.urls, initialIndex: value.index) }
        #else
        .sheet(item: $viewer) { value in NativeImageGallery(urls: value.urls, initialIndex: value.index) }
        #endif
        .confirmationDialog(MediaL.text("deleteRemoteConfirm"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(MediaL.text("delete"), role: .destructive) {
                guard let confirmation, let service else { return }
                action.run(app) { try await service.deleteConfirmed(confirmation); try Task.checkCancellation(); images = service.images }
            }
        }
    }
    private func open(_ image: MediaHostedImage) {
        let visible = visibleImages
        guard let index = visible.firstIndex(where: { $0.id == image.id }) else { return }
        viewer = .init(urls: visible.map(\.url), index: index)
    }
    private func load() {
        guard let service else { return }
        action.run(app) { let result = try await service.list(provider: provider); try Task.checkCancellation(); images = result }
    }
}
