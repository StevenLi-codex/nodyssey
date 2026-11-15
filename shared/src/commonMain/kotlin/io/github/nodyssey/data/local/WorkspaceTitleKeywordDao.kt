package io.github.nodyssey.data.local

import io.github.nodyssey.model.TitleKeywordKind

/** Global rules, workspace-local SQL mirrors and derived private post IDs.
 * Never invoke global.rebuildRegexHits: that would touch quarantined legacy post IDs.
 */
class WorkspaceTitleKeywordDao(
    private val global: TitleKeywordDao,
    private val local: TitleKeywordDao,
) : TitleKeywordDao by local {
    suspend fun synchronize() {
        TitleKeywordKind.entries.forEach { kind ->
            val desired = global.list(kind)
            local.list(kind).filter { old -> desired.none { it.keyword == old.keyword } }.forEach { local.delete(kind, it.keyword) }
            desired.forEach { local.insert(it) }
        }
        local.rebuildRegexHits(TitleRegexRules(global.list(TitleKeywordKind.BLOCK_REGEX).map { it.keyword }))
    }

    override suspend fun insert(keyword: TitleKeywordEntity) {
        global.insert(keyword)
        synchronize()
    }

    override suspend fun delete(kind: TitleKeywordKind, keyword: String) {
        global.delete(kind, keyword)
        synchronize()
    }
}
