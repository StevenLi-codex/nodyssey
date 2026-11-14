import SwiftUI
import UIKit
import Photos
import ImageIO
import NodysseyShell

@MainActor
final class NativeImageState: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var data: Data?
    @Published private(set) var failure = false
    @Published private(set) var deferredForWifi = false
    private var request: NativeRequest?
    private var decodeTask: Task<Void, Never>?
    private var identity = UUID()
    private(set) var url: String?

    func load(_ url: String, allowMetered: Bool = false) {
        cancel()
        self.url = url
        image = nil
        data = nil
        failure = false
        deferredForWifi = false
        let identity = self.identity
        request = NativePlatform.shared.image(url: url, allowMetered: allowMetered) { [weak self] bytes, error in
            guard let self, self.identity == identity, self.url == url else { return }
            self.request = nil
            guard error == nil, let bytes else {
                self.failure = true
                self.deferredForWifi = error == "IMAGE_WIFI_ONLY"
                return
            }
            let data = bytes as Data
            self.decodeTask = Task { [weak self] in
                let worker = Task.detached(priority: .userInitiated) { NativeImageDecoder.decode(data) }
                let image = await withTaskCancellationHandler(operation: { await worker.value },
                                                              onCancel: { worker.cancel() })
                guard !Task.isCancelled, let self, self.identity == identity, self.url == url else { return }
                self.data = data
                self.image = image
                self.failure = image == nil
            }
        }
    }
    func cancel() {
        identity = UUID()
        request?.cancel()
        request = nil
        decodeTask?.cancel()
        decodeTask = nil
    }
    deinit { request?.cancel(); decodeTask?.cancel() }
}

/// Uses the installed Kotlin image loader (authenticated headers, proxy, cache, SVG workers).
struct NativeRemoteImage: View {
    let url: String
    var aspectFit: Bool = true
    @StateObject private var state = NativeImageState()
    @State private var viewing = false

    var body: some View {
        Group {
            if state.url == url, let image = state.image {
                NativeImageDisplay(image: image, aspectFit: aspectFit)
                    .aspectRatio(image.size.width / max(image.size.height, 1), contentMode: aspectFit ? .fit : .fill)
                    .clipped()
                    .onTapGesture { viewing = true }
                    .accessibilityLabel("Image")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { viewing = true }
            } else if state.url == url, state.failure {
                Button { state.load(url, allowMetered: state.deferredForWifi) } label: {
                    Label(state.deferredForWifi ? "Load using mobile data" : "Retry image", systemImage: "arrow.clockwise")
                }.buttonStyle(.plain)
            } else {
                ProgressView().accessibilityLabel("Loading image")
            }
        }
        .onAppear { state.load(url) }
        .onChange(of: url) { value in viewing = false; state.load(value) }
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
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = NativeImageState()
    @State private var sharing = false
    @State private var browsing = false
    @State private var saving = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if state.url == url, let image = state.image {
                    NativeZoomImage(image: image)
                } else if state.failure {
                    Button(state.deferredForWifi ? "Load using mobile data" : "Retry image") {
                        state.load(url, allowMetered: state.deferredForWifi)
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
                        .disabled(state.image == nil || saving)
                    Button { save() } label: {
                        if saving { ProgressView() } else { Label("Save image", systemImage: "square.and.arrow.down") }
                    }.disabled(state.data == nil || saving)
                }
            }
            .sheet(isPresented: $sharing) {
                if let image = state.image { NativeShare(items: [image]) }
            }
            .sheet(isPresented: $browsing) {
                if let target = URL(string: url) { NativeExternalBrowser(url: target) }
            }
            .alert("Image", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) { message = nil }
            } message: { Text(message ?? "") }
        }
        .onAppear { state.load(url) }
        .onChange(of: url) { value in sharing = false; browsing = false; state.load(value) }
        .onDisappear { state.cancel() }
    }

    private func save() {
        guard !saving, let data = state.data, state.url == url else { return }
        saving = true
        Task { @MainActor in
            defer { saving = false }
            // Called only by the explicit Save button. Never requests read-library permission.
            let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
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

/// ImageIO decoding stays on the worker. SVG rasterization remains in Kotlin's existing pipeline.
private enum NativeImageDecoder {
    static func decode(_ data: Data) -> UIImage? {
        guard !Task.isCancelled, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1, count <= 300 else { return UIImage(data: data) }
        var frames: [UIImage] = []
        var duration: TimeInterval = 0
        var pixels = 0
        for index in 0..<count {
            if Task.isCancelled { return nil }
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 4096, height <= 4096 else { return UIImage(data: data) }
            pixels += width * height
            // Bound animation decode memory, not just the encoded file's size.
            guard pixels <= 16_000_000,
                  let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { return UIImage(data: data) }
            let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            let ticks = min(100, max(1, Int((max(0.02, min(delay, 2)) / 0.02).rounded())))
            let frame = UIImage(cgImage: cgImage)
            frames.append(contentsOf: repeatElement(frame, count: ticks))
            duration += Double(ticks) * 0.02
        }
        return UIImage.animatedImage(with: frames, duration: duration)
    }
}

private struct NativeImageDisplay: UIViewRepresentable {
    let image: UIImage
    let aspectFit: Bool
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
        if view.image !== image { view.image = image }
    }
}

private struct NativeZoomImage: UIViewRepresentable {
    let image: UIImage
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
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
        return scroll
    }
    func updateUIView(_ scroll: UIScrollView, context: Context) {
        if context.coordinator.imageView.image !== image {
            scroll.setZoomScale(1, animated: false)
            context.coordinator.imageView.image = image
        }
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    }
}
