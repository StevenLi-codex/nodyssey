package io.github.nodyssey.ios

import io.github.nodyssey.data.EnhancedEditionPaths
import kotlinx.cinterop.ExperimentalForeignApi
import platform.Foundation.NSApplicationSupportDirectory
import platform.Foundation.NSCachesDirectory
import platform.Foundation.NSFileManager
import platform.Foundation.NSSearchPathDirectory
import platform.Foundation.NSURL
import platform.Foundation.NSUserDomainMask

/*
 * The two directories this app writes to, and the line between them.
 *
 * Application Support is what the system keeps: the database, the settings files, the downloaded
 * threads. Caches is what the system may take back whenever it is short of room: decoded images, the
 * web view's own store. That is the same distinction `filesDir` and `cacheDir` draw on Android, and
 * getting it backwards is how 「已离线」 stops being true after a night of low disk space.
 */

@OptIn(ExperimentalForeignApi::class)
internal fun applicationSupportDirectory(): NSURL = editionDirectory(editionPaths.supportRoot)

@OptIn(ExperimentalForeignApi::class)
internal fun cachesDirectory(): NSURL = editionDirectory(editionPaths.cacheRoot)

/** Selected before the graph opens DNS/settings, Room, drafts, offline files or Coil caches. */
@OptIn(ExperimentalForeignApi::class)
private val editionPaths: EnhancedEditionPaths by lazy {
    EnhancedEditionPaths(
        requireNotNull(systemDirectory(NSApplicationSupportDirectory).path),
        requireNotNull(systemDirectory(NSCachesDirectory).path),
    )
}

@OptIn(ExperimentalForeignApi::class)
private fun editionDirectory(path: String): NSURL {
    check(NSFileManager.defaultManager.createDirectoryAtPath(
        path, withIntermediateDirectories = true, attributes = null, error = null,
    )) { "Cannot create enhanced edition directory" }
    return NSURL.fileURLWithPath(path, isDirectory = true)
}

@OptIn(ExperimentalForeignApi::class)
private fun systemDirectory(directory: NSSearchPathDirectory): NSURL =
    requireNotNull(
        NSFileManager.defaultManager.URLForDirectory(
            directory = directory,
            inDomain = NSUserDomainMask,
            appropriateForURL = null,
            // Application Support is not created for an app on its own; Caches is, and asking twice
            // costs nothing.
            create = true,
            error = null,
        ),
    ) { "no directory $directory in the user domain" }
