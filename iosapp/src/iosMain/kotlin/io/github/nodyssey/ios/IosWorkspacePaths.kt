@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.github.nodyssey.ios

import io.github.nodyssey.core.ActiveSite
import platform.Foundation.NSFileManager
import platform.Foundation.NSNumber
import platform.Foundation.NSURL
import platform.Foundation.NSURLIsExcludedFromBackupKey

/** One durable device-local profile. No account ID, proof, router, migration or legacy fallback. */
internal fun singleLocalProfileDirectory(): String {
    val base = requireNotNull(applicationSupportDirectory().path)
    val root = "$base/io.github.nodyssey.single-local-v1/${ActiveSite.current.name}"
    check(NSFileManager.defaultManager.createDirectoryAtPath(root, true, null, null))
    check(NSURL.fileURLWithPath(root, isDirectory = true).setResourceValue(NSNumber(bool = true), NSURLIsExcludedFromBackupKey, null))
    return root
}
