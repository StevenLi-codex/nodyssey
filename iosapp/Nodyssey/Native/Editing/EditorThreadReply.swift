import SwiftUI
import NodysseyNativeCore
#if canImport(UIKit)
import UIKit
#endif

/// The thread owns the draft. Only auxiliary panels are presented; the input stays
/// mounted in the thread's single bottom inset through blur and preview transitions.
struct EditorThreadReplyPresentation: ViewModifier {
    @ObservedObject var owner: EditorReplyLifetime
    let covered: Bool
    let onPublished: (JSONValue) -> Void
    var onOpen: () -> Void = {}
    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !covered {
                    if let model = owner.model {
                        EditorInlineReply(model: model, owner: owner, onPublished: onPublished)
                    } else {
                        Button(action: onOpen) {
                            HStack {
                                Image(systemName: "square.and.pencil")
                                Text(EL("reply")).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).padding(.horizontal, 22).padding(.vertical, 4)
                            .background(.background)
                    }
                }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: previewVisible, onDismiss: finishPreview) { preview }
            #else
            .sheet(isPresented: previewVisible, onDismiss: finishPreview) { preview }
            #endif
            .onChange(of: covered) { value in
                if value {
                    owner.model?.focus.handoff {}
                    if let model = owner.model { Task { do { try await model.flush() } catch { model.report(error) } } }
                }
            }
    }
    private var previewVisible: Binding<Bool> {
        Binding(get: { owner.previewVisible && !covered }, set: { if !$0 && !covered { finishPreview() } })
    }
    @ViewBuilder private var preview: some View {
        if let model = owner.model { EditorReplyPreview(model: model, close: finishPreview) }
    }
    private func finishPreview() {
        if !covered { owner.previewVisible = false; owner.model?.previewing = false; owner.model?.preview = nil }
    }
}

private struct EditorReplyPreview: View {
    @ObservedObject var model: EditorViewModel
    let close: () -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                if let nodes = model.preview { EditorRichPreview(nodes: nodes).padding() }
                else if let failure = model.failure { NativeFailureView(failure: failure) }
                else { ProgressView().padding() }
            }
            .navigationTitle(EL("preview"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(EL("edit"), action: close).frame(minWidth: 44, minHeight: 44) } }
        }
    }
}

private struct EditorInlineReply: View {
    @EnvironmentObject private var app: NativeAppModel
    @ObservedObject var model: EditorViewModel
    @ObservedObject var owner: EditorReplyLifetime
    let onPublished: (JSONValue) -> Void
    @State private var panel: EditorPanel?
    @State private var photos = false
    @State private var emoji = false
    @State private var tools = false
    @State private var expanded = false
    private var session: EditorSession { model.session }
    private var canPublish: Bool {
        model.ready && !session.busy && !session.accepted && session.pendingRestore == nil && model.attachments.isEmpty && !session.body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if session.replyContext["replyToFloor"]?.int != nil {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("@" + (session.replyContext["replyToAuthor"]?.string ?? "")).font(.caption.weight(.medium))
                        Text(session.replyContext["replyToText"]?.string ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.clearReplyTarget() } label: { Image(systemName: "xmark.circle").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel(EL("removeQuote"))
                }.padding(.horizontal, 16)
            }
            if session.pendingRestore != nil {
                HStack {
                    Text(EL("draftFound")).font(.caption)
                    Button(EL("restore")) { model.focus.handoff { if let draft = session.pendingRestore { session.restore(draft) } } }
                    Button(EL("keepCurrent")) { model.focus.handoff { session.keepCurrent() } }
                }.frame(minHeight: 44).padding(.horizontal, 16)
            }
            if !model.ready {
                if let failure = model.failure {
                    NativeFailureView(failure: failure, retry: {
                        if case .reply(let postID) = session.mode { Task { await owner.open(postID: postID, transport: app.transport, generation: app.generation) } }
                    })
                } else { ProgressView() }
            }
            HStack(alignment: .bottom, spacing: 0) {
                Menu {
                    Button(EL("IMAGE")) { model.focus.handoff { emoji = false; photos = true } }
                    Button(EL("preview")) { model.focus.handoff { owner.previewVisible = true; Task { await model.showPreview() } } }
                        .disabled(!model.ready || session.busy)
                    Button(EL(expanded ? "collapse" : "expand")) { expanded.toggle() }
                    Button(EL("toolbar")) { tools.toggle() }
                    Button(EL("close")) { close() }
                } label: { Image(systemName: "plus.circle").frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel(EL("IMAGE"))
                Button { model.focus.handoff { emoji.toggle() } } label: { Image(systemName: "face.smiling").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel(EL("EMOJI"))
                MarkedTextEditor(buffer: Binding(get: { session.body }, set: session.changeBody), focus: model.focus,
                                 accessibilityLabel: EL("body"), autofocus: model.ready && owner.initialFocusAllowed,
                                 maximumVisibleLines: expanded ? 8 : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .simultaneousGesture(TapGesture().onEnded { emoji = false; owner.visible = true })
                Button {
                    model.focus.handoff { Task { if let result = await owner.publish() { onPublished(result) } } }
                } label: { Image(systemName: "arrow.up.circle.fill").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel(EL("publishReply")).disabled(!canPublish)
            }.padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 4)
            if tools {
                EditorToolbar(model: model, onPanel: { selected in
                    model.focus.handoff {
                        if selected == .stickers { emoji.toggle() }
                        else { emoji = false; panel = selected }
                    }
                }, onPhotos: { model.focus.handoff { emoji = false; photos = true } }, compact: true)
            }
            attachments
            if let failure = model.failure, model.ready { NativeFailureView(failure: failure) }
        }
        .background(.background)
        .disabled(owner.closing || app.departureRunning || session.busy)
        .sheet(item: $panel) { panel in NavigationStack { EditorPanelView(panel: panel, model: model) } }
        .sheet(isPresented: $photos) { EditorPhotoPicker(model: model) }
        .sheet(isPresented: $emoji) { NavigationStack { EditorPanelView(panel: .stickers, model: model, embedded: true) } }
        .onDisappear { model.focus.handoff {} }
    }
    private func close() {
        if emoji { emoji = false; return }
        model.focus.handoff { Task { await owner.hide() } }
    }
    @ViewBuilder private var attachments: some View {
        if !model.attachments.isEmpty {
            ScrollView(.horizontal) {
                HStack {
                    ForEach(model.attachments) { item in
                        VStack(alignment: .leading) {
                            Text(item.name).font(.caption).lineLimit(1)
                            if item.phase == .uploading { ProgressView() }
                            if item.phase == .waiting || item.phase == .failed {
                                Button(EL(item.phase == .failed ? "retryUpload" : "upload")) { model.upload(item.id) }
                            }
                            if let markdown = item.markdown { Button(EL("insert")) { model.insert(markdown); model.removeAttachment(item.id) } }
                            Button(EL("remove"), role: .destructive) { model.removeAttachment(item.id) }
                        }.frame(maxWidth: 180).buttonStyle(.bordered)
                    }
                }
            }
        }
    }
}
