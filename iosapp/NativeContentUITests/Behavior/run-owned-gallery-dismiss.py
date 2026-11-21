#!/usr/bin/env python3
"""Prepare a frozen programmatic iOS gallery/owned-navigation regression.

No SSH: execute the emitted request only through an authorized serialized wrapper.
This replays mounted shipping Button actions and public UIKit drag callbacks, not
physical touch. Kotlin/image I/O and unrelated destination factories are boundaries.
"""
from pathlib import Path
import argparse, hashlib, json, plistlib, re

HERE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--prepare-request', required=True, type=Path)
parser.add_argument('--repo', type=Path, default=HERE.parents[2])
args = parser.parse_args()
repo = args.repo.resolve()
request = args.prepare_request.resolve()
request.parent.mkdir(parents=True, exist_ok=True)
stage = request.with_suffix('.inputs')
stage.mkdir(parents=True, exist_ok=False)
originals = repo
base = 'iosapp/Nodyssey/Native/'
nav = base + 'Foundation/NativeOwnedNavigation.swift'
image = base + 'Platform/NativeRemoteImage.swift'
media = base + 'Media/NativeMediaScreens.swift'
inputs = [
    'iosapp/NativeCore/Sources/NodysseyNativeCore/JSONValue.swift',
    'iosapp/NativeCore/Sources/NodysseyNativeCore/NativeFailure.swift',
    'iosapp/NativeCore/Sources/NodysseyNativeCore/NativeMutationState.swift',
    'iosapp/NativeCore/Sources/NodysseyNativeCore/NativeRequestState.swift',
    'iosapp/NativeCore/Sources/NodysseyNativeCore/NativeRoute.swift',
    'iosapp/NativeCore/Sources/NodysseyNativeCore/NativeTransport.swift',
    'iosapp/Nodyssey/Native/Content/ContentBackSwipe.swift',
    'iosapp/Nodyssey/Native/Content/ContentImageGallery.swift',
    'iosapp/Nodyssey/Native/Content/ContentRichBody.swift',
    'iosapp/Nodyssey/Native/Foundation/NativeAppModel.swift',
    'iosapp/Nodyssey/Native/Foundation/NativeDestination.swift',
    'iosapp/Nodyssey/Native/Foundation/NativeOwnedNavigation.swift',
    'iosapp/Nodyssey/Native/Foundation/NativePresentation.swift',
    'iosapp/Nodyssey/Native/Foundation/NativePressStyle.swift',
    'iosapp/Nodyssey/Native/Foundation/NativeRefreshCompletion.swift',
    'iosapp/Nodyssey/Native/Foundation/NativeRefreshState.swift',
    'iosapp/Nodyssey/Native/Foundation/NativeScreen.swift',
    'iosapp/Nodyssey/Native/Foundation/NativeStore.swift',
    'iosapp/Nodyssey/Native/Media/NativeMediaScreens.swift',
    'iosapp/Nodyssey/Native/Platform/NativeImagePlayback.swift',
    'iosapp/Nodyssey/Native/Platform/NativeImageState.swift',
    'iosapp/Nodyssey/Native/Platform/NativeRemoteImage.swift',
    'iosapp/Nodyssey/Native/Platform/NativeShare.swift',
    'iosapp/Nodyssey/Native/Rendering/NativeInlineArrangement.swift',
    'iosapp/Nodyssey/Native/Rendering/NativeRenderingMemo.swift',
    'iosapp/Nodyssey/Native/Rendering/NativeRichSelection.swift',
    'iosapp/Nodyssey/Native/Rendering/NativeRichText.swift',
    'iosapp/Nodyssey/Native/Rendering/RichDocument.swift',
]
def text(p): return (originals/p).read_text()
def swap(source, before, after):
    assert source.count(before)==1, before
    return source.replace(before,after,1)
def write(name, data):
    target=stage/name; target.parent.mkdir(parents=True,exist_ok=True)
    target.write_bytes(data.encode() if isinstance(data,str) else data)

for path in inputs:
    write('originals/'+path,(originals/path).read_bytes())
