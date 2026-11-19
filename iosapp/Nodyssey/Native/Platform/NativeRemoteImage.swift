import SwiftUI
import UIKit
import Photos
import ImageIO
import NodysseyShell

extension NativeAppModel {
    var nativeImageScope: NativeImageScope {
        NativeImageScope(appIdentity: ObjectIdentifier(self),
            identityEpoch: session.nativeString("identityEpoch"),
            boundaryEpoch: privateBoundary.nativeString("identityEpoch"),
            boundaryPhase: privateBoundary.nativeString("phase"), generation: generation,
            site: site.nativeString("current"), siteOrigin: siteOrigin,
            wifiOnly: settings["imagesOnWifiOnly"]?.bool)
    }
}

/// Uses the installed Kotlin image loader (authenticated headers, proxy, cache, SVG workers).
struct NativeRemoteImage: View {
    let url: String
    var aspectFit: Bool = true
    /// Optional pixel target for fixed-size consumers; default uses the display's pixel extent.
    var maxPixel: Int? = nil
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.displayScale) private var displayScale
    @StateObject private var state = NativeImageState()
    @State private var viewing = false
    private var scope: NativeImageScope { app.nativeImageScope }
    private var targetPixel: Int {
        maxPixel ?? Int((max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * displayScale).rounded(.up))
    }

    var body: some View {
        Group {
            if state.url == url, state.scope == scope, let image = state.image {
                NativeImageDisplay(image: image, aspectFit: aspectFit)
                    .aspectRatio(state.aspectRatio ?? (image.size.width / max(image.size.height, 1)), contentMode: aspectFit ? .fit : .fill)
                    .clipped()
                    .onTapGesture { viewing = true }
                    .accessibilityLabel("Image")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { viewing = true }
            } else if state.url == url, state.scope == scope, state.failure {
                Button { state.load(url, allowMetered: state.deferredForWifi, scope: scope, maxPixel: targetPixel) } label: {
                    Label(state.deferredForWifi ? "Load using mobile data" : "Retry image", systemImage: "arrow.clockwise")
                }.buttonStyle(.plain)
            } else {
                ProgressView().accessibilityLabel("Loading image")
            }
        }
        .onAppear { state.load(url, scope: scope, maxPixel: targetPixel) }
        .onChange(of: url) { value in viewing = false; state.load(value, scope: scope, maxPixel: targetPixel) }
        .onChange(of: scope) { value in viewing = false; state.load(url, scope: value, maxPixel: targetPixel) }
        .onChange(of: targetPixel) { value in state.load(url, scope: scope, maxPixel: value) }
        .onDisappear { state.cancel() }
        .fullScreenCover(isPresented: $viewing) { NativeImageViewer(url: url) }
    }
}

/// A gallery destination keeps URL identity stable while paging and zooming.
struct NativeImageGallery: View {
    let urls: [String]
    @State private var index: Int
    @Environment(\.dismiss) private var dismiss

    init(urls: [String], initialIndex: Int = 0) {
        self.urls = urls
        _index = State(initialValue: urls.indices.contains(initialIndex) ? initialIndex : 0)
    }
    var body: some View {
        if urls.isEmpty {
            VStack {
                Text("No images")
                Button("Close") { dismiss() }
            }
        } else {
            TabView(selection: $index) {
                ForEach(Array(urls.enumerated()), id: \.offset) { offset, url in
                    NativeImageViewer(url: url).tag(offset)
                }
            }.tabViewStyle(.page(indexDisplayMode: .automatic))
        }
    }
}

