package io.github.nodyssey.ios

import io.github.nodyssey.data.offline.OfflineFileStore
import java.io.File

/** Real temporary files, NOT Foundation or the shipping iOS path implementation. */
class GraphFiles(private val root: File) : OfflineFileStore {
    var failClear = false
    init { root.mkdirs() }
    fun isEmpty() = root.listFiles().orEmpty().isEmpty()
    override fun nameOf(url: String) = java.util.UUID.nameUUIDFromBytes(url.toByteArray()).toString()
    override fun hasStored(url: String) = File(root, nameOf(url)).isFile
    override fun write(name: String, bytes: ByteArray): Long { File(root, name).writeBytes(bytes); return bytes.size.toLong() }
    override fun sweep(keep: Set<String>) { root.listFiles().orEmpty().filter { it.name !in keep }.forEach { check(it.delete()) } }
    override fun clear() { check(!failClear) { "injected offline file cleanup failure" }; sweep(emptySet()) }
    override fun freeBytes() = root.usableSpace
    override fun hasRoomFor(bytes: Long) = bytes < root.usableSpace
}
