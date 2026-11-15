@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.github.nodyssey.ios

import io.github.nodyssey.core.ActiveSite
import platform.Foundation.NSFileManager
import platform.Foundation.NSNumber
import platform.Foundation.NSURL
import platform.Foundation.NSURLIsExcludedFromBackupKey

/** Outside Caches: ordinary cache maintenance must never sweep preserved spaces. */
internal fun privateWorkspaceDirectory(id: String? = null): String {
    val base = requireNotNull(applicationSupportDirectory().path)
    val root = "$base/io.github.nodyssey.private-workspaces/${ActiveSite.current.name}"
    val path = if (id == null) root else "$root/$id"
    check(NSFileManager.defaultManager.createDirectoryAtPath(path, true, null, null))
    check(NSURL.fileURLWithPath(root, isDirectory = true).setResourceValue(NSNumber(bool = true), NSURLIsExcludedFromBackupKey, null))
    return path
}

/** Do not open/migrate an installed legacy database merely to decide it is unowned. */
internal fun legacyPrivateFilesExist(): Boolean {
    val base = requireNotNull(applicationSupportDirectory().path)
    val files = NSFileManager.defaultManager
    return listOf(
        io.github.nodyssey.data.local.nodeSeekDatabasePath(),
        "$base/post-composer.preferences_pb",
        "$base/comment-composer.preferences_pb",
        "$base/offline",
        "${requireNotNull(cachesDirectory().path)}/image_cache",
        "${legacyProvenanceDirectory()}/private-store-provenance.preferences_pb",
    ).any { files.fileExistsAtPath(it) }
}

/** Inspect in place; unlike the secret factory this must not migrate a legacy journal. */
internal fun legacyProvenanceDirectory(): String {
    val base = requireNotNull(applicationSupportDirectory().path)
    val excluded = "$base/io.github.nodyssey.no-backup"
    return if (NSFileManager.defaultManager.fileExistsAtPath("$excluded/private-store-provenance.preferences_pb")) excluded else base
}
