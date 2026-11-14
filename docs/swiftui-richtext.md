# Native SwiftUI rich text

## Integration surface

Production sources are the three files in `iosapp/Nodyssey/Native/Rendering/`:
`RichDocument.swift` (Foundation only), `NativeRichText.swift`, and `NativeCodeBlock.swift`.
They have no dependency on `NativeClient`, `JSONValue`, Compose, WebKit, HTML, or JavaScript.
Add them to the iOS app target, not to both the app and an imported renderer module.

```swift
let nodes = try JSONDecoder().decode([NativeRichNode].self, from: canonicalRichNodeJSON)
NativeRichTextView(nodes: nodes, actions: NativeRichTextActions(
    onImage: { url, alt in /* route to the surrounding gallery */ },
    onVote: { voteId in /* open native poll, load vote.get */ },
    onStardust: { request in /* review/confirm the complete receive-code request */ },
    onLink: { url in /* current-site-aware native routing or validated external navigation */ },
    onQuoteReference: { name, floor, url in /* preserve floor, jump within/cross thread */ },
    onCode: { code, action in /* native NodeQuality/YABS report/source/comparison owner */ }
))
```

These are callback examples, not network implementations. Nil callbacks are disabled or absent,
never fake successful actions. The renderer's default initializer is
`NativeRichTextView(nodes: [NativeRichNode], actions: NativeRichTextActions = .init())`.
The entire `NativeRichTextActions` initializer is optional/default-nil:

| Argument | Type and responsibility |
| --- | --- |
| `onImage` | `(String, String?) -> Void`: exact URL and alt, exposed by **Open in gallery** in the image context menu. Platform `NativeRemoteImage(url:aspectFit:)` already owns normal tap-to-view, retry, mobile-data consent and image accessibility. Do not put it inside another Button or disable it when this callback is nil. |
| `onVote` | `(Int64) -> Void`: exact marker ID. Open a native live poll. No title/options/counts/selected state are inferred from the cached marker. |
| `onStardust` | `(NativeStardustReceive) -> Void`: `memberId:Int64`, `refId:Int64`, `amount:Int`, `description:String`, `onetime:Bool`. Only **Review payment** is offered; the owner confirms spending, authenticates, calls the repository, and shows server results. |
| `onLink` | `(String) -> Void`: validated scheme, otherwise exact unnormalized canonical string. Resolve relative paths against the active site; do not discard thread hashes or blindly call a global URL opener. |
| `onQuoteReference` | `(String, String, String) -> Void`: name, floor, URL. A `qref` URL may lack its separately supplied `#3` floor; route with **both** fields. Without a handler the reference remains text, not a misleading active link. |
| `onCode` | `(NativeCode, NativeCodeAction) -> Void`: `.adaptedReport`, `.source`, `.compare`. Receives complete source, nullable language, spans and terminal columns. The owner calls shared NodeQuality/YABS parsers and persisted comparison basket APIs. With no handler, native source expansion and copy still work; no invented adapted report appears. |
| `codeContent` | `(NativeCode, NativeRichTextActions) -> AnyView`: optional inline code/report slot. Inherited unchanged through quotes, folds, every tab (including inactive tabs) and list items. Receives original code plus inherited callbacks, so source controls retain gallery/link/report actions. Nil renders `NativeCodeBlock` exactly as before; editor previews need not opt in. |

NodeQuality/YABS report parsing, adapted report cards, and comparison persistence are intentionally
**outside this renderer's ownership**. The callback hook is implemented; that does not mean a
consuming screen has wired/verified those features. The owner must provide a report error/unsupported
state rather than silently dropping unrecognized source. `NativeCodeBlock(code:actions:)` can also be
used standalone.

