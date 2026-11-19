import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import NativeImage

func raster(width: Int = 16, height: Int = 8) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
    return data as Data
}

final class DecodeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var entered = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return entered }
    func enterAndWait() {
        lock.lock(); entered += 1; lock.unlock()
        gate.wait()
    }
    func release(_ count: Int) { for _ in 0..<count { gate.signal() } }
}

@Suite(.serialized) @MainActor struct NativeImageLifecycleTests {
    @Test func repeatedAppearanceJoinsPendingPlatformAccess() {
        NativePlatform.shared.reset()
        let state = NativeImageState()
        state.load("https://images.invalid/pending.png")
        state.load("https://images.invalid/pending.png")
        #expect(NativePlatform.shared.calls.count == 1)
        #expect(!NativePlatform.shared.calls[0].request.cancelled)
        state.cancel()
        #expect(NativePlatform.shared.calls[0].request.cancelled)
    }

    @Test func changedSecurityScopeRevokesRetainedImageAndRejectsLateBytes() async throws {
        NativePlatform.shared.reset()
        let app = NSObject()
        func scope(_ epoch: String, _ wifi: Bool) -> NativeImageScope {
            NativeImageScope(appIdentity: ObjectIdentifier(app), identityEpoch: epoch,
                boundaryEpoch: epoch, boundaryPhase: "READY", generation: 1,
                site: "NODESEEK", siteOrigin: "https://example.invalid", wifiOnly: wifi)
        }
        let state = NativeImageState()
        let url = "https://images.invalid/private.png"
        state.load(url, scope: scope("A", false))
        let old = NativePlatform.shared.calls[0]
        old.completion(raster() as NSData, nil)
        for _ in 0..<200 where state.image == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(state.image != nil)
        state.load(url, scope: scope("B", true))
        #expect(state.image == nil)
        #expect(state.data == nil)
        #expect(NativePlatform.shared.calls.count == 2)
        old.completion(raster() as NSData, nil) // uncooperative cancelled bridge
        for _ in 0..<10 { await Task.yield() }
        #expect(state.image == nil)
        NativePlatform.shared.calls.last!.completion(nil, "IMAGE_WIFI_ONLY")
        #expect(state.deferredForWifi)
        #expect(state.image == nil)
        state.cancel()
    }

    @Test func independentOwnersReuseOnlyAfterTheirOwnPlatformAdmission() async throws {
        NativePlatform.shared.reset()
        let first = NativeImageState()
        let second = NativeImageState()
        let data = raster(width: 21, height: 11)
        let url = "https://images.invalid/shared.png"
        first.load(url)
        NativePlatform.shared.calls.last!.completion(data as NSData, nil)
        for _ in 0..<200 where first.image == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        let image = try #require(first.image)
        second.load(url)
        #expect(NativePlatform.shared.calls.count == 2)
        #expect(second.image == nil) // no synchronous URL cache bypass of Kotlin protection
        NativePlatform.shared.calls.last!.completion(nil, "IMAGE_WIFI_ONLY")
        #expect(second.image == nil)
        second.load(url, allowMetered: true)
        #expect(NativePlatform.shared.calls.last!.allowMetered == true)
        NativePlatform.shared.calls.last!.completion(data as NSData, nil)
        for _ in 0..<200 where second.image == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(second.image === image)
        #expect(second.data == data)
    }

    @Test func staticThumbnailDecodesAtTargetSizeWithoutChangingOriginalBytes() throws {
        let data = raster(width: 1600, height: 800)
        let image = try #require(NativeImageDecoder.decode(data, maxPixel: 200))
        #expect(image.cgImage?.width == 200)
        #expect(image.cgImage?.height == 100)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let original = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(original.width == 1600)
        #expect(original.height == 800)
    }

    @Test func sameContentJoinsHeldDecodeAndCancelsOneWaiterPromptly() async throws {
        let probe = DecodeProbe()
        let pipeline = NativeImagePipeline(decode: { data, size in
            probe.enterAndWait()
            return NativeImageDecoder.decode(data, maxPixel: size)
        })
        defer { probe.release(10) }
        let data = raster(width: 22)
        var firstReturned = false
        let first = Task { let result = await pipeline.image(data, scope: nil); firstReturned = true; return result }
        for _ in 0..<200 where probe.count == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        let second = Task { await pipeline.image(data, scope: nil) }
        for _ in 0..<20 { await Task.yield() }
        first.cancel()
        for _ in 0..<20 { await Task.yield() }
        #expect(firstReturned) // must not wait for an uncooperative decode to finish
        #expect(probe.count == 1)
        probe.release(2)
        let a = await first.value
        let b = await second.value
        #expect(a == nil)
        #expect(b != nil)
    }

