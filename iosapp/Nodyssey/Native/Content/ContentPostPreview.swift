import SwiftUI
import NodysseyNativeCore
#if os(iOS)
import UIKit
#endif

struct ContentPostPreviewItem {
    let postID: Int64
    let summary: JSONValue
    let routeIdentity: JSONValue
    let onCommit: () -> Void
    let onMenuStateChanged: (UUID, Bool) -> Void
}

#if os(iOS)
/// Installed only in the feed card's Button label background, not over the List/window.
/// UIKit's public commit delegate is the sole route-opening path for a preview tap.
struct ContentPostPreviewInteraction: UIViewRepresentable {
    @EnvironmentObject private var app: NativeAppModel
    let item: ContentPostPreviewItem

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        let interaction = UIContextMenuInteraction(delegate: context.coordinator)
        view.addInteraction(interaction)
        context.coordinator.interaction = interaction
        context.coordinator.configure(app: app, item: item)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.configure(app: app, item: item)
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        view.interactions.filter { $0 is UIContextMenuInteraction }.forEach(view.removeInteraction)
        coordinator.cancel()
    }

    @MainActor
    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        private weak var app: NativeAppModel?
        weak var interaction: UIContextMenuInteraction?
        private var rowOwner: ContentPostPreviewOwner?
        private var activeOwner: ContentPostPreviewOwner?
        private var item: ContentPostPreviewItem?
        private var activeMenu: UUID?
        private var committingMenu: UUID?
        private var displayedMenuOwner: UUID?
        private var activeLoader: ContentPostPreviewLoader?
        private var lease = ContentPostPreviewLease()

        func configure(app: NativeAppModel, item: ContentPostPreviewItem) {
            let epoch = app.session.nativeString("identityEpoch")
            let site = app.site.nativeString("current")
            let unchangedRow = rowOwner?.matches(postID: item.postID, generation: app.generation,
                                                 identityEpoch: epoch, site: site) == true &&
                self.app === app && self.item?.summary == item.summary && self.item?.routeIdentity == item.routeIdentity
            if !unchangedRow {
                cancelActive(dismissMenu: true)
                rowOwner = ContentPostPreviewOwner(postID: item.postID, generation: app.generation,
                                                   identityEpoch: epoch, site: site)
            }
            self.app = app
            self.item = item
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            guard let app, let item, let rowOwner, isCurrent(rowOwner, app: app) else { return nil }
            cancelActive()
            let menu = UUID()
            activeMenu = menu
            let sessionOwner = ContentPostPreviewOwner(postID: item.postID, generation: app.generation,
                identityEpoch: app.session.nativeString("identityEpoch"), site: app.site.nativeString("current"))
            activeOwner = sessionOwner
            lease.begin(sessionOwner)
            let loader = ContentPostPreviewLoader()
            activeLoader = loader
            let expectedOwner = sessionOwner
            let expectedItem = item
            return UIContextMenuConfiguration(identifier: sessionOwner.id.uuidString as NSString, previewProvider: { [weak self] in
                guard let self, self.activeMenu == menu, let app = self.app,
                      self.accepts(expectedOwner, app: app), self.item?.postID == expectedItem.postID else { return nil }
                let width = min(max(UIScreen.main.bounds.width - 40, 280), 420)
                let height = min(max(UIScreen.main.bounds.height * 0.62, 260), 520)
                let root = ContentPostPreviewCard(loader: loader, owner: expectedOwner, summary: expectedItem.summary)
                    .environmentObject(app)
                    .frame(width: width, height: height, alignment: .topLeading)
                let controller = UIHostingController(rootView: root)
                controller.view.backgroundColor = .clear
                controller.preferredContentSize = CGSize(width: width, height: height)
                return controller
            }, actionProvider: { _ in nil })
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                    animator: UIContextMenuInteractionAnimating?) {
            guard let activeOwner, configuration.identifier as? String == activeOwner.id.uuidString,
                  displayedMenuOwner != activeOwner.id else { return }
            displayedMenuOwner = activeOwner.id
            item?.onMenuStateChanged(activeOwner.id, true)
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
                                    animator: UIContextMenuInteractionCommitAnimating) {
            guard let app, let item, let owner = activeOwner, let menu = activeMenu,
                  let configuredID = configuration.identifier as? NSString,
                  configuredID as String == owner.id.uuidString,
                  accepts(owner, app: app) else { return }
            let callback = item.onCommit
            committingMenu = menu
            animator.addCompletion { [weak self] in
                Task { @MainActor in
                    guard let self, self.activeMenu == menu, let app = self.app,
                          self.accepts(owner, app: app) else { return }
                    self.cancelActive()
                    callback()
                }
            }
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    willEndFor configuration: UIContextMenuConfiguration,
                                    animator: UIContextMenuInteractionAnimating?) {
            guard let activeOwner, let menu = activeMenu,
                  configuration.identifier as? String == activeOwner.id.uuidString else { return }
            activeLoader?.cancel(activeOwner)
            releaseDisplayedMenu()
            // UIKit may order end/commit callbacks in the same dismissal cycle.
            // Keep only navigation eligibility until that animation completes.
            let finish = { [weak self] in
                guard let self, self.activeMenu == menu, self.committingMenu != menu else { return }
                self.cancelActive()
            }
            if let animator { animator.addCompletion(finish) }
            else { Task { @MainActor in await Task.yield(); finish() } }
        }

        func cancel() {
            cancelActive(dismissMenu: true)
            rowOwner = nil
            item = nil
            app = nil
        }

        private func accepts(_ owner: ContentPostPreviewOwner, app: NativeAppModel) -> Bool {
            isCurrent(owner, app: app) && lease.accepts(owner, postID: item?.postID ?? -1, generation: app.generation,
                          identityEpoch: app.session.nativeString("identityEpoch"),
                          site: app.site.nativeString("current"))
        }

        private func isCurrent(_ owner: ContentPostPreviewOwner, app: NativeAppModel) -> Bool {
            app.selectedTab == .home && app.homePath.isEmpty && app.sheet == nil && !app.departureRunning &&
            owner.matches(postID: item?.postID ?? -1, generation: app.generation,
                          identityEpoch: app.session.nativeString("identityEpoch"),
                          site: app.site.nativeString("current"))
        }

        private func releaseDisplayedMenu() {
            guard let owner = displayedMenuOwner else { return }
            displayedMenuOwner = nil
            item?.onMenuStateChanged(owner, false)
        }

        private func cancelActive(dismissMenu: Bool = false) {
            let wasActive = activeMenu != nil
            releaseDisplayedMenu()
            activeLoader?.cancel(activeOwner)
            if let activeOwner { lease.cancel(activeOwner) }
            activeLoader = nil
            activeOwner = nil
            activeMenu = nil
            committingMenu = nil
            if dismissMenu, wasActive { interaction?.dismissMenu() }
        }
    }
}
#else
struct ContentPostPreviewInteraction: View {
    let item: ContentPostPreviewItem
    var body: some View { Color.clear }
}
#endif

