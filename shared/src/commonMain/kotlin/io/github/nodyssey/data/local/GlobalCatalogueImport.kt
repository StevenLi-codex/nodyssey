package io.github.nodyssey.data.local

import androidx.room.immediateTransaction
import androidx.room.useWriterConnection
import androidx.sqlite.SQLiteConnection

/** Import only global catalogues once, atomically, from a read-only legacy connection.
 * No private table or derived post-ID table is read/copied. The source is never migrated.
 */
suspend fun NodeSeekDatabase.importGlobalCatalogues(openLegacy: () -> SQLiteConnection?) {
    useWriterConnection { target ->
        target.immediateTransaction {
            target.usePrepared("CREATE TABLE IF NOT EXISTS workspace_catalogue_import (done INTEGER NOT NULL)") { it.step() }
            val done = target.usePrepared("SELECT COUNT(*) FROM workspace_catalogue_import") {
                it.step()
                it.getLong(0) != 0L
            }
            if (!done) {
                openLegacy()?.use { source ->
                    for (table in listOf("boards", "title_keywords", "my_stickers", "sticker_repos", "sticker_folders")) {
                        val exists = source.prepare("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?").use {
                            it.bindText(1, table)
                            it.step()
                            it.getLong(0) != 0L
                        }
                        if (!exists) continue
                        source.prepare("SELECT * FROM `$table`").use { rows ->
                            val columns = (0 until rows.getColumnCount()).map { rows.getColumnName(it) }
                            check(columns.all { Regex("[A-Za-z_][A-Za-z0-9_]*").matches(it) })
                            val sql = "INSERT OR IGNORE INTO `$table` (${columns.joinToString { "`$it`" }}) VALUES (${columns.joinToString { "?" }})"
                            while (rows.step()) {
                                target.usePrepared(sql) { insert ->
                                    columns.indices.forEach { index ->
                                        when (rows.getColumnType(index)) {
                                            1 -> insert.bindLong(index + 1, rows.getLong(index))
                                            2 -> insert.bindDouble(index + 1, rows.getDouble(index))
                                            3 -> insert.bindText(index + 1, rows.getText(index))
                                            4 -> insert.bindBlob(index + 1, rows.getBlob(index))
                                            5 -> insert.bindNull(index + 1)
                                            else -> error("Unknown SQLite column type")
                                        }
                                    }
                                    insert.step()
                                }
                            }
                        }
                    }
                }
                target.usePrepared("INSERT INTO workspace_catalogue_import VALUES (1)") { it.step() }
            }
        }
    }
}