# Compile and extract only the frozen copy, never re-read a moving worktree.
originals = stage/'originals'
write('recipe.py', Path(__file__).read_bytes())
common=[p for p in inputs if p not in (nav,image,media,base+'Platform/NativeImageState.swift',base+'Foundation/NativeScreen.swift',base+'Content/ContentRichBody.swift') and p.startswith(base)]
core=[p for p in inputs if p.startswith('iosapp/NativeCore/')]
for path in core+common+[nav,image]: write(path,(originals/path).read_bytes())
# Exact ImageViewer factory case and any close adapter between factory and first unrelated screen.
m=text(media)
fragment=m[m.index('        case "ImageViewer":\n'):m.index('        case "Web":\n')]
# Include real declarations added between factory and unrelated NativeImageHostScreen.
tail=m[m.index('    private static func invalid()'):m.index('struct NativeImageHostScreen')]
header='import SwiftUI\nimport NodysseyNativeCore\n@MainActor enum ProbeMediaRoute {\n    static func make(destination: NativeDestination) -> AnyView? {\n        let args = destination.arguments\n        switch destination.route {\n'
def factory(body): return header+body+'        default: return nil\n        }\n    }\n'+tail
write('ExactMediaRoute.swift',factory(fragment))
# Empty URLs aren't admitted by the shipping factory. Relax only the two validation
# predicates for the synthetic empty-only fixture; construction/close remain production.
empty=swap(fragment,', !values.isEmpty,',',')
empty=swap(empty,'guard index >= 0, index < Int64(urls.count) else','guard index >= 0, urls.isEmpty || index < Int64(urls.count) else')
write('ProbeMediaRoute.swift',factory(empty))
write('ImageScope.swift','import Foundation\nstruct NativeImageScope:'+text(base+'Platform/NativeImageState.swift').split('struct NativeImageScope:',1)[1].split('@MainActor',1)[0])
n=swap(text(nav),'        owner.apply(rootID:', '        Actions.owners[stack == .sheet ? "sheet" : "home"] = owner\n        owner.apply(rootID:')
n+='''
extension NativeOwnedNavigationController {
    func probeAtRest(_ id: UUID?) -> Bool {
        active && motion == nil && projection == nil && visible?.id == id &&
            visible?.surface.window != nil && visible?.surface.superview === view
    }
    var probeVisibleDescription: String { visible?.id?.uuidString ?? "none" }
    var probeDescription: String { "active=\\(active) visible=\\(probeVisibleDescription) mounted=\\(visible?.surface.window != nil) motion=\\(motion != nil) projection=\\(projection != nil)" }
    var probeZoomReady: Bool { visible.map { ProbeDrag.isReady(in: $0.view) } == true }
    func probeDrag(distance: CGFloat) -> Bool {
        visible.map { ProbeDrag.run(in: $0.view, distance: distance) } == true
    }
}
'''
write('ProbeOwned.swift',n)
i=text(image)
# Extract the original closure's actual callable expression, using it once for the
# real mounted Button and once for the representable that captures the same action.
actions=list(re.finditer(r'Button\("Close"\) (\{ [^\n{}]+ \})', i))
assert len(actions)==2
for match, key in reversed(list(zip(actions,['Actions.empty','url']))):
    start,end=match.span(); action=match.group(1)
    i=i[:start]+f'let action = {action}; Button("Close", action: action).background {{ ActionCapture(name: {key}, action: action) }}'+i[end:]
i=swap(i,'.accessibilityAction { viewing = true }','.accessibilityAction { viewing = true }\n                        .background { ActionCapture(name: "open-cover", action: { viewing = true }) }')
i+='''
@MainActor enum ProbeDrag {
    final class EndedPan: UIPanGestureRecognizer {
        let distance: CGFloat
        init(distance: CGFloat) { self.distance = distance; super.init(target: nil, action: nil) }
        override var state: UIGestureRecognizer.State { get { .ended } set {} }
        override func translation(in view: UIView?) -> CGPoint { CGPoint(x: 0, y: distance) }
    }
    private static func zoom(in view: UIView) -> NativeZoomImage.ViewerScrollView? {
        if let scroll = view as? NativeZoomImage.ViewerScrollView, scroll.window != nil { return scroll }
        for child in view.subviews { if let hit = zoom(in: child) { return hit } }
        return nil
    }
    static func isReady(in view: UIView) -> Bool {
        guard let scroll = zoom(in: view), let c = scroll.delegate as? NativeZoomImage.Coordinator else { return false }
        return c.imageView.image != nil
    }
    static func run(in view: UIView, distance: CGFloat) -> Bool {
        guard let scroll = zoom(in: view), let c = scroll.delegate as? NativeZoomImage.Coordinator else { return false }
        let pan = EndedPan(distance: distance)
        scroll.addGestureRecognizer(pan)
        c.drag(pan)
        scroll.removeGestureRecognizer(pan)
        return true
    }
}
'''
# .ended setter is public for a UIGestureRecognizer subclass via subclass import.
i='import UIKit.UIGestureRecognizerSubclass\n'+i
write('ProbeImage.swift',i)
for source, name in [('OwnedGalleryDismissProbe.swift', 'Probe.swift'), ('OwnedGalleryDismissBoundaries.swift', 'Boundaries.swift')]:
    write(name, (HERE/source).read_bytes())
