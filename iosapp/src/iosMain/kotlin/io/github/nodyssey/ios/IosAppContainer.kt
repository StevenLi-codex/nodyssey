package io.github.nodyssey.ios

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
import kotlinx.coroutines.flow.map
import platform.Foundation.NSURL
/** Immutable, owned device-local repository graph. Never retarget captured repositories. */
@OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)
class IosAppContainer internal constructor(
    internal val services: IosGlobalServices,
    internal val profileRoot: String,
) : AppContainer by services {
    override val doh: io.github.nodyssey.data.dns.DohSupport get() = services.doh
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
        createNodeSeekDatabase("$profileRoot/private.db")
    }
    private val database get() = databaseDelegate.value
    private fun createPreferenceDataStore(name: String, keepOutOfBackup: Boolean = false) =
        io.github.nodyssey.data.createPreferenceDataStore(
            name,
            scope = storeScope,
            directory = profileRoot,
        )
    private val loaderDelegate = lazy {
        nodysseyImageLoader(PlatformContext.INSTANCE, privateBoundary, "$profileRoot/cache/image_cache") { urlSession }
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
    private val previewSite = io.github.nodyssey.core.ActiveSite.current

    /** iOS-only transient page-one read. Uses this graph's existing authenticated remote. */
    internal suspend fun previewThread(postId: Long): io.github.nodyssey.model.ThreadSnapshot = lifetime.use {
        privateBoundary.protect {
            require(postId > 0)
            fun checkSite() {
                // site.select only persists a restart choice. An installed-site drift must never
                // retarget this graph or export nodes resolved against a different site's origin.
                if (io.github.nodyssey.core.ActiveSite.current != previewSite) {
                    throw io.github.nodyssey.data.session.PrivateWorkRevoked()
                }
            }
            kotlinx.coroutines.currentCoroutineContext().ensureActive()
            checkSite()
            val detail = remotePosts.loadDetail(postId, 1)
            kotlinx.coroutines.currentCoroutineContext().ensureActive()
            checkSite()
            if (detail.postId != postId || detail.page != 1) {
                throw io.github.plaza.core.net.SiteException(io.github.plaza.core.net.SiteError.Unparsable)
            }
            // Preview never offers reveal-blocked actions. Keep server flags/identity, not content.
            fun visible(content: io.github.nodyssey.model.PostContent) = if (content.isBlocked) {
                content.copy(nodes = emptyList(), signatureNodes = emptyList())
            } else {
                content
            }
            io.github.nodyssey.model.ThreadSnapshot(
                postId = detail.postId,
                title = detail.title,
                body = detail.body?.let(::visible),
                comments = detail.comments.map(::visible),
                firstLoadedPage = 1,
                lastLoadedPage = 1,
                totalPages = detail.totalPages,
                // Shape compatibility only: this response was never persisted in the cache.
                cachedAtMillis = 0,
                commentPages = detail.comments.map { 1 },
                collected = detail.collected,
                collectionCount = detail.collectionCount,
                isAwarded = detail.isAwarded,
            )
        }
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
    internal suspend fun prepare() = Unit
    override val titleKeywordStore: TitleKeywordStore by lazy { TitleKeywordStore(database.titleKeywordDao(), clock) }
    override val trackedThreadStore: TrackedThreadStore by lazy { TrackedThreadStore(database.trackedThreadDao(), clock) }

    override val readingPositionStore: ReadingPositionStore by lazy {
        RoomReadingPositionStore(database.readingPositionDao(), clock)
    }

    private val settingsDataStore by lazy {
        createPreferenceDataStore("settings-private")
    }
    private val routedSettings by lazy {
        WorkspaceSettingsDataStore(services.settingsDataStore, settingsDataStore, services.settingsMutex)
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
    internal val offlineFiles by lazy { IosOfflineFileStore.of(NSURL.fileURLWithPath(profileRoot, isDirectory = true)) }

    internal val privateBoundary: PrivateSessionBoundary by lazy {
        PrivateSessionBoundary(
            provenance = null,
            owner = sessionCookies::privateOwnerProof,
            participants = emptyList(),
            singleAccountLocal = true,
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
            cacheDirectory = NSURL.fileURLWithPath("$profileRoot/cache", isDirectory = true),
            dispatchers = dispatchers,
            // The singleton the screens draw through, not a loader of this store's own: emptying a
            // cache the app is not reading would report success and free nothing.
            imageCaches = { IosImageCaches { imageLoader } },
        )
    }
}
