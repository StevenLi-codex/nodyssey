package io.github.nodyssey.data.session

/** Includes public mixed-settings writers/observers, not just admitted private operations. */
class PrivateWorkspaceLifetime {
    private val barrier = SessionWorkBarrier()
    suspend fun start() = barrier.open("workspace")
    suspend fun <T> use(block: suspend () -> T): T = barrier.withLease("workspace", block)
    suspend fun closeAndJoin() = barrier.closeAndJoin()
}
