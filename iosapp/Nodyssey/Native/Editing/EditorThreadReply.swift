import SwiftUI
import NodysseyNativeCore
#if canImport(UIKit)
import UIKit
#endif

/// Sheet presentation does not own the model. Only the registered thread departure
/// can terminate it; a gesture first commits IME input and awaits the existing draft queue.
struct EditorThreadReplyPresentation: ViewModifier {
    @ObservedObject var owner: EditorReplyLifetime
    let covered: Bool
    let onPublished: (JSONValue) -> Void
    @State private var previewPresented = false
    private var sheetVisible: Binding<Bool> {
        Binding(get: { owner.visible && !owner.previewVisible && !covered }, set: { showing in
            if !showing && !covered && !owner.previewVisible { Task { await owner.hide() } }
        })
    }
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: sheetVisible, onDismiss: {
                if owner.visible && owner.previewVisible && !covered { previewPresented = true }
            }) {
                if let model = owner.model {
                    EditorReplySheet(model: model, owner: owner, onPreview: {
                        model.focus.handoff {
                            owner.previewVisible = true
                            Task { await model.showPreview() }
                        }
                    }, onPublished: onPublished)
                }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $previewPresented, onDismiss: finishPreview) { preview }
            #else
            .sheet(isPresented: $previewPresented, onDismiss: finishPreview) { preview }
            #endif
            .onChange(of: covered) { value in
                if value {
                    previewPresented = false
                    owner.model?.focus.handoff {}
                    if let model = owner.model { Task { do { try await model.flush() } catch { model.report(error) } } }
                } else if owner.previewVisible && owner.visible { previewPresented = true }
            }
            .onChange(of: owner.visible) { if !$0 { previewPresented = false } }
    }
    @ViewBuilder private var preview: some View {
        if let model = owner.model {
            EditorReplyPreview(model: model, close: { previewPresented = false })
        }
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
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(EL("edit"), action: close).frame(minHeight: 44) } }
        }
    }
}

private struct EditorReplySheet: View {
    @EnvironmentObject private var app: NativeAppModel
    @ObservedObject var model: EditorViewModel
    @ObservedObject var owner: EditorReplyLifetime
    let onPreview: () -> Void
    let onPublished: (JSONValue) -> Void
    @State private var panel: EditorPanel?
    @State private var photos = false
    @State private var emoji = false
    private var session: EditorSession { model.session }
    private var canPublish: Bool {
        model.ready && !session.busy && !session.accepted && session.pendingRestore == nil && model.attachments.isEmpty && !session.body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(action: close) { Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel(EL("close"))
                Text(EL("reply") + (session.replyContext["replyToFloor"]?.int.map { " #\($0)" } ?? ""))
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onPreview) { Image(systemName: "eye").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel(EL("preview")).disabled(!model.ready || session.busy)
                Button(EL("publishReply")) {
                    model.focus.handoff {
                        Task { if let result = await owner.publish() { onPublished(result) } }
                    }
                }.frame(minHeight: 44).disabled(!canPublish)
            }.padding(.horizontal, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if session.replyContext["replyToFloor"]?.int != nil {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("@" + (session.replyContext["replyToAuthor"]?.string ?? "")).font(.subheadline.weight(.medium))
                                Text(session.replyContext["replyToText"]?.string ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            Button { model.clearReplyTarget() } label: { Image(systemName: "xmark.circle").frame(minWidth: 44, minHeight: 44) }
                                .accessibilityLabel(EL("removeQuote"))
                        }.padding(8).background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if session.pendingRestore != nil {
                        Text(EL("draftFound")).font(.caption)
                        HStack {
                            Button(EL("restore")) { model.focus.handoff { if let draft = session.pendingRestore { session.restore(draft) } } }
                            Button(EL("keepCurrent")) { model.focus.handoff { session.keepCurrent() } }
                        }.frame(minHeight: 44)
                    }
                    if !model.ready {
                        if let failure = model.failure { NativeFailureView(failure: failure, retry: {
                            if case .reply(let postID) = session.mode {
                                Task { await owner.open(postID: postID, transport: app.transport, generation: app.generation) }
                            }
                        }) }
                        else { ProgressView() }
                    }
                    MarkedTextEditor(buffer: Binding(get: { session.body }, set: session.changeBody), focus: model.focus, accessibilityLabel: EL("body"), autofocus: model.ready && owner.initialFocusAllowed)
                        .frame(minHeight: 80, idealHeight: 160, maxHeight: 260)
                        .simultaneousGesture(TapGesture().onEnded { emoji = false })
                    attachments
                    if session.accepted { Text(EL("acceptedDetail")).font(.caption) }
                    if let failure = model.failure, model.ready { NativeFailureView(failure: failure) }
                }.padding(.horizontal, 16)
            }
            Divider()
            EditorToolbar(model: model, onPanel: { selected in
                model.focus.handoff {
                    if selected == .stickers { emoji.toggle() }
                    else { emoji = false; panel = selected }
                }
            }, onPhotos: { model.focus.handoff { emoji = false; photos = true } }, compact: true)
            if emoji {
                EditorPanelView(panel: .stickers, model: model, embedded: true)
                    .frame(height: 200)
            }
        }
        .disabled(owner.closing || app.departureRunning || session.busy)
        .interactiveDismissDisabled(true)
        .background(EditorReplyDismissAttempt(onAttempt: close))
        .presentationDetents([.height(430), .large])
        .presentationDragIndicator(.visible)
        .sheet(item: $panel) { panel in NavigationStack { EditorPanelView(panel: panel, model: model) } }
        .sheet(isPresented: $photos) { EditorPhotoPicker(model: model) }
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

#if canImport(UIKit)
/// SwiftUI has no async shouldDismiss hook. A refused UIKit gesture invokes the
/// same awaited hide action as Close; it never lets UIKit discard an unsaved owner.
private struct EditorReplyDismissAttempt: UIViewControllerRepresentable {
    let onAttempt: () -> Void
    func makeUIViewController(context: Context) -> Controller { Controller(onAttempt: onAttempt) }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.onAttempt = onAttempt; controller.install() }
    final class Controller: UIViewController, UIAdaptivePresentationControllerDelegate {
        var onAttempt: () -> Void
        init(onAttempt: @escaping () -> Void) { self.onAttempt = onAttempt; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError("Not a storyboard controller") }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); install() }
        func install() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var controller: UIViewController? = self.parent
                while let current = controller {
                    if let presentation = current.presentationController { presentation.delegate = self; return }
                    controller = current.parent
                }
            }
        }
        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool { false }
        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) { onAttempt() }
    }
}
#else
private struct EditorReplyDismissAttempt: View { let onAttempt: () -> Void; var body: some View { EmptyView() } }
#endif
