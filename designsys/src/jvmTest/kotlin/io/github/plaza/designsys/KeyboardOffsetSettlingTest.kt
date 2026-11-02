package io.github.plaza.designsys

import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.Measurable
import androidx.compose.ui.layout.MeasureResult
import androidx.compose.ui.layout.MeasureScope
import androidx.compose.ui.node.DelegatingNode
import androidx.compose.ui.node.GlobalPositionAwareModifierNode
import androidx.compose.ui.node.LayoutModifierNode
import androidx.compose.ui.node.ModifierNodeElement
import androidx.compose.ui.node.invalidateMeasurement
import androidx.compose.ui.platform.InspectorInfo
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.v2.runComposeUiTest
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.IntSize
import java.lang.reflect.Proxy
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * CMP-10727: exercise the resolved Compose binary, not a copy of its settling algorithm.
 *
 * The iOS keyboard uses this shared Skiko layout node. Reflection only constructs that private
 * upstream node and supplies its internal PlatformInsets value; measurement, placement, global
 * positioning and invalidation run attached to a real headless Compose owner. This is a regression
 * for its feedback-loop mechanism, not an iPhone keyboard/hang reproduction.
 */
class KeyboardOffsetSettlingTest {
    @OptIn(ExperimentalTestApi::class)
    @Test
    fun `keyboard offset settles once per ordinary measure and permits a later geometry change`() = runComposeUiTest {
        val probe = SettlingProbe()
        setContent {
            Layout(content = {}, modifier = ProbeElement(probe)) { _, _ ->
                layout(800, 800) {}
            }
        }

        runOnIdle {
            assertTrue(probe.upstream.isAttached, "The real upstream node must have an owner")
            assertEquals(
                2,
                probe.measureCount,
                "CMP-10727: one ordinary measure may trigger only one settling measure; " +
                    "observed ${probe.measureCount} measures and ${probe.positionCount} positioning callbacks " +
                    "from ${probe.upstream.javaClass.protectionDomain.codeSource.location}",
            )
            assertEquals(2, probe.positionCount)

            // A permanent 'never settle again' workaround must also fail: an independent layout
            // request re-arms settling and is entitled to its own single correction.
            probe.measureCount = 0
            probe.positionCount = 0
            probe.invalidateMeasurement()
        }

        runOnIdle {
            assertEquals(2, probe.measureCount, "A later external measure must permit one new settling pass")
            assertEquals(2, probe.positionCount)
        }
    }

    /**
     * Control the focus rectangle at the two real layout phases. During measurement it is visible;
     * after placement a simultaneous child-layout change puts it behind the keyboard. Keep doing
     * this even on a self-triggered measure: the old implementation keeps invalidating itself.
     *
     * Delegating with the same node kinds makes this wrapper the dispatch entry point, while its
     * delegate still has a real coordinator/owner and executes all production behavior. The hard
     * forwarding bound lets alpha01 reach the assertion rather than hang the test scheduler.
     */
    private class SettlingProbe :
        DelegatingNode(),
        LayoutModifierNode,
        GlobalPositionAwareModifierNode {
        var focusedRect = Rect(0f, 100f, 20f, 120f)
        val upstream = delegate(newUpstreamNode { focusedRect })
        var measureCount = 0
        var positionCount = 0

        override fun MeasureScope.measure(measurable: Measurable, constraints: Constraints): MeasureResult {
            measureCount++
            focusedRect = Rect(0f, 100f, 20f, 120f)
            return with(upstream as LayoutModifierNode) { measure(measurable, constraints) }
        }

        override fun onGloballyPositioned(coordinates: LayoutCoordinates) {
            positionCount++
            focusedRect = Rect(0f, 700f, 20f, 720f)
            if (positionCount <= 4) {
                (upstream as GlobalPositionAwareModifierNode).onGloballyPositioned(coordinates)
            }
        }
    }

    private class ProbeElement(private val probe: SettlingProbe) : ModifierNodeElement<SettlingProbe>() {
        override fun create() = probe

        override fun update(node: SettlingProbe) = Unit

        override fun InspectorInfo.inspectableProperties() = Unit

        override fun equals(other: Any?) = other is ProbeElement && other.probe === probe

        override fun hashCode() = System.identityHashCode(probe)
    }

    private companion object {
        fun newUpstreamNode(focusedRect: () -> Rect?): Modifier.Node {
            val nodeClass = Class.forName("androidx.compose.ui.layout.OffsetToFocusedRectNode")
            val insetsClass = Class.forName("androidx.compose.ui.platform.PlatformInsets")
            val insets = Proxy.newProxyInstance(insetsClass.classLoader, arrayOf(insetsClass)) { proxy, method, args ->
                when (method.name) {
                    "getBottom" -> 320
                    "getTop", "getLeft", "getRight" -> 0
                    "equals" -> proxy === args?.get(0)
                    "hashCode" -> System.identityHashCode(proxy)
                    "toString" -> "KeyboardInsets(bottom=320)"
                    else -> error("Unexpected PlatformInsets call: $method")
                }
            }
            // #3407 removed the externally supplied size in alpha02. Select the real constructor,
            // not Kotlin's synthetic DefaultConstructorMarker bridge; both versions run the same
            // measurement/positioning assertions above. Duration.ZERO is encoded as 0L.
            val constructor = nodeClass.declaredConstructors.single {
                it.parameterTypes.last().name != "kotlin.jvm.internal.DefaultConstructorMarker"
            }
            constructor.isAccessible = true
            val completion: () -> Unit = {}
            val arguments = when (constructor.parameterCount) {
                4 -> arrayOf(insets, focusedRect, 0L, completion)
                5 -> arrayOf(insets, focusedRect, IntSize(800, 800), 0L, completion)
                else -> error("Unexpected keyboard-offset constructor: $constructor")
            }
            return constructor.newInstance(*arguments) as Modifier.Node
        }
    }
}