struct NativeImageViewer: View {
    let url: String
    @EnvironmentObject private var app: NativeAppModel
    private var scope: NativeImageScope { app.nativeImageScope }
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = NativeImageState()
    @State private var sharing = false
    @State private var browsing = false
    @State private var saving = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if state.url == url, state.scope == scope, let image = state.image {
                    NativeZoomImage(image: image, onDismiss: { dismiss() })
                } else if state.scope == scope, state.failure {
                    Button(state.deferredForWifi ? "Load using mobile data" : "Retry image") {
                        state.load(url, allowMetered: state.deferredForWifi, scope: scope)
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { browsing = true } label: { Label("Open in browser", systemImage: "safari") }
                        .disabled(!NativePlatform.shared.isExternalBrowserUrl(url: url) || saving)
                    Button { sharing = true } label: { Label("Share", systemImage: "square.and.arrow.up") }
                        .disabled(state.scope != scope || state.image == nil || saving)
                    Button { save() } label: {
                        if saving { ProgressView() } else { Label("Save image", systemImage: "square.and.arrow.down") }
                    }.disabled(state.scope != scope || state.data == nil || saving)
                }
            }
            .sheet(isPresented: $sharing) {
                if state.scope == scope, let image = state.image { NativeShare(items: [image]) }
            }
            .sheet(isPresented: $browsing) {
                if let target = URL(string: url) { NativeExternalBrowser(url: target) }
            }
            .alert("Image", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) { message = nil }
            } message: { Text(message ?? "") }
        }
        .onAppear { state.load(url, scope: scope) }
        .onChange(of: url) { value in sharing = false; browsing = false; state.load(value, scope: scope) }
        .onChange(of: scope) { value in
            sharing = false; browsing = false
            state.load(url, scope: value)
        }
        .onDisappear { state.cancel() }
    }

    private func save() {
        guard !saving, state.scope == scope, let data = state.data, state.url == url else { return }
        let acceptedScope = scope
        saving = true
        Task { @MainActor in
            defer { saving = false }
            // Called only by the explicit Save button. Never requests read-library permission.
            let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard app.nativeImageScope == acceptedScope else { return }
            guard permission == .authorized || permission == .limited else {
                message = "Photo access was denied. You can allow adding photos in Settings."
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                }
                message = "Image saved."
            } catch {
                message = "The image could not be saved."
            }
        }
    }
}

private struct NativeImageDisplay: UIViewRepresentable {
    let image: UIImage
    let aspectFit: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }
    func updateUIView(_ view: UIImageView, context: Context) {
        view.contentMode = aspectFit ? .scaleAspectFit : .scaleAspectFill
        view.clipsToBounds = true
        NativeImagePlayback.update(view, image: image, reduceMotion: reduceMotion)
    }
}

// Geometry/admission logic is platform-free so the actual UI policy can run on the Mac test host.
enum NativeImageGesturePolicy {
    static func isZoomed(_ scale: CGFloat, minimum: CGFloat) -> Bool { scale > minimum + 0.01 }

    static func shouldDismiss(translationY: CGFloat, scale: CGFloat, minimum: CGFloat) -> Bool {
        !isZoomed(scale, minimum: minimum) && abs(translationY) > 120
    }

    static func zoomRect(tap: CGPoint, viewport: CGSize, scale: CGFloat) -> CGRect {
        let size = CGSize(width: viewport.width / scale, height: viewport.height / scale)
        let origin = CGPoint(x: tap.x - size.width / CGFloat(2), y: tap.y - size.height / CGFloat(2))
        return CGRect(origin: origin, size: size)
    }

    static func canBeginDismiss(scale: CGFloat, minimum: CGFloat, velocity: CGPoint,
                                locationX: CGFloat, width: CGFloat, touches: Int) -> Bool {
        !isZoomed(scale, minimum: minimum) && touches == 1 &&
            abs(velocity.y) > abs(velocity.x) * 1.2 &&
            locationX > 24 && locationX < width - 24
    }
}

