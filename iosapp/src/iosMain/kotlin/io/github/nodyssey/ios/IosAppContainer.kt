package io.github.nodyssey.ios

import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.room.useReaderConnection
import coil3.ImageLoader
import coil3.PlatformContext
import io.github.nodyssey.data.AppCacheStore
import io.github.nodyssey.data.AssetsRepository
import io.github.nodyssey.data.CollectedPostMetaStore
import io.github.nodyssey.data.MessageRepository
import io.github.nodyssey.data.NetworkAssetsRepository
import io.github.nodyssey.data.NetworkMessageRepository
import io.github.nodyssey.data.NetworkProfileRepository
import io.github.nodyssey.data.NetworkUserSpaceRepository
import io.github.nodyssey.data.NotificationCounts
import io.github.nodyssey.data.OfflineFirstPostRepository
import io.github.nodyssey.data.OfflineLibrary
import io.github.nodyssey.data.OfflineThreadReader
import io.github.nodyssey.data.PostCollectionWriter
import io.github.nodyssey.data.PostReactionWriter
import io.github.nodyssey.data.PostRepository
import io.github.nodyssey.data.ProfileRepository
import io.github.nodyssey.data.ReadingPositionStore
import io.github.nodyssey.data.RoomCollectedPostMetaStore
import io.github.nodyssey.data.RoomReadingPositionStore
import io.github.nodyssey.data.TitleKeywordStore
import io.github.nodyssey.data.TrackedThreadStore
import io.github.nodyssey.data.UserNoteStore
import io.github.nodyssey.data.UserSpaceRepository
import io.github.nodyssey.data.account.AccountSettingsRepository
import io.github.nodyssey.data.account.NetworkAccountSettingsRepository
import io.github.nodyssey.data.composer.CommentComposerRepository
import io.github.nodyssey.data.composer.DefaultCommentComposerRepository
import io.github.nodyssey.data.composer.DefaultPostComposerRepository
import io.github.nodyssey.data.composer.DefaultPostEditor
import io.github.nodyssey.data.composer.PostComposerRepository
import io.github.nodyssey.data.composer.PostEditor
import io.github.nodyssey.data.createPreferenceDataStore
import io.github.nodyssey.data.local.createNodeSeekDatabase
import io.github.nodyssey.data.offline.RoomOfflineLibrary
import io.github.nodyssey.data.offline.UrlSessionOfflineImageSource
import io.github.nodyssey.data.session.PrivateOfflineLibrary
import io.github.nodyssey.data.session.PrivateSessionBoundary
import io.github.nodyssey.data.session.PrivateStoreParticipant
import io.github.nodyssey.data.session.PrivateStoreProvenance
import io.github.nodyssey.data.settings.ReportCompareStore
import io.github.nodyssey.data.settings.SettingsRepository
import io.github.nodyssey.data.settings.WorkspaceSettingsDataStore
import io.github.nodyssey.di.AppContainer
import io.github.plaza.core.runCatchingExceptCancellation
import io.github.plaza.core.update.isPreReleaseVersionName
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import platform.Foundation.NSURL
/** Immutable, owned private repository snapshot. Never retarget a captured repository. */
@OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)
class IosAppContainer internal constructor(
    internal val services: IosGlobalServices,
    internal val workspaceId: String?,
    internal val workspaceRoot: String?,
) : AppContainer by services {
    internal val lifetime = io.github.nodyssey.data.session.PrivateWorkspaceLifetime()
    private val storeJob = SupervisorJob()
    private val storeScope = CoroutineScope(storeJob + dispatchers.io)
    private val transport get() = services.transport
    private val remotePosts get() = services.remotePosts
    private val htmlClient get() = services.htmlClient
    private val jsonClient get() = services.jsonClient
    private val sessionCookies get() = services.sessionCookies
    private val offlineScheduler get() = services.offlineScheduler
    internal val urlSession get() = services.urlSession
    private val databaseDelegate = lazy {
        if (workspaceRoot == null) createNodeSeekDatabase() else createNodeSeekDatabase("$workspaceRoot/private.db")
    }
    private val database get() = databaseDelegate.value
    private fun createPreferenceDataStore(name: String, keepOutOfBackup: Boolean = false) =
        io.github.nodyssey.data.createPreferenceDataStore(
            name,
            scope = storeScope,
            directory = workspaceRoot ?: if (keepOutOfBackup) legacyProvenanceDirectory() else requireNotNull(applicationSupportDirectory().path),
        )
    private val loaderDelegate = lazy {
        nodysseyImageLoader(PlatformContext.INSTANCE, privateBoundary, workspaceRoot?.let { "$it/cache/image_cache" }) { urlSession }
    }
    internal val imageLoader: ImageLoader get() = loaderDelegate.value

    internal suspend fun close() {
        // Every caller must first retire the boundary and join native/file/image/scheduler leases.
        lifetime.closeAndJoin()
        storeJob.cancelAndJoin()
        if (loaderDelegate.isInitialized()) {
            imageLoader.shutdown()
            imageLoader.diskCache?.shutdown()
        }
        if (databaseDelegate.isInitialized()) database.close()
    }
    override val postRepository: PostRepository by lazy { io.github.nodyssey.data.session.PrivatePostRepository(rawPostRepository, privateBoundary) }

    private val rawPostRepository: PostRepository by lazy {
        OfflineFirstPostRepository(
            database,
            remotePosts,
            clock,
            PostReactionWriter(jsonClient),
            settingsRepository.showBlockedContent,
            PostCollectionWriter(jsonClient),
            settingsRepository.settings.map { it.readHistoryLimit }.distinctUntilChanged(),
            offlineLibrary as? OfflineThreadReader,
            collectedPostMetaStore,
        )
    }

    override val collectedPostMetaStore: CollectedPostMetaStore by lazy {
        RoomCollectedPostMetaStore(database.collectedPostMetaDao(), clock)
    }

    override val userNoteStore: UserNoteStore by lazy { UserNoteStore(database.userNoteDao(), clock) }
    private val keywordDao by lazy {
        io.github.nodyssey.data.local.WorkspaceTitleKeywordDao(services.database.titleKeywordDao(), database.titleKeywordDao())
    }
    internal suspend fun prepare() {
        if (workspaceRoot != null) keywordDao.synchronize()
    }
    override val titleKeywordStore: TitleKeywordStore by lazy { TitleKeywordStore(keywordDao, clock) }
    override val trackedThreadStore: TrackedThreadStore by lazy { TrackedThreadStore(database.trackedThreadDao(), clock) }

    override val readingPositionStore: ReadingPositionStore by lazy {
        RoomReadingPositionStore(database.readingPositionDao(), clock)
    }

    private val settingsDataStore by lazy {
        if (workspaceRoot == null) services.settingsDataStore else createPreferenceDataStore("settings-private")
    }
    private val routedSettings by lazy {
        if (workspaceRoot == null) settingsDataStore else WorkspaceSettingsDataStore(services.settingsDataStore, settingsDataStore, services.settingsMutex)
    }

    override val settingsRepository: SettingsRepository by lazy {
        SettingsRepository(
            dataStore = routedSettings,
            devChannelDefault = isPreReleaseVersionName(appVersion.name),
        )
    }

    override val reportCompareStore: ReportCompareStore get() = settingsRepository.reportCompare
    override val messageRepository: MessageRepository by lazy {
        NetworkMessageRepository(jsonClient) {
            runCatchingExceptCancellation { profileRepository.profile().uid }.getOrNull()
        }
    }

    override val profileRepository: ProfileRepository by lazy {
        NetworkProfileRepository(
            htmlSource = htmlClient,
            jsonSource = jsonClient,
            profileDao = database.profileDao(),
            currentSessionFingerprint = { sessionRepository.state.value.fingerprint },
            isSignedIn = { sessionRepository.state.value.isSignedIn },
            clock = clock,
        )
    }
    private val postDraftStore by lazy { createPreferenceDataStore("post-composer") }
    private val commentDraftStore by lazy { createPreferenceDataStore("comment-composer") }
    internal val offlineFiles by lazy { IosOfflineFileStore.of(workspaceRoot?.let { NSURL.fileURLWithPath(it, isDirectory = true) } ?: applicationSupportDirectory()) }

    internal val privateBoundary: PrivateSessionBoundary by lazy {
        // Mixed store: history is owner-private; preferences remain device-global.
        // Include the legacy key as well: removing v3 alone would resurrect it on decode.
        val historyKeys = listOf("search_history_v3", "recent_searches", "recent_boards").map(::stringPreferencesKey)
        val participants = listOf(
            PrivateStoreParticipant("settings-history", {
                val preferences = settingsDataStore.data.first()
                historyKeys.none { it in preferences }
            }, {
                settingsDataStore.edit { preferences -> historyKeys.forEach { preferences.remove(it) } }
            }),
            PrivateStoreParticipant("post-drafts", { postDraftStore.data.first().asMap().isEmpty() }, {
                postDraftStore.edit { it.clear() }
                Unit
            }),
            PrivateStoreParticipant("comment-drafts", { commentDraftStore.data.first().asMap().isEmpty() }, {
                commentDraftStore.edit { it.clear() }
                Unit
            }),
            PrivateStoreParticipant("room-private", {
                database.useReaderConnection { connection ->
                    listOf(
                        "posts", "feed_positions", "feed_remote_keys", "post_details", "post_comments", "post_read_marks",
                        "post_reading_positions", "self_profile", "offline_threads", "offline_comments", "offline_images",
                        "collected_post_meta", "user_notes", "tracked_threads", "title_regex_hits",
                    ).all { table ->
                        connection.usePrepared("SELECT COUNT(*) FROM `$table`") { statement ->
                            statement.step()
                            statement.getLong(0) == 0L
                        }
                    }
                }
            }, {
                rawPostRepository.clearSessionData()
                // Derived IDs can outlive post pruning (there is no foreign key).
                // The device-global keyword rules themselves are intentionally preserved.
                database.titleKeywordDao().clearRegexHits()
                profileRepository.clearCachedProfile()
                rawOfflineLibrary.clearAll()
                userNoteStore.notes.first().keys.forEach { userNoteStore.setNote(it, "") }
                trackedThreadStore.all().forEach { trackedThreadStore.untrack(it.postId) }
            }),
            PrivateStoreParticipant("offline-files", { offlineFiles.isEmpty() }, { offlineFiles.clear() }),
            PrivateStoreParticipant("reports", {
                // Decoder fallback can hide corrupt/legacy bytes; absence alone proves empty.
                stringPreferencesKey("report_compare_basket") !in settingsDataStore.data.first()
            }, {
                settingsDataStore.edit { it.remove(stringPreferencesKey("report_compare_basket")) }
            }),
            PrivateStoreParticipant("authenticated-images", {
                val loader = imageLoader
                loader.memoryCache?.keys.orEmpty().isEmpty() && (loader.diskCache?.size ?: 0L) == 0L
            }, {
                val loader = imageLoader
                loader.memoryCache?.clear()
                loader.diskCache?.clear()
            }),
        )
        PrivateSessionBoundary(
            PrivateStoreProvenance(createPreferenceDataStore("private-store-provenance", keepOutOfBackup = true), participants.map { it.id }.toSet()),
            sessionCookies::privateOwnerProof,
            participants,
            beforePublication = {
                notificationRepository.clearCounts()
                settingsRepository.setNotificationSeenCounts(NotificationCounts())
            },
            preserveUnowned = true,
            publishSession = {
                sessionRepository.publishReconciled()
                Unit
            },
        )
    }

    override val postComposerRepository: PostComposerRepository by lazy {
        DefaultPostComposerRepository(postDraftStore, transport, dispatchers, clock, privateBoundary)
    }

    override val accountSettingsRepository: AccountSettingsRepository by lazy {
        NetworkAccountSettingsRepository(
            jsonApi = jsonClient,
            multipartWriteSource = jsonClient,
            htmlSource = htmlClient,
            profileRepository = profileRepository,
        )
    }

    override val userSpaceRepository: UserSpaceRepository by lazy {
        NetworkUserSpaceRepository(jsonClient, dispatchers)
    }

    override val offlineLibrary: OfflineLibrary by lazy { PrivateOfflineLibrary(rawOfflineLibrary, privateBoundary) }

    private val rawOfflineLibrary: RoomOfflineLibrary by lazy {
        RoomOfflineLibrary(
            dao = database.offlineDao(),
            remote = remotePosts,
            files = offlineFiles,
            // The app's own session, so a stored picture arrives under the same cookies and headers
            // as one on screen. Lazily for the reason the Android container gives about its client.
            images = object : io.github.nodyssey.data.offline.OfflineImageSource {
                override suspend fun fetch(url: String, maxBytes: Long): ByteArray? {
                    val bytes = kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) {
                        UrlSessionOfflineImageSource { urlSession }.fetch(url, maxBytes)
                    }
                    kotlinx.coroutines.currentCoroutineContext().ensureActive()
                    return bytes
                }
            },
            collectedMeta = collectedPostMetaStore,
            settingsStore = services.offlineSettings,
            scheduler = offlineScheduler,
            clock = clock,
            dispatchers = dispatchers,
        )
    }
    override val assetsRepository: AssetsRepository by lazy {
        NetworkAssetsRepository(profileRepository, creditRepository, jsonClient, dispatchers, clock)
    }

    override val commentComposerRepository: CommentComposerRepository by lazy {
        DefaultCommentComposerRepository(
            commentDraftStore,
            transport,
            dispatchers,
            clock,
            postRepository::noteOwnReplyPublished,
            privateBoundary,
        )
    }

    override val postEditor: PostEditor by lazy {
        DefaultPostEditor(
            remote = remotePosts,
            posts = postComposerRepository,
            comments = commentComposerRepository,
            threads = postRepository::extendThread,
        )
    }
    override val appCacheStore: AppCacheStore by lazy {
        IosAppCacheStore(
            cacheDirectory = workspaceRoot?.let { NSURL.fileURLWithPath("$it/cache", isDirectory = true) } ?: cachesDirectory(),
            dispatchers = dispatchers,
            // The singleton the screens draw through, not a loader of this store's own: emptying a
            // cache the app is not reading would report success and free nothing.
            imageCaches = { IosImageCaches { imageLoader } },
        )
    }
}