    @Test func globalBudgetQueuesDistinctImagesAndQueuedCancellationSkipsDecode() async throws {
        let probe = DecodeProbe()
        let pipeline = NativeImagePipeline(maxConcurrent: 2, decode: { data, size in
            probe.enterAndWait()
            return NativeImageDecoder.decode(data, maxPixel: size)
        })
        defer { probe.release(20) }
        let a = raster(width: 31), b = raster(width: 32), c = raster(width: 33)
        let first = Task { await pipeline.image(a, scope: nil) }
        let second = Task { await pipeline.image(b, scope: nil) }
        for _ in 0..<200 where probe.count < 2 { try await Task.sleep(nanoseconds: 1_000_000) }
        let queued = Task { await pipeline.image(c, scope: nil) }
        for _ in 0..<40 { await Task.yield() }
        #expect(probe.count == 2)
        queued.cancel()
        let cancelled = await queued.value
        #expect(cancelled == nil)
        probe.release(2)
        _ = await first.value; _ = await second.value
        #expect(probe.count == 2)
    }

    @Test func boundedCacheEvictsLeastRecentlyUsedDecodedImage() async throws {
        let pipeline = NativeImagePipeline(costLimit: 4096, countLimit: 2)
        let a = raster(width: 10), b = raster(width: 11), c = raster(width: 12)
        let original = try #require(await pipeline.image(a, scope: nil))
        let second = try #require(await pipeline.image(b, scope: nil))
        #expect(await pipeline.image(a, scope: nil) === original)
        _ = await pipeline.image(c, scope: nil)
        #expect(await pipeline.image(a, scope: nil) === original)
        let replacement = try #require(await pipeline.image(b, scope: nil))
        #expect(replacement !== second)
        let oversized = NativeImagePipeline(costLimit: 1)
        let one = await oversized.image(a, scope: nil)
        #expect(await oversized.image(a, scope: nil) !== one)
    }

