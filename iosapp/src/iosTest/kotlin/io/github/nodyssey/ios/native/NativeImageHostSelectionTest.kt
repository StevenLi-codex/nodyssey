package io.github.nodyssey.ios.native

import io.github.nodyssey.data.imagehost.HostedImage
import io.github.nodyssey.data.imagehost.ImageHostConfig
import io.github.nodyssey.data.imagehost.ImageHostProvider
import io.github.nodyssey.data.imagehost.ImageHostRepository
import io.github.nodyssey.data.imagehost.ImageHostUpload
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/** Concrete iosTest suite: no app graph, live transport, or test-owned selection lock. */
class NativeImageHostSelectionTest {
    private fun requester(repository: ImageHostRepository): suspend (String, JsonObject) -> JsonElement? =
        { operation, args -> settingsImageHostRequest(repository, operation, args) }

    @Test
    fun missingOrMalformedExpectedProviderNeverListsOrDeletes() = runBlocking {
        val repository = SelectionHostRepository()
        val request = requester(repository)
        val invalid = listOf(JsonNull, JsonPrimitive("node_image"), JsonPrimitive(" NODE_IMAGE"), JsonPrimitive("UNKNOWN"), JsonPrimitive(0), settingsObject())
        assertFailsWith<IllegalArgumentException> { request("imageHost.delete", settingsObject("id" to "collision")) }
        for (value in invalid) {
            assertFailsWith<IllegalArgumentException> {
                request("imageHost.delete", settingsObject("id" to "collision", "expectedProvider" to value))
            }
            assertFailsWith<IllegalArgumentException> {
                request("imageHost.images", settingsObject("expectedProvider" to value))
            }
        }
        assertEquals(emptyList(), repository.listed)
        assertEquals(emptyList(), repository.deleted)
    }

    @Test
    fun sameProviderDeletesExactImageWithBackendOnlyToken() = runBlocking {
        val repository = SelectionHostRepository()
        val request = requester(repository)
        val original = repository.rows.getValue(ImageHostProvider.NODE_IMAGE).single()
        assertEquals(JsonNull, request("imageHost.delete", settingsObject("id" to original.id, "expectedProvider" to "NODE_IMAGE")))
        assertEquals(listOf(ImageHostProvider.NODE_IMAGE to original), repository.deleted)
        assertEquals("node-delete-token", repository.deleted.single().second.deleteToken)
        assertEquals(0, repository.rows.getValue(ImageHostProvider.NODE_IMAGE).size)
        assertEquals(1, repository.rows.getValue(ImageHostProvider.SMMS).size)
    }

    @Test
    fun missingIdDoesNotDeleteAnotherImage() = runBlocking {
        val repository = SelectionHostRepository()
        val request = requester(repository)
        val failure = assertFailsWith<NativeFailure> {
            request("imageHost.delete", settingsObject("id" to "absent", "expectedProvider" to "NODE_IMAGE"))
        }
        assertEquals("NOT_FOUND", failure.code)
        assertEquals(emptyList(), repository.deleted)
    }

    @Test
    fun queuedDeleteValidatesProviderAfterTakingSettingsLock() = runBlocking {
        withTimeout(5_000) {
            val repository = SelectionHostRepository()
            val request = requester(repository)
            val entered = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            repository.beforeSelect = {
                entered.complete(Unit)
                release.await()
            }
            val selection = launch { request("imageHost.select", settingsObject("provider" to "SMMS")) }
            entered.await()
            // UNDISTPATCHED enters settingsRequest now, while the selection owns its lock.
            val deletion = async(start = CoroutineStart.UNDISPATCHED) {
                assertFailsWith<NativeFailure> {
                    request("imageHost.delete", settingsObject("id" to "collision", "expectedProvider" to "NODE_IMAGE"))
                }.code
            }
            release.complete(Unit)
            selection.join()
            assertEquals("SOURCE_CHANGED", deletion.await())
            assertEquals(emptyList(), repository.listed)
            assertEquals(emptyList(), repository.deleted)
        }
    }