write('NodysseyShell.swift','''public struct NativePlatform {
    public static let shared = NativePlatform()
    public func isExternalBrowserUrl(url: String) -> Bool { false }
}
''')
write('Probe.app/Info.plist',plistlib.dumps({'CFBundleIdentifier':'invalid.nodyssey.union-owned-dismiss','CFBundleExecutable':'OwnedDismiss','CFBundleName':'OwnedDismiss','CFBundlePackageType':'APPL','CFBundleVersion':'1','MinimumOSVersion':'16.0','UILaunchScreen':{},'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False,'UISceneConfigurations':{}}}))
for name, paths in {'core':core,'device':common+[nav,image,'ExactMediaRoute.swift','ImageScope.swift','Boundaries.swift','DeviceFixtureSignatures.swift'], 'sim':common+['ProbeOwned.swift','ProbeImage.swift','ProbeMediaRoute.swift','ImageScope.swift','Boundaries.swift','Probe.swift']}.items():
    write(name+'.rsp','\n'.join(paths)+'\n')
# Device-only typecheck sees unmodified gallery/viewer, representable and original route branch.
write('DeviceFixtureSignatures.swift','''import SwiftUI
@MainActor enum Actions { static let cover = "https://fixture.invalid/cover.png" }
''')
command=r'''set -euxo pipefail
swiftc --version
xcodebuild -version
DEVICE_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
SIM_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphoneos --show-sdk-version
xcrun --sdk iphonesimulator --show-sdk-version
mkdir -p device-modules sim-modules
xcrun --sdk iphoneos swiftc -target arm64-apple-ios16.0 -sdk "$DEVICE_SDK" -swift-version 5 -emit-module -module-name NodysseyNativeCore @core.rsp -emit-module-path device-modules/NodysseyNativeCore.swiftmodule
xcrun --sdk iphoneos swiftc -target arm64-apple-ios16.0 -sdk "$DEVICE_SDK" -swift-version 5 -emit-module -module-name NodysseyShell NodysseyShell.swift -emit-module-path device-modules/NodysseyShell.swiftmodule
xcrun --sdk iphoneos swiftc -target arm64-apple-ios16.0 -sdk "$DEVICE_SDK" -swift-version 5 -I device-modules -typecheck @device.rsp
printf '%s\n' DEVICE_IOS16_TYPECHECK_PASS
xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios16.0-simulator -sdk "$SIM_SDK" -swift-version 5 -emit-module -emit-library -static -module-name NodysseyNativeCore @core.rsp -emit-module-path sim-modules/NodysseyNativeCore.swiftmodule -o sim-modules/libNodysseyNativeCore.a
xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios16.0-simulator -sdk "$SIM_SDK" -swift-version 5 -emit-module -emit-library -static -module-name NodysseyShell NodysseyShell.swift -emit-module-path sim-modules/NodysseyShell.swiftmodule -o sim-modules/libNodysseyShell.a
xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios16.0-simulator -sdk "$SIM_SDK" -swift-version 5 -parse-as-library -I sim-modules -L sim-modules -lNodysseyNativeCore -lNodysseyShell @sim.rsp -o Probe.app/OwnedDismiss
codesign --force --sign - Probe.app
shasum -a 256 Probe.app/OwnedDismiss
RUNTIME=$(xcrun simctl list runtimes available -j | python3 -c 'import sys,json; print(next(r["identifier"] for r in json.load(sys.stdin)["runtimes"] if r["isAvailable"] and r["version"]=="26.5"))')
DEVICE=$(xcrun simctl create OwnedDismissUnion com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro "$RUNTIME")
trap 'xcrun simctl shutdown "$DEVICE" || true; xcrun simctl delete "$DEVICE" || true' EXIT
xcrun simctl boot "$DEVICE"
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl status_bar "$DEVICE" clear
xcrun simctl install "$DEVICE" Probe.app
xcrun simctl launch --stdout="$STAGE/app.stdout" --stderr="$STAGE/app.stderr" "$DEVICE" invalid.nodyssey.union-owned-dismiss
DATA=$(xcrun simctl get_app_container "$DEVICE" invalid.nodyssey.union-owned-dismiss data)
for i in $(seq 1 50); do [ ! -f "$DATA/Documents/result.txt" ] || break; sleep 1; done
python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); print("APP_STDOUT",pathlib.Path("app.stdout").read_text(errors="replace") if pathlib.Path("app.stdout").exists() else "missing");print("APP_STDERR",pathlib.Path("app.stderr").read_text(errors="replace") if pathlib.Path("app.stderr").exists() else "missing"); sys.exit(70) if not p.is_file() else None; b=p.read_bytes(); pathlib.Path("result.txt").write_bytes(b); lines=b.decode().splitlines(); print("RUNTIME_RESULTS_BEGIN", *lines, "RUNTIME_RESULTS_END", sep="\n"); assert lines[-1]=="COMPLETE cases=7" and sum(x.startswith(("PASS ","FAIL ")) for x in lines)==7; sys.exit(42 if any(s.startswith("FAIL ") for s in lines) else 0)' "$DATA/Documents/result.txt"
'''
files={str(p.relative_to(stage)):str(p) for p in sorted(stage.rglob('*')) if p.is_file()}
def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
(stage/'source-manifest.json').write_text(json.dumps({n:sha(p) for n,p in files.items()}, indent=2)+'\n')
files['source-manifest.json'] = str(stage/'source-manifest.json')
request.write_text(json.dumps({'files':files,'command':command,'timeout':440},indent=2)+'\n')
print(request)
