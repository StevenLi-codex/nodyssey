package io.github.nodyssey.ui.composer

// Android and desktop keep their existing input/session behavior.
internal actual val iosComposerFocusHandoff: Boolean = false

internal actual fun checkComposerInputThread() = Unit
