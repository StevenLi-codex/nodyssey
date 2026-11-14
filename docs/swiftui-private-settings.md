# Public settings private-history boundary

## Implemented policy

`NativeSettingsMapping.kt` exports device preferences only. It omits `searchHistory` and `recentBoards` entirely from **every** public settings snapshot, including READY admission. This covers `settings.get`, `settings.observe`, and mutation responses through their shared mapper. It deliberately does not emit fake empty history, copy activity into Swift state, or decide that current cookies own legacy rows. An already-built/queued public DTO cannot contain these private fields when the identity changes.

The unchanged dedicated supplement operations remain the history consumers: `search.history.get`, `search.history`, record/remove/clear, and `boards.recent.get`, `boards.recent`, record. These operations are not public exemptions in `NativeBridge`; they retain protected admission. The editor already calls `boards.recent.get` rather than reading settings fields. This settings patch neither grants them admission nor replaces their repository operations.

Mixed Preferences inventory classification:

- `search_history_v3`, legacy `recent_searches`, and `recent_boards`: private activity, not device preferences. The legacy key must be considered alongside v3 to prevent fallback resurrection.
- Appearance, language, home-board arrangement, toolbars, capabilities/preferences, and `readHistoryLimit`: device-global preferences. Preserve them; do not clear the whole Preferences file.
- Explicit private-history reset/inventory integration belongs to the container owner. The concurrent container implementation now includes a selective `settings-history` participant; this settings patch does not edit or independently accept that implementation.

No stored history or unrelated preference is deleted by this patch. Shared/Android repository implementation and defaults are unchanged.

## Limit mutation

Although `settings.set` remains public, the `readHistoryLimit` branch acquires the **existing** `graph.privateBoundary.protect` lease before either writing the preference or trimming private history. It keeps the existing settings mutex and calls the existing protected `PostRepository.trimReadHistory` after persistence, so the trim sees the new limit. Unknown or switched-owner admission fails before persistence.

A transition/cancellation can occur after DataStore commits and before the nested trim is admitted. That failure now compensates only the limit preference with `NonCancellable`, **inside the same lease and settings mutex**, then rethrows. Revocation therefore joins the compensation instead of returning while a partial preference remains. No new coordinator API or Android hook was introduced.

This is not a distributed transaction across Room and DataStore. Process death, storage failure during compensation, and partially completed destructive Room work cannot be rolled back by this settings-local change. The tests establish admission-refusal and controlled revocation behavior, not crash-atomic history trimming.

## Behavioral evidence

Run from the repository root:

```sh
python3 iosapp/tests/private_settings_test.py --repeat 3
```

Final post-format artifact directory:
`/home/hermes/.hermes/cache/scratch/native-private-settings-9ozyr9lp`

Each run executes 10 new settings-boundary cases plus 19 existing settings mapping/persistence/image-host cases: 29 passed, zero failures/ignored, repeated three times. The new cases cover:

- UNKNOWN get and observe, with legacy activity preserved.
- READY A and A→B get, including a retained A DTO.
- A continuing public observer before/after A→B.
- UNKNOWN and A→B limit refusal, verified against actual DataStore and after close/reopen.
- Owner change after preference commit but before protected trim.
- Revocation/cancellation after commit, with joined compensation before transition completes.
- Admitted limit mutation still invoking trim with the new persisted limit.
- Unrelated public preference mutation while private admission is denied.

Genuine pre-fix RED logs (not synthetic mutations):

- Public DTO exposure: `native-private-settings-foql_pez/tests-1.log` — all four get/observe cases failed on exported `searchHistory`.
- Initial UNKNOWN limit refusal: `native-private-settings-xowozh7l/tests-1.log` — persisted 100 instead of unchanged 300.
- A→B refusal: `native-private-settings-nwtuw74w/tests-1.log` — same partial write.
- Owner change after commit: `native-private-settings-w9er3oht/tests-1.log` — the initial lease-only fix still left 100 instead of 300.
- Revocation after commit: `native-private-settings-vfcw06ri/tests-1.log` — the initial lease-only fix still left 100 instead of 300.

Paths above are relative to `/home/hermes/.hermes/cache/scratch/`. Each successful compilation also archives source hashes. An early fixture typo was a compiler error, not RED evidence. One parallel compiler run hit a mutable build-jar mmap failure; the harness now snapshots and validates built jars into its unique scratch directory before compiling.

The harness compiles unchanged production `NativeSettings.kt`, its mapping, `SettingsRepository`, `PrivatePostRepository`, boundary/provenance/barrier sources, and existing concrete iosTest suites against real pinned JVM domain jars. New cases use real temporary file-backed DataStore; their graph/context is a JVM dependency fixture. The raw broad PostRepository delegate records trim calls/visible limits, while admission is the actual production protected wrapper. No live transport or production data is used. This is **not** real Room deletion, NativeBridge callback delivery, IosAppContainer runtime integration, Kotlin/Native compilation, or Apple execution.

Scoped Spotless IDE hook completed with `IS CLEAN`; scoped `git diff --check` passed. Gradle reports this linux-aarch64 host unsupported for Kotlin/Native, so Apple compilation/export/runtime remain separate gates.

## Parent integration handoff

The older JVM harness `iosapp/tests/native_release_notes_test.py` currently fails compilation because its generated `SettingsCompileGraph` lacks the existing iOS `privateBoundary` property now consumed by settings. The image-host and supplement legacy harnesses also declare that older graph shape by inspection. Their fixture graph signatures need to expose `PrivateSessionBoundary` (without adding a new application API). They are outside this subtask's ownership and were not changed. The new harness successfully runs the existing settings mapping/persistence/image-host suites with the correct graph signature.

Only `NativeSettings.kt`, `NativeSettingsMapping.kt`, the new settings harness/fixture, and this document were edited in the repository. No bridge, container, coordinator, live reset, commit, or push was performed.