private struct ContentPostPreviewCard: View {
    @EnvironmentObject private var app: NativeAppModel
    @ObservedObject var loader: ContentPostPreviewLoader
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let owner: ContentPostPreviewOwner
    let summary: JSONValue

    private var projection: ContentPostPreviewContent {
        ContentPostPreviewContent(postID: owner.postID, summary: summary, thread: isCurrent ? loader.value : .null)
    }

    private var decodedNodes: Result<[NativeRichNode], Error>? {
        guard projection.hasBody,
              let data = try? JSONEncoder().encode(JSONValue.array(projection.nodes)) else { return nil }
        return Result { try JSONDecoder().decode([NativeRichNode].self, from: data) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    ContentAvatar(value: summary, size: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        if let category = summary.nativeString("categoryTitle"), !category.isEmpty {
                            Text(category).font(.caption.weight(.medium)).foregroundStyle(.tint)
                        }
                        Text(projection.title).font(.title3.weight(.bold))
                            .fixedSize(horizontal: false, vertical: true)
                        if let author = summary.nativeString("authorName"), !author.isEmpty {
                            Text(author).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                if loader.isLoading && loader.value == .null {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 64)
                } else if let failure = loader.failure {
                    NativeFailureView(failure: failure)
                } else if projection.isBlocked {
                    Text(String(localized: "content.revealBlocked", table: "Content"))
                        .font(.subheadline).foregroundStyle(.secondary)
                } else if projection.hasBody {
                    if let decodedNodes {
                        switch decodedNodes {
                        case .success(let nodes):
                            NativeRichTextView(nodes: nodes)
                        case .failure:
                            NativeFailureView(failure: .init(code: "INVALID_DATA", message: "Unable to decode preview content"))
                        }
                    }
                } else {
                    NativeEmptyView(String(localized: "content.noCachedThread", table: "Content"))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task(id: owner.id) {
            guard isCurrent else { loader.cancel(owner); return }
            await loader.load(app, owner: owner)
        }
        .onChange(of: app.generation) { _ in loader.cancel(owner) }
        .onChange(of: app.session.nativeString("identityEpoch")) { _ in loader.cancel(owner) }
        .onChange(of: app.site.nativeString("current")) { _ in loader.cancel(owner) }
        .onDisappear { loader.cancel(owner) }
        // This is an independent host, not a descendant of NativeRootView.
        .modifier(NativeSettingsAppearance(settings: app.settings))
        .environment(\.nativeCardMotionDisabled, app.settings.nativeBool("einkMode") == true)
        .transaction { if reduceMotion || app.settings.nativeBool("einkMode") == true {
            $0.disablesAnimations = true; $0.animation = nil
        } }
    }

    private var isCurrent: Bool {
        owner.matches(postID: owner.postID, generation: app.generation,
                      identityEpoch: app.session.nativeString("identityEpoch"),
                      site: app.site.nativeString("current"))
    }
}
