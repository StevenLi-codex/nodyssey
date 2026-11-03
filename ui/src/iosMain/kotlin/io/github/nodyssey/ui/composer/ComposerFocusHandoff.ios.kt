package io.github.nodyssey.ui.composer

import platform.Foundation.NSThread

internal actual val iosComposerFocusHandoff: Boolean = true

internal actual fun checkComposerInputThread() {
    check(NSThread.isMainThread) { "Composer input handoff must run on Main" }
}
