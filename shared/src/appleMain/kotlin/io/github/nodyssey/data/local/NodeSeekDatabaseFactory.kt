package io.github.nodyssey.data.local

import androidx.room.Room
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import io.github.nodyssey.core.ActiveSite
import kotlinx.cinterop.ExperimentalForeignApi
import platform.Foundation.NSApplicationSupportDirectory
import platform.Foundation.NSFileManager
import platform.Foundation.NSURL
import platform.Foundation.NSUserDomainMask

/**
 * The same database, opened where an Apple platform keeps one.
 *
 * Application Support rather than Documents: this file is the app's cache and bookkeeping, not
 * something the person using it produced, and Documents is the directory a file-browsing user is
 * shown. The file name is the one Android already uses — see [databaseFileName] — which costs
 * nothing and makes a store recognisable across the two.
 *
 * [BundledSQLiteDriver] rather than the platform's own: Apple ships a system SQLite but Room's
 * driver for it is Android's, and a bundled copy is also the only way both targets are known to be
 * on the same SQLite version as the schemas were generated against.
 */
@OptIn(ExperimentalForeignApi::class)
fun createNodeSeekDatabase(rootDirectory: String? = null): NodeSeekDatabase =
    Room
        .databaseBuilder<NodeSeekDatabase>(name = nodeSeekDatabasePath(rootDirectory))
        .setDriver(BundledSQLiteDriver())
        .addMigrations(*NODESEEK_MIGRATIONS)
        // Preserve the default Apple factory's legacy policy for other callers. The enhanced iOS
        // edition explicitly supplies its fixed root and fails closed on unsupported schemas;
        // neither downgrade nor v1/v2 can silently destroy even that edition's data.
        .apply {
            if (rootDirectory == null) {
                fallbackToDestructiveMigrationFrom(dropAllTables = true, 1, 2)
                fallbackToDestructiveMigrationOnDowngrade(dropAllTables = true)
            }
        }
        .build()

@OptIn(ExperimentalForeignApi::class)
private fun nodeSeekDatabasePath(rootDirectory: String?): String {
    if (rootDirectory != null) {
        NSFileManager.defaultManager.createDirectoryAtPath(
            rootDirectory, withIntermediateDirectories = true, attributes = null, error = null,
        )
        return "$rootDirectory/${databaseFileName(ActiveSite.current)}"
    }
    val directory: NSURL? =
        NSFileManager.defaultManager.URLForDirectory(
            directory = NSApplicationSupportDirectory,
            inDomain = NSUserDomainMask,
            appropriateForURL = null,
            create = true,
            error = null,
        )
    return requireNotNull(directory?.path) { "no Application Support directory" } +
        "/" + databaseFileName(ActiveSite.current)
}
