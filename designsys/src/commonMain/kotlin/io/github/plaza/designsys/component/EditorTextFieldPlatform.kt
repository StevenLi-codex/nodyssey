package io.github.plaza.designsys.component

import androidx.compose.runtime.staticCompositionLocalOf

/** Testable platform boundary: Android and desktop retain the original editor path. */
internal expect val optimizeEditorTextField: Boolean

internal val LocalEditorTextFieldOptimization = staticCompositionLocalOf { optimizeEditorTextField }
