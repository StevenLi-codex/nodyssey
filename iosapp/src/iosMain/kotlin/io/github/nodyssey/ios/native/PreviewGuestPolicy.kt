package io.github.nodyssey.ios.native

/** Shipping preview policy, not a debug flag. New operations are denied by default. */
internal object PreviewGuestPolicy {
    private val requests = setOf(
        "site.get", "app.foreground", "session.snapshot",
        "categories.get", "categories.refresh", "feed.pageIndex",
        "paging.access", "paging.refresh", "paging.retry",
        "search.local", "search.users", "search.resolveMember",
        "thread.get", "thread.config", "thread.load", "thread.status",
        "thread.markRead", "thread.position.get", "thread.position.set",
        "profile.user", "space.topics", "space.comments", "vote.get",
        "settings.get", "settings.capabilities", "settings.metadata",
        "settings.terms", "settings.privacy", "settings.changelog",
        "search.history.get", "search.history.record", "boards.recent.get", "boards.recent.record",
    )
    private val observations = setOf(
        "session.state", "settings.observe", "feed", "categories", "thread", "thread.config",
        "search.feed", "search.local", "search.history", "boards.recent",
    )
    private val localSettings = setOf(
        "themeMode", "appLanguage", "colorSource", "presetId", "seedColor", "paletteStyle",
        "fontScale", "oneHandMode", "einkMode", "imagesOnWifiOnly", "feedSort", "homePageBar",
        "onboardingSeen", "oneHandTipDismissed",
    )

    fun allows(operation: String, observing: Boolean, settingKey: String?): Boolean =
        if (observing) operation in observations else
            operation in requests || (operation == "settings.set" && settingKey in localSettings)

    @Suppress("UNUSED_PARAMETER")
    fun browserAllowed(goal: String): Boolean = false

    fun sessionAllowed(signedIn: Boolean): Boolean = !signedIn
}