For image-tap gallery ownership (rather than the platform's single-image viewer), a future platform
extension should inject an optional open action into `NativeRemoteImage` itself, where the loaded/error
state is known. A high-priority parent gesture would steal retry/mobile-data consent and is not used.

## Wire compatibility and rendering

The authoritative model is `richtext/src/commonMain/kotlin/io/github/plaza/core/richtext/RichNode.kt`
and `core/ansi/AnsiDecoder.kt`. The decoder is a tagged `Codable` enum, not a parser for encoded HTML.

- All block tags: `p`, `h`, `img`, `vote`, `stardust`, `code`, `quote`, `tabs`, `fold`, `list`, `table`, `hr`.
- All **actual** inline tags: `t`, `a`, `sticker`, **`iimg`**, **`qref`**, `br`. `img` is the block tag;
  the decoder does not silently invent an inline alias.
- All combinations of `bold`, `italic`, `strikethrough`, `code` are preserved and rendered.
- Recursive quotes, ordered/unordered lists, tabs and folds keep structure. Folds honor `open` initially;
  tab subtrees stay mounted so nested folds retain state while switching tabs. If a view is reused for a
  different article/reply, give the renderer the owning content identity with `.id(...)`.
- Canonical table `cells` retain tappable links and native image thumbnails. When `cells` is empty or
  absent, legacy `rows:[[String]]` are promoted to unstyled inline text, exactly like Kotlin `content`.
- Text-only paragraphs/cells use native attributed `Text` with selection. Paragraphs containing images
  use a SwiftUI `Layout` for composed-character-safe word/CJK wrapping with actual `NativeRemoteImage`
  stickers/thumbnails. Selection is not contiguous across that media flow; it is not an HTML surface.
- IDs decode as `Int64` directly; unknown discriminators or missing/invalid required identities throw.
  Callers should surface decoding errors, not silently substitute an empty post. Unknown extra object
  fields are ignored by Codable. Nullable image alt and code language encode as explicit null for Kotlin
  readers, which require those keys even when their values are null.
- Code uses horizontally scrolling, selectable monospace `Text`, copy, native full-source presentation,
  and theme-aware foreground/background/bold/underline ANSI styling. `columns` is retained, not used to
  force reflow. Kotlin span offsets are UTF-16 **code units**. Invalid ranges/split surrogates are ignored;
  combining marks, variation selectors and ZWJ scalar boundaries remain valid. The conversion uses the
  attributed scalar view because `AttributedString.Index(String.Index, within:)` rejects an interior
  combining boundary. Overlapping spans apply in wire order.
- Link policy allows http/https without user-info, nonempty mailto, and relative `/path`/`#floor` values;
  rejects executable/unknown schemes, network-relative URLs, backslashes and controls. Attributed Text
  carries renderer-generated local action IDs, all intercepted with `.handled`/`.discarded`. No link
  is implicitly returned to the system. Navigation owners still enforce site/account boundaries.

## Parent integration evidence

The renderer and platform sources are included in branch commit `92336381d6d61cd463c85e26070a32db4f5fd126`. GitHub Actions run `43555353912` executed the same 12 rich-document tests successfully with full Xcode, as well as 20 NativeCore tests. Kotlin iOS production compilation succeeded, but its test-source compilation failed on an undeclared coroutines-test import; the focused fix is commit `33d782448dde7baf600006639e047e48642196f2`. That run never reached the Swift iOS app build. Runtime gallery, rich-text layout and callback consumption remain separate UI integration gates.

## Reproducible tests and honest limits

Run on any suitable Swift toolchain with `TMPDIR` pointing to a scratch directory:

```sh
sh iosapp/NativeRenderingTests/run-tests.sh
```

The harness copies **the actual production `RichDocument.swift`** into a temporary Swift package,
runs Swift Testing, and removes the temporary package. There is no second retained implementation.
`Package.swift` is a staging manifest, so use the wrapper rather than `swift test` in its source folder.

Approved nested SSH runner from this workspace:

```sh
python3 iosapp/NativeRenderingTests/run-mac-tests.py
python3 iosapp/NativeRenderingTests/run-mac-tests.py --typecheck-ui
```

It stages only beneath `/Users/steven/.cache/hermes-build/nodyssey-richtext`. Foundation test execution:
**12 tests passed**, Apple Swift **6.4.2**, macOS target **27.3**. The tests include verbatim checked-in
cache fixtures from `shared/src/androidHostTest/kotlin/io/github/nodyssey/data/PostDetailCacheTest.kt`
plus synthetic recursive/ANSI/identity fixtures; no authenticated/live forum data. RED failures were
observed before paragraph decoding, recursive variant decoding, old-table promotion, range conversion,
URL policy, tokenization, and explicit-null encoding were implemented.

The current Command Line Tools install needs explicit Swift Testing framework/plugin flags. Its default
SwiftPM build engine emits missing search-path warnings for Xcode-style developer directories but the
Swift Testing runner executes and passes. No directories or toolchains were modified to hide warnings.

The optional **macOS SwiftUI typecheck** also passes with Swift 6 and installed **MacOSX26.5.sdk**, targeting
macOS 13 (matching the older APIs used for iOS 16 support). Newer CLT MacOSX27.2.sdk references a missing
SwiftUI macro plugin, so it is not used for this check. The typecheck uses a clearly labeled, signature-only
`NativeRemoteImage` stand-in outside the test target; it does **not** execute images or prove UIKit/Kotlin
integration. No Xcode iOS build, simulator/device run, screenshot, accessibility runtime or UIKit test is
claimed. Parent integration must add target membership, wire callbacks on every consuming surface, and
run those iOS gates. Tab/fold state and media-flow layout require that runtime verification.

## Nested report slot (G-02)

`NativeRichTextActions.codeContent` is a SwiftUI-only owner slot, not a report parser or a new
settings model. Every recursive renderer already forwards the same actions value; the code
branch now consumes this slot before falling back to native source. No IDs, container state,
gallery or navigation behavior is changed, and no labels or localization keys are introduced.

Content should install a slot returning its existing `ContentReportView(inline: true)` with
inherited actions and encoded-code identity, and remove its top-level-only code special case.
That existing owner calls Kotlin `reports.parse`, observes `app.settings.reportFormat`, keeps
explicit Source/Adapted overrides local to the report, and preserves unrecognized raw source.
**Renderer availability alone does not establish that Content has installed the slot.** The
Content integration edit is separately reserved by the parent; this renderer change does not
modify `ContentRichBody.swift` without that reservation.

Reproduce the actual SwiftUI composition regression:

```sh
python3 iosapp/NativeRenderingTests/run-mac-tests.py --composition
```

The runner now stages beneath `/Users/steven/.cache/hermes-build/nodyssey-richtext/nested-reports`,
not another domain's staging directory. The composition suite compiles all three actual renderer
sources and mounts `NativeRichTextView` in an `NSHostingView`; no duplicate tree walker or
source-string assertions are used. One fixture exercises root, quote, open fold, both tabs
(including the inactive tab), and nested list code. It asserts exact original code metadata/ANSI
spans and inherited gallery, link, quote-reference, exact Int64 poll and source-report callbacks.
The platform image boundary fails if invoked; these code-only fixtures do not fake image loading.

Executed with Apple Swift 6.4.2: **12 Foundation tests and 1 hosted composition test passed**;
renderer SwiftUI signature typecheck against MacOSX26.5/macOS 13 also passed. The slot API first
produced an API-absence compile failure; with only the optional API seam in place, the hosted
regression then failed **11 executable assertions** because no code slot was consumed. Wiring
the production code branch made the same test pass. Logs are `nested-report-behavior-red.log`
and `nested-report-final-{foundation,composition,typecheck}.log` in the task scratch directory.
CLT missing-framework-path warnings and the existing macOS 14 `onChange` deprecation remain;
that API is retained for iOS 16 compatibility. Two SSH banner timeouts required retries.

This is actual macOS renderer composition, not an iOS/Kotlin link, a parser/persistence replay,
or simulator/device report-picker, tab/fold-state, Dynamic Type or accessibility acceptance.
Those Apple integration gates and the consumer-slot wiring remain separately reportable.
