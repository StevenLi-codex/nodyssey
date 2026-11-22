package io.github.plaza.designsys.component

import kotlin.test.Test

class EditorTextFieldPlatformTest {
    @Test
    fun `desktop production retains the original layout callback behavior`() =
        EditorTextFieldLayoutTest().assertRemeasurementCallbackWrites(
            "ordinary text",
            optimized = optimizeEditorTextField,
            expectedWrites = 1,
        )
}