    @Test
    fun selectionCannotInterleaveBetweenDeletionListingAndDelete() = runBlocking {
        withTimeout(5_000) {
            val repository = SelectionHostRepository()
            val request = requester(repository)
            val entered = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            repository.beforeImages = {
                entered.complete(Unit)
                release.await()
            }
            val deletion = async { request("imageHost.delete", settingsObject("id" to "collision", "expectedProvider" to "NODE_IMAGE")) }
            entered.await()
            val selection = launch(start = CoroutineStart.UNDISPATCHED) { request("imageHost.select", settingsObject("provider" to "SMMS")) }
            assertEquals(ImageHostProvider.NODE_IMAGE, repository.selected.value)
            release.complete(Unit)
            assertEquals(JsonNull, deletion.await())
            selection.join()
            assertEquals(ImageHostProvider.SMMS, repository.selected.value)
            assertEquals(ImageHostProvider.NODE_IMAGE, repository.deleted.single().first)
            assertEquals("node-delete-token", repository.deleted.single().second.deleteToken)
            assertEquals(1, repository.rows.getValue(ImageHostProvider.SMMS).size)
        }
    }

    @Test
    fun cancellationDuringDeletionListingReleasesLockWithoutDeleting() = runBlocking {
        withTimeout(5_000) {
            val repository = SelectionHostRepository()
            val request = requester(repository)
            val entered = CompletableDeferred<Unit>()
            repository.beforeImages = {
                entered.complete(Unit)
                awaitCancellation()
            }
            val deletion = launch { request("imageHost.delete", settingsObject("id" to "collision", "expectedProvider" to "NODE_IMAGE")) }
            entered.await()
            deletion.cancelAndJoin()
            request("imageHost.select", settingsObject("provider" to "SMMS"))
            assertEquals(ImageHostProvider.SMMS, repository.selected.value)
            assertEquals(emptyList(), repository.deleted)
        }
    }

    @Test
    fun providerBoundListRejectsSwitchBeforeDispatch() = runBlocking {
        val repository = SelectionHostRepository()
        val request = requester(repository)
        request("imageHost.select", settingsObject("provider" to "SMMS"))
        val failure = assertFailsWith<NativeFailure> {
            request("imageHost.images", settingsObject("expectedProvider" to "NODE_IMAGE"))
        }
        assertEquals("SOURCE_CHANGED", failure.code)
        assertEquals(emptyList(), repository.listed)
    }

    @Test
    fun switchAfterLastFrontendCheckCannotDeleteCollidingIdOnAnotherProvider() = runBlocking {
        val repository = SelectionHostRepository()
        val request = requester(repository)
        request("imageHost.images", settingsObject())
        // The UI's last check succeeds, then a second window selects another browsable host.
        assertEquals("NODE_IMAGE", (request("imageHost.get", settingsObject()) as JsonObject).settingsString("provider"))
        request("imageHost.select", settingsObject("provider" to "SMMS"))
        val failure = assertFailsWith<NativeFailure> {
            request("imageHost.delete", settingsObject("id" to "collision", "expectedProvider" to "NODE_IMAGE"))
        }
        assertEquals("SOURCE_CHANGED", failure.code)
        assertEquals(listOf(ImageHostProvider.NODE_IMAGE), repository.listed)
        assertEquals(emptyList(), repository.deleted)
        assertEquals(1, repository.rows.getValue(ImageHostProvider.SMMS).size)
    }
}

private class SelectionHostRepository : ImageHostRepository {
    override val selected = MutableStateFlow(ImageHostProvider.NODE_IMAGE)
    override val current = selected.map { ImageHostConfig(provider = it, token = "test-only") }
    val rows = mutableMapOf(
        ImageHostProvider.NODE_IMAGE to mutableListOf(HostedImage("collision", "node.png", "https://node.invalid/a.png", deleteToken = "node-delete-token")),
        ImageHostProvider.SMMS to mutableListOf(HostedImage("collision", "smms.png", "https://smms.invalid/b.png", deleteToken = "smms-delete-token")),
    )
    val listed = mutableListOf<ImageHostProvider>()
    val deleted = mutableListOf<Pair<ImageHostProvider, HostedImage>>()
    var beforeImages: suspend () -> Unit = {}
    var beforeSelect: suspend () -> Unit = {}
    override fun config(provider: ImageHostProvider) = MutableStateFlow(ImageHostConfig(provider = provider, token = "test-only"))
    override suspend fun select(provider: ImageHostProvider) {
        beforeSelect()
        selected.value = provider
    }
    override suspend fun save(config: ImageHostConfig) = error("not used")
    override suspend fun disconnect(provider: ImageHostProvider) = error("not used")
    override suspend fun upload(upload: ImageHostUpload, onProgress: (Float) -> Unit): HostedImage = error("No live uploads")
    override suspend fun images(): List<HostedImage> {
        beforeImages()
        listed += selected.value
        return rows.getValue(selected.value).toList()
    }
    override suspend fun delete(image: HostedImage) {
        deleted += selected.value to image
        rows.getValue(selected.value).remove(image)
    }
}
