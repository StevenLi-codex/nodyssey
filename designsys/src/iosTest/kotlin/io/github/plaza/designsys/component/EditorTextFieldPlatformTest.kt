package io.github.plaza.designsys.component

import kotlin.test.Test

class EditorTextFieldPlatformTest {
    @Test
    fun `iOS production selects the no callback publication path`() =
        EditorTextFieldLayoutTest().assertRemeasurementCallbackWrites(
            "ordinary text",
            optimized = optimizeEditorTextField,
        )
}
