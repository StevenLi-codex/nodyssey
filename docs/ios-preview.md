# Nodyssey Preview — guest-only prerelease

This isolated branch starts from verified simulator-built snapshot `47c7ae5324cfe373c37009e523abb237a016735b`. It does not include the concurrent account-isolation work in the development checkout.

- Independent bundle: `io.github.nodyssey.preview`; display name: **Nodyssey Preview**. Keep that bundle ID when resigning. No app groups or keychain-sharing entitlements are requested. Do not restore/copy the main application's data into this sandbox.
- The Kotlin request and observation bridge uses a production, default-deny allowlist before resolving the application graph. Login, session sync, private-account reads, writes, payments/transfers, uploads, imports and resets are denied. Unknown future operations are denied.
- Every native browser session is refused before WebKit cookie seeding or observer startup, including Cloudflare challenge browsers, because an unrestricted challenge page could navigate to login. External browser routes are also unavailable. Any signed-in session causes bridge and image requests to fail closed; no data is reset to recover it.
- Public feeds, threads, search and public user pages use the real network. Reading-position/history writes are local to this independent guest sandbox. Basic appearance and onboarding settings remain available.
- Cloudflare may block public browsing. This preview does not bypass that protection. No fabricated feed is substituted.

## Artifact and installation

The separate `ios-preview.yml` workflow archives the real ARM64 device application with Xcode, checks its identity and packages `nodyssey-preview-unsigned.ipa`. A successful archive is **not** full acceptance. The existing full verification workflow is unchanged.

Use your own IPA signing service to sign the IPA (and embedded frameworks if required). Preserve the preview bundle ID or use another unique ID, never the main app ID. Install the resulting signed IPA on a provisioned compatible iPhone. This build has not been physically installed by CI and does not contain an Apple signing identity or provisioning profile.

## Known limitations

This is not a production/account-enabled release. The baseline's standalone SVG diagnostic remains red, and two navigation-container oracle tests remain failed. Assertions are not weakened or changed to green. Preview archive production does not wait for those unrelated full-suite gates. Browser login and account-feature acceptance are intentionally out of scope. The guest policy JVM test executes the production Kotlin policy; it is not an Apple runtime test.