    @Test func targetChangeCannotRetainPreviousSizeAndGifKeepsAllFrames() async throws {
        NativePlatform.shared.reset()
        let state = NativeImageState()
        let url = "https://images.invalid/sized.png"
        let bytes = raster(width: 1600, height: 800)
        state.load(url, maxPixel: 200)
        NativePlatform.shared.calls.last!.completion(bytes as NSData, nil)
        for _ in 0..<200 where state.image == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(state.image?.cgImage?.width == 200)
        #expect(state.data == bytes)
        state.load(url, maxPixel: 400)
        #expect(state.image == nil)
        #expect(NativePlatform.shared.calls.count == 2)
        NativePlatform.shared.calls.last!.completion(bytes as NSData, nil)
        for _ in 0..<200 where state.image == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(state.image?.cgImage?.width == 400)

        let gif = NSMutableData()
        let destination = CGImageDestinationCreateWithData(gif, "com.compuserve.gif" as CFString, 2, nil)!
        let frame = NativeImageDecoder.decode(raster(width: 120, height: 60))!.cgImage!
        for _ in 0..<2 {
            CGImageDestinationAddImage(destination, frame,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        let animated = try #require(NativeImageDecoder.decode(gif as Data, maxPixel: 10))
        #expect(animated.images?.first?.cgImage?.width == 120)
        #expect(animated.images?.count == 10)
        #expect(abs(animated.duration - 0.2) < 0.001)
    }

    @Test func reducedMotionStopsAlreadyPlayingAnimatedImage() throws {
        let frame = try #require(NativeImageDecoder.decode(raster(width: 13)))
        let animated = try #require(UIImage.animatedImage(with: [frame, frame], duration: 0.2))
        let view = UIImageView()
        view.image = animated
        view.startAnimating()
        NativeImagePlayback.update(view, image: animated, reduceMotion: true)
        #expect(!view.isAnimating)
        #expect(view.image === frame)
        NativeImagePlayback.update(view, image: animated, reduceMotion: false)
        #expect(view.image === animated)
        #expect(view.isAnimating)
    }

    @Test func identityRevocationPurgesDecodedImagesRatherThanResurrectingOldEpoch() async throws {
        let pipeline = NativeImagePipeline()
        let owner = NSObject()
        func scope(_ epoch: String) -> NativeImageScope {
            NativeImageScope(appIdentity: ObjectIdentifier(owner), identityEpoch: epoch, boundaryEpoch: epoch,
                boundaryPhase: "READY", generation: 1, site: "NODESEEK", siteOrigin: nil, wifiOnly: false)
        }
        let data = raster(width: 17)
        let a = try #require(await pipeline.image(data, scope: scope("A")))
        let b = try #require(await pipeline.image(data, scope: scope("B")))
        #expect(a !== b)
        #expect(await pipeline.image(data, scope: scope("A")) !== a)
    }

    @Test func failedDecodeCanRetryAndDeinitCancelsItsPlatformOwner() async throws {
        NativePlatform.shared.reset()
        var state: NativeImageState? = NativeImageState()
        state!.load("https://images.invalid/retry.png")
        NativePlatform.shared.calls.last!.completion(Data([0, 1, 2]) as NSData, nil)
        for _ in 0..<200 where !state!.failure { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(state!.failure)
        state!.load("https://images.invalid/retry.png")
        #expect(NativePlatform.shared.calls.count == 2)
        let request = NativePlatform.shared.calls.last!.request
        state = nil
        #expect(request.cancelled)
    }

    @Test func revokedHeldDecodeCannotPublishOrPopulateCache() async throws {
        let probe = DecodeProbe()
        let pipeline = NativeImagePipeline(decode: { data, size in
            probe.enterAndWait()
            return NativeImageDecoder.decode(data, maxPixel: size)
        })
        defer { probe.release(20) }
        let owner = NSObject()
        func scope(_ epoch: String) -> NativeImageScope {
            NativeImageScope(appIdentity: ObjectIdentifier(owner), identityEpoch: epoch, boundaryEpoch: epoch,
                boundaryPhase: "READY", generation: 1, site: "NODESEEK", siteOrigin: nil, wifiOnly: false)
        }
        let data = raster(width: 18)
        var returned = false
        let old = Task { let value = await pipeline.image(data, scope: scope("A")); returned = true; return value }
        for _ in 0..<200 where probe.count == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        pipeline.admitScope(scope("B"))
        for _ in 0..<20 { await Task.yield() }
        #expect(returned)
        let rejected = await old.value
        #expect(rejected == nil)
        probe.release(1)
        let fresh = Task { await pipeline.image(data, scope: scope("B")) }
        for _ in 0..<200 where probe.count < 2 { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(probe.count == 2)
        probe.release(1)
        #expect(await fresh.value != nil)
    }

    @Test func downsamplingDoesNotChangeLayoutAspectRatioThroughPixelRounding() async throws {
        NativePlatform.shared.reset()
        let state = NativeImageState()
        state.load("https://images.invalid/odd.png", maxPixel: 20)
        NativePlatform.shared.calls.last!.completion(raster(width: 301, height: 101) as NSData, nil)
        for _ in 0..<200 where state.image == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        let ratio = try #require(state.aspectRatio)
        #expect(abs(ratio - CGFloat(301) / CGFloat(101)) < 0.000001)
        #expect(state.image!.cgImage!.width <= 20)
    }

    @Test func memoryPressureDropsDecodedReuseButNotAnOwnersAcceptedPresentation() async throws {
        NativePlatform.shared.reset()
        let state = NativeImageState()
        let data = raster(width: 19)
        state.load("https://images.invalid/pressure.png")
        NativePlatform.shared.calls.last!.completion(data as NSData, nil)
        for _ in 0..<200 where state.image == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        let retained = try #require(state.image)
        NativeImagePipeline.shared.removeCachedImages()
        #expect(state.image === retained)
        #expect(await NativeImagePipeline.shared.image(data, scope: nil) !== retained)
    }

    @Test func sameLoadedAppearanceKeepsImageAndDoesNotDispatchAgain() async throws {
        NativePlatform.shared.reset()
        let state = NativeImageState()
        state.load("https://images.invalid/retained.png")
        let data = raster()
        NativePlatform.shared.calls[0].completion(data as NSData, nil)
        for _ in 0..<200 where state.image == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        let loaded = try #require(state.image)
        state.cancel() // disappear cancels work, not an already accepted presentation
        state.load("https://images.invalid/retained.png")
        #expect(state.image === loaded)
        #expect(state.data == data)
        #expect(NativePlatform.shared.calls.count == 1)
    }
}