private struct NativeZoomImage: UIViewRepresentable {
    let image: UIImage
    var onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = ViewerScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.bouncesZoom = true
        let imageView = context.coordinator.imageView
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "Image. Pinch to zoom."
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        let drag = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.drag(_:)))
        drag.maximumNumberOfTouches = 1
        drag.delegate = context.coordinator
        scroll.addGestureRecognizer(drag)
        scroll.dismissPan = drag
        scroll.panGestureRecognizer.require(toFail: drag)
        return scroll
    }
    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.onDismiss = onDismiss
        context.coordinator.reduceMotion = reduceMotion
        if context.coordinator.sourceImage !== image {
            scroll.transform = .identity
            scroll.setZoomScale(1, animated: false)
            context.coordinator.sourceImage = image
        }
        NativeImagePlayback.update(context.coordinator.imageView, image: image, reduceMotion: reduceMotion)
    }
    // UIScrollView owns pinch/pan. SwiftUI's page TabView offers no per-page gesture arbitration
    // on iOS 16; fail dependencies let its ancestor pager win only when our zoom pan fails.
    // Never replace a system gesture delegate or disable a navigation edge-back recognizer.
    final class ViewerScrollView: UIScrollView {
        weak var dismissPan: UIPanGestureRecognizer?
        override func layoutSubviews() {
            super.layoutSubviews()
            var ancestor = superview
            while let view = ancestor {
                if let pager = view as? UIScrollView {
                    pager.panGestureRecognizer.require(toFail: panGestureRecognizer)
                    if let dismissPan { pager.panGestureRecognizer.require(toFail: dismissPan) }
                }
                for edge in view.gestureRecognizers ?? [] where edge is UIScreenEdgePanGestureRecognizer {
                    panGestureRecognizer.require(toFail: edge)
                    dismissPan?.require(toFail: edge)
                }
                ancestor = view.superview
            }
        }
        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === panGestureRecognizer,
               !NativeImageGesturePolicy.isZoomed(zoomScale, minimum: minimumZoomScale) { return false }
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        let imageView = UIImageView()
        var sourceImage: UIImage?
        var onDismiss: () -> Void = {}
        var reduceMotion = false
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let scroll = pan.view as? UIScrollView else { return false }
            guard !scroll.isZooming else { return false }
            return NativeImageGesturePolicy.canBeginDismiss(
                scale: scroll.zoomScale, minimum: scroll.minimumZoomScale,
                velocity: pan.velocity(in: scroll), locationX: pan.location(in: scroll).x - scroll.bounds.minX,
                width: scroll.bounds.width, touches: pan.numberOfTouches)
        }

        @objc func doubleTap(_ tap: UITapGestureRecognizer) {
            guard let scroll = tap.view as? UIScrollView, !scroll.isZooming else { return }
            if NativeImageGesturePolicy.isZoomed(scroll.zoomScale, minimum: scroll.minimumZoomScale) {
                scroll.setZoomScale(scroll.minimumZoomScale, animated: !reduceMotion)
            } else {
                // UIScrollView expects this rectangle in the zoomed view's coordinate system.
                let rect = NativeImageGesturePolicy.zoomRect(tap: tap.location(in: imageView),
                    viewport: scroll.bounds.size, scale: min(2.5, scroll.maximumZoomScale))
                scroll.zoom(to: rect, animated: !reduceMotion)
            }
        }

        @objc func drag(_ pan: UIPanGestureRecognizer) {
            guard let scroll = pan.view as? UIScrollView else { return }
            let distance = pan.translation(in: scroll.superview).y
            switch pan.state {
            case .began, .changed:
                // Translation uses the stationary parent; transforming the recognizer's view
                // must not feed its own movement back into the next translation sample.
                if !reduceMotion { scroll.transform = CGAffineTransform(translationX: 0, y: distance) }
            case .ended:
                let shouldDismiss = NativeImageGesturePolicy.shouldDismiss(
                    translationY: distance, scale: scroll.zoomScale, minimum: scroll.minimumZoomScale)
                reset(scroll)
                if shouldDismiss { onDismiss() }
            case .cancelled, .failed:
                reset(scroll)
            default: break
            }
        }

        private func reset(_ scroll: UIScrollView) {
            if reduceMotion { scroll.transform = .identity }
            else { UIView.animate(withDuration: 0.2) { scroll.transform = .identity } }
        }
    }
}
