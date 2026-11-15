"""Build a JVM graph fixture from exact iOS inventory/wrapper/dispatch regions.

Not an IosAppContainer Apple construction test. Platform paths, cookies, Coil and
scheduler are fixtures; repositories, Room, DataStore, boundary and dispatch are real.
"""
import hashlib
import json
import re


def prepare(root, out, main):
    graph_path = root / 'iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/IosAppContainer.kt'
    graph = graph_path.read_text()
    generated = (out / 'Graph.kt').read_text()
    generated = generated[:generated.index('val privateBoundary:')]
    wrappers = {}
    for name, end in [('postComposerRepository', '    override val accountSettingsRepository'),
                      ('commentComposerRepository', '    override val postEditor'),
                      ('offlineLibrary', '    private val rawOfflineLibrary')]:
        start = graph.index('    override val ' + name)
        wrappers[name] = graph[start:graph.index(end, start)].replace('override val', 'val')
        generated = re.sub(r'^val ' + name + r':.*\n', '', generated, flags=re.M)
    dependencies = {
        'postDraftStore': 'androidx.datastore.core.DataStore<androidx.datastore.preferences.core.Preferences>',
        'commentDraftStore': 'androidx.datastore.core.DataStore<androidx.datastore.preferences.core.Preferences>',
        'settingsDataStore': 'androidx.datastore.core.DataStore<androidx.datastore.preferences.core.Preferences>',
        'database': 'io.github.nodyssey.data.local.NodeSeekDatabase',
        'sessionCookies': 'io.github.plaza.core.net.SessionCookies',
        'rawPostRepository': 'io.github.nodyssey.data.PostRepository',
        'rawOfflineLibrary': 'io.github.nodyssey.data.offline.RoomOfflineLibrary',
        'offlineFiles': 'GraphFiles',
        'transport': 'io.github.plaza.core.net.HttpTransport',
        'dispatchers': 'io.github.plaza.core.AppDispatchers',
        'profileRepository': 'io.github.nodyssey.data.ProfileRepository',
        'userNoteStore': 'io.github.nodyssey.data.UserNoteStore',
        'trackedThreadStore': 'io.github.nodyssey.data.TrackedThreadStore',
        'reportCompareStore': 'io.github.nodyssey.data.settings.ReportCompareStore',
        'settingsRepository': 'io.github.nodyssey.data.settings.SettingsRepository',
    }
    for name, kind in dependencies.items():
        if not re.search(r'^val ' + name + ':', generated, re.M):
            generated += f'val {name}: {kind} get() = values.getValue("{name}") as {kind}\n'
    region = graph[graph.index('    internal val privateBoundary:'):graph.index('    override val postComposerRepository:')]
    generated += region + '\n'.join(wrappers.values())
    generated += '''
fun createPreferenceDataStore(name: String, keepOutOfBackup: Boolean = false) = values.getValue(name) as androidx.datastore.core.DataStore<androidx.datastore.preferences.core.Preferences>
}
object NodysseyApp {
    lateinit var fixture: IosAppContainer
    var graphRequests = 0
    suspend fun ensureContainer(): IosAppContainer { graphRequests++; return fixture }
    suspend fun nativeForeground(): Unit = error("Unused foreground platform scheduler")
}
'''
    imports = '''import androidx.room.useReaderConnection
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import io.github.nodyssey.data.NotificationCounts
import io.github.nodyssey.data.session.*
import io.github.nodyssey.data.composer.*
import io.github.nodyssey.data.OfflineLibrary
import kotlinx.coroutines.flow.first
import coil3.PlatformContext
import coil3.SingletonImageLoader
'''
    generated = generated.replace('package io.github.nodyssey.ios\n', 'package io.github.nodyssey.ios\n' + '\n'.join(line for line in imports.splitlines() if line not in generated.splitlines()) + '\n')
    app_path = root / 'iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/NodysseyApp.kt'
    app = app_path.read_text()
    # Verbatim public bootstrap; only the surrounding Apple object construction is substituted.
    metadata = app[app.index('    internal fun nativeSiteMetadata()'):app.index('    /** Native scene activation:')]
    generated = generated.replace('    lateinit var fixture: IosAppContainer', metadata + '    lateinit var fixture: IosAppContainer')
    (out / 'bootstrap-source-hashes.json').write_text(json.dumps({str(app_path): hashlib.sha256(app_path.read_bytes()).hexdigest(),
        'extracted_metadata_sha256': hashlib.sha256(metadata.encode()).hexdigest()}, indent=2))
    (out / 'Graph.kt').write_text(generated)
    content_path = main / 'NativeContent.kt'
    settings_path = main / 'NativeSettings.kt'
    content, settings = content_path.read_text(), settings_path.read_text()
    drafts = content[content.index('        "draft.post.get"'):content.index('        "notifications.', content.index('        "draft.post.get"'))]
    # Draft block ends before the next domain (no fake repository responses).
    offline = settings[settings.index('        "offline.get"'):settings.index('        "cache.size"')]
    flow = settings[settings.index('private fun NativeContext.offlineFlow()'):settings.index('private fun NativeContext.notesFlow()')]
    ids = settings[settings.index('private fun JsonObject.settingsId('):settings.index('private fun JsonObject.settingsRepo()')]
    permission = content[content.index('private fun JsonObject.nativePermission()'):]
    # only nativePermission, not unrelated editor helpers
    permission = permission.split('\nprivate fun ', 1)[0]
    permission += '\n' + next(line for line in content.splitlines() if line.startswith('private fun JsonObject.nativeOptionalInt')) + '\n'
    (out / 'UnusedDomains.kt').write_text('''package io.github.nodyssey.ios.native
import io.github.nodyssey.data.composer.*
import io.github.nodyssey.data.OfflineSettings
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
internal suspend fun NativeContext.contentRequest(op: String, a: JsonObject): JsonElement? = when(op) {
''' + drafts + '''else -> null
}
internal suspend fun NativeContext.settingsRequest(op: String, args: JsonObject): JsonElement? {
when(op) {
''' + offline + '''else -> return null
}
}
internal fun NativeContext.contentObserve(op: String, args: JsonObject): Flow<JsonElement>? = null
internal fun NativeContext.settingsObserve(operation: String, args: JsonObject): Flow<JsonElement>? = when(operation) {
''' + next(line for line in settings.splitlines() if '"settings.observe" ->' in line) + '''
    "offline.observe" -> offlineFlow()
    else -> null
}
''' + flow + ids + permission)
    # Run the real supplement dispatcher/site mapper, not a successful site.get stub.
    (out / 'SitePreferences.kt').write_text('''package platform.Foundation
class NSUserDefaults {
    val values = mutableMapOf<String, String>()
    var writes = 0
    fun stringForKey(key: String): String? { check(key == "active_site"); return values[key] }
    fun setObject(value: Any?, forKey: String) { check(forKey == "active_site"); writes++; values[forKey] = value as String }
    companion object { val standardUserDefaults = NSUserDefaults() }
}
''')
    sources = [main / 'NativeContentMapping.kt', main / 'NativeSettingsMapping.kt', main / 'NativeSupplement.kt',
               out / 'SitePreferences.kt',
               root / 'iosapp/tests/fixtures/NativePrivateGraphIntegrationTest.kt',
               root / 'iosapp/tests/fixtures/PrivateGraphPlatformFixture.kt']
    # Compile current boundary sources, not a potentially stale shared jar.
    sources += list((root / 'shared/src/commonMain/kotlin/io/github/nodyssey/data/session').glob('Private*.kt'))
    sources += [root / 'shared/src/commonMain/kotlin/io/github/nodyssey/data/session/SessionWorkBarrier.kt']
    sources += [root / ('shared/src/commonMain/kotlin/io/github/nodyssey/data/composer/' + name) for name in ['PostComposerRepository.kt', 'CommentComposerRepository.kt']]
    (out / 'source-hashes.json').write_text(json.dumps({str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources + [graph_path, content_path, settings_path, main / 'NativeBridge.kt']}, indent=2))
    (out / 'Coil.kt').write_text('''package coil3
object PlatformContext { val INSTANCE = this }
class FixtureCache { val keys = mutableSetOf<String>(); val size: Long get() = keys.size.toLong(); fun clear() { keys.clear() } }
class FixtureLoader { val memoryCache: FixtureCache? = FixtureCache(); val diskCache: FixtureCache? = FixtureCache() }
object SingletonImageLoader { val loader = FixtureLoader(); fun get(context: PlatformContext) = loader }
''')
    sources.append(out / 'Coil.kt')
    scheduler_path = root / 'iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/BgTaskOfflineScheduler.kt'
    scheduler = scheduler_path.read_text()
    launch_private = scheduler[scheduler.index('    private fun launchPrivate('):scheduler.index('    /**', scheduler.index('    private fun launchPrivate('))]
    start_drain = scheduler[scheduler.index('    override fun startDrain('):scheduler.index('    override fun ensureMaintenance()')]
    (out / 'Scheduler.kt').write_text('''package io.github.nodyssey.ios
import io.github.nodyssey.data.offline.*
import io.github.nodyssey.data.session.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
class BGProcessingTaskRequest(val id: String) { var requiresNetworkConnectivity = false }
/** Exact launchPrivate/startDrain; task submission and Network.framework are NOT exercised. */
class GraphScheduler(private val scope: CoroutineScope, private val container: suspend () -> IosAppContainer?) : OfflineWorkScheduler {
    private var foregroundDrain: Job? = null
    private var boundary: PrivateSessionBoundary? = null
    private val restartGate = Mutex()
    fun attach(boundary: PrivateSessionBoundary) { this.boundary = boundary }
    private val DRAIN_TASK_ID = "fixture"
    private suspend fun networkAllows(wifiOnly: Boolean) = true
    private fun submit(request: BGProcessingTaskRequest) = Unit
    override fun ensureMaintenance() = Unit
''' + launch_private + start_drain + '\n}\n')
    sources.append(out / 'Scheduler.kt')
    (out / 'scheduler-source-hash.json').write_text(json.dumps({str(scheduler_path): hashlib.sha256(scheduler_path.read_bytes()).hexdigest()}, indent=2))
    return list(map(str, sources))